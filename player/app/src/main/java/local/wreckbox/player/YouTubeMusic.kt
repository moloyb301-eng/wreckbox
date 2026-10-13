package local.wreckbox.player

import android.webkit.CookieManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale

/** Something YouTube Music lists: a song, or a page to open (album, playlist, artist). */
sealed class Item {
    abstract val title: String
    abstract val subtitle: String
    abstract val art: String?

    data class Song(val track: Track, override val subtitle: String, val video: Boolean = false) : Item() {
        override val title get() = track.title
        override val art get() = track.art
    }
    data class Album(val id: String, override val title: String, override val subtitle: String, override val art: String?, val artist: String = "") : Item()
    data class Playlist(val id: String, override val title: String, override val subtitle: String, override val art: String?) : Item()
    data class Artist(val id: String, override val title: String, override val subtitle: String, override val art: String?) : Item()
    /** A mood / genre button (opens a browse page with params). */
    data class Mood(val id: String, val params: String, override val title: String, val color: Long) : Item() {
        override val subtitle get() = ""
        override val art: String? get() = null
    }

    /** One of our mixes (Home): its songs are right here. */
    data class Mix(val id: String, override val title: String, override val subtitle: String, val tracks: List<Track>) : Item() {
        override val art get() = tracks.firstOrNull { it.art != null }?.art
        /** Up to four different covers, for the tile's collage. */
        val arts get() = tracks.mapNotNull { it.art }.distinct().take(4)
    }

    fun toJson(): JSONObject = when (this) {
        is Song -> JSONObject().put("k", "song").put("track", track.toJson()).put("sub", subtitle).put("video", video)
        is Album -> JSONObject().put("k", "album").put("id", id).put("title", title).put("sub", subtitle).put("art", art).put("artist", artist)
        is Playlist -> JSONObject().put("k", "playlist").put("id", id).put("title", title).put("sub", subtitle).put("art", art)
        is Artist -> JSONObject().put("k", "artist").put("id", id).put("title", title).put("sub", subtitle).put("art", art)
        is Mood -> JSONObject().put("k", "mood").put("id", id).put("params", params).put("title", title).put("color", color)
        is Mix -> JSONObject().put("k", "mix").put("id", id).put("title", title).put("sub", subtitle).put("tracks", tracks.toJsonArray())
    }

    companion object {
        fun fromJson(j: JSONObject): Item? = runCatching {
            fun s(k: String) = j.optString(k).takeIf { it.isNotEmpty() && it != "null" }
            when (j.getString("k")) {
                "song" -> Song(Track.fromJson(j.getJSONObject("track")), j.optString("sub"), j.optBoolean("video"))
                "album" -> Album(j.getString("id"), j.getString("title"), j.optString("sub"), s("art"), j.optString("artist"))
                "playlist" -> Playlist(j.getString("id"), j.getString("title"), j.optString("sub"), s("art"))
                "artist" -> Artist(j.getString("id"), j.getString("title"), j.optString("sub"), s("art"))
                "mood" -> Mood(j.getString("id"), j.optString("params"), j.getString("title"), j.optLong("color"))
                "mix" -> Mix(j.getString("id"), j.getString("title"), j.optString("sub"), j.optJSONArray("tracks").toTracks())
                else -> null
            }
        }.getOrNull()
    }
}

/** A titled row of items (a YouTube Music shelf, or one of ours). */
data class Shelf(val title: String, val items: List<Item>, val subtitle: String = "") {
    fun toJson(): JSONObject = JSONObject().put("title", title).put("sub", subtitle).put("items", JSONArray().also { a -> items.forEach { a.put(it.toJson()) } })

    companion object {
        fun fromJson(j: JSONObject) = Shelf(j.optString("title"), j.optJSONArray("items")?.let { a ->
            (0 until a.length()).mapNotNull { Item.fromJson(a.getJSONObject(it)) }
        } ?: emptyList(), j.optString("sub"))
    }
}

/**
 * YouTube Music's own web API (the one music.youtube.com uses; no key). Signed-in calls (your home feed, your history)
 * send the session cookies the app already has from signing in, with the same SAPISIDHASH header the website sends.
 */
object YouTubeMusic {
    private const val ORIGIN = "https://music.youtube.com"

    private fun country() = Locale.getDefault().country.takeIf { it.length == 2 } ?: "US"

    fun signedIn() = LoginActivity.signedIn(Service.YOUTUBE)

    suspend fun call(endpoint: String, body: JSONObject, auth: Boolean = false): JSONObject = withContext(Dispatchers.IO) {
        body.put("context", JSONObject().put("client", JSONObject().put("clientName", "WEB_REMIX").put("clientVersion", "1.20251001.01.00")
            .put("hl", "en").put("gl", country())))
        val c = URL("$ORIGIN/youtubei/v1/$endpoint?prettyPrint=false").openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.doOutput = true
        c.connectTimeout = 10_000
        c.readTimeout = 15_000
        c.setRequestProperty("Content-Type", "application/json")
        c.setRequestProperty("Origin", ORIGIN)
        c.setRequestProperty("X-Origin", ORIGIN)
        c.setRequestProperty("User-Agent", WebEngine.userAgent())
        if (auth) {
            val cookies = CookieManager.getInstance().getCookie(ORIGIN)
            val sapisid = cookies?.split(";")?.map { it.trim() }?.firstOrNull { it.startsWith("SAPISID=") || it.startsWith("__Secure-3PAPISID=") }?.substringAfter("=")
            if (cookies != null && sapisid != null) {
                val ts = System.currentTimeMillis() / 1000
                val hash = MessageDigest.getInstance("SHA-1").digest("$ts $sapisid $ORIGIN".toByteArray()).joinToString("") { "%02x".format(it) }
                c.setRequestProperty("Cookie", cookies)
                c.setRequestProperty("Authorization", "SAPISIDHASH ${ts}_$hash")
                c.setRequestProperty("X-Goog-AuthUser", "0")
            }
        }
        c.outputStream.use { it.write(body.toString().toByteArray()) }
        JSONObject(c.inputStream.bufferedReader().use { it.readText() })
    }

    private var warmedAt = 0L

    /** Opens the connection to YouTube Music ahead of a search (the TLS handshake costs 0.2–0.4 s on mobile data). */
    suspend fun warm() {
        if (System.currentTimeMillis() - warmedAt < 60_000) return
        warmedAt = System.currentTimeMillis()
        runCatching { call("music/get_search_suggestions", JSONObject().put("input", "")) }
    }

    // MARK: search

    class Results(
        val top: Item?,
        val songs: List<Item.Song>,
        val artists: List<Item.Artist>,
        val albums: List<Item.Album>,
        val playlists: List<Item.Playlist>,
        /** "Showing results for …": YouTube's own spelling fix. */
        val corrected: String?,
    )

    /** The unfiltered search: the top result and a mix of songs, videos, artists, albums and playlists. */
    suspend fun search(q: String): Results {
        val j = call("search", JSONObject().put("query", q))
        var top: Item? = null
        walk(j, "musicCardShelfRenderer") { card ->
            val run = card.optJSONObject("title")?.optJSONArray("runs")?.optJSONObject(0)
            val sub = text(card.optJSONObject("subtitle"))
            val art = thumb(card.optJSONObject("thumbnail"))
            val nav = run?.optJSONObject("navigationEndpoint")
            top = nav?.let { browseItem(it, run.optString("text"), sub, art) }
                ?: nav?.optJSONObject("watchEndpoint")?.optString("videoId")?.takeIf { it.isNotEmpty() }?.let { id ->
                    val parts = sub.split(" • ")
                    Item.Song(Track(Source.YOUTUBE, id, run.optString("text"), parts.getOrNull(1) ?: "", parts.getOrNull(2), dur(parts.lastOrNull()), art), sub, parts.firstOrNull() == "Video")
                }
        }
        val items = mutableListOf<Item>()
        walk(j, "musicResponsiveListItemRenderer") { r -> listItem(r)?.let(items::add) }
        val corrected = j.toString().takeIf { it.contains("showingResultsForRenderer") }?.let {
            var q2: String? = null
            walk(j, "showingResultsForRenderer") { r -> q2 = r.optJSONObject("correctedQueryEndpoint")?.optJSONObject("searchEndpoint")?.optString("query") }
            q2
        }
        // The top card repeats a few of its own songs below it: keep each once.
        val songs = items.filterIsInstance<Item.Song>().distinctBy { it.track.id }
        return Results(top, songs, items.filterIsInstance<Item.Artist>().distinctBy { it.id }, items.filterIsInstance<Item.Album>().distinctBy { it.id },
            items.filterIsInstance<Item.Playlist>().distinctBy { it.id }, corrected)
    }

    /** Suggestions while typing: completed queries, then a few direct hits (artists, songs). */
    suspend fun suggestions(q: String): Pair<List<String>, List<Item>> {
        val j = call("music/get_search_suggestions", JSONObject().put("input", q))
        val texts = mutableListOf<String>()
        walk(j, "searchSuggestionRenderer") { r ->
            r.optJSONObject("navigationEndpoint")?.optJSONObject("searchEndpoint")?.optString("query")?.takeIf { it.isNotEmpty() }?.let(texts::add)
        }
        val items = mutableListOf<Item>()
        walk(j, "musicResponsiveListItemRenderer") { r -> listItem(r)?.let(items::add) }
        return texts to items
    }

    // MARK: pages

    class ArtistPage(val name: String, val art: String?, val about: String, val listeners: String, val songs: List<Item.Song>,
                     val songsPlaylist: String?, val shelves: List<Shelf>, val radio: String?)

    suspend fun artist(id: String): ArtistPage {
        val j = call("browse", JSONObject().put("browseId", id))
        val h = j.optJSONObject("header")?.let { it.optJSONObject("musicImmersiveHeaderRenderer") ?: it.optJSONObject("musicVisualHeaderRenderer") }
        val name = text(h?.optJSONObject("title"))
        val songs = mutableListOf<Item.Song>()
        var songsPlaylist: String? = null
        val shelves = mutableListOf<Shelf>()
        sections(j).forEach { s ->
            s.optJSONObject("musicShelfRenderer")?.let { m ->
                m.optJSONArray("contents")?.forEachObj { it.optJSONObject("musicResponsiveListItemRenderer")?.let(::listItem)?.let { i -> if (i is Item.Song) songs += i.copy(track = i.track.copy(artist = i.track.artist.ifEmpty { name })) } }
                songsPlaylist = (m.optJSONObject("bottomEndpoint") ?: m.optJSONObject("title")?.optJSONArray("runs")?.optJSONObject(0)?.optJSONObject("navigationEndpoint"))
                    ?.optJSONObject("browseEndpoint")?.optString("browseId")?.takeIf { it.isNotEmpty() }
            }
            s.optJSONObject("musicCarouselShelfRenderer")?.let { carousel(it, name) }?.takeIf { it.items.isNotEmpty() }?.let(shelves::add)
        }
        val radio = h?.optJSONObject("startRadioButton")?.optJSONObject("buttonRenderer")?.optJSONObject("navigationEndpoint")
            ?.optJSONObject("watchPlaylistEndpoint")?.optString("playlistId")
        return ArtistPage(name, thumb(h?.optJSONObject("thumbnail")), text(h?.optJSONObject("description")),
            text(h?.optJSONObject("monthlyListenerCount")), songs, songsPlaylist, shelves, radio)
    }

    class Collection(val title: String, val subtitle: String, val art: String?, val tracks: List<Track>)

    /** An album (MPREb_…) or a playlist (VL…) — its songs. */
    suspend fun collection(id: String): Collection {
        val j = call("browse", JSONObject().put("browseId", id))
        var title = ""
        var sub = ""
        var art: String? = null
        var artist = ""
        walk(j, "musicResponsiveHeaderRenderer") { h ->
            title = text(h.optJSONObject("title"))
            sub = text(h.optJSONObject("subtitle"))
            artist = text(h.optJSONObject("straplineTextOne"))
            art = thumb(h.optJSONObject("thumbnail"))
        }
        if (title.isEmpty()) walk(j, "musicDetailHeaderRenderer") { h ->
            title = text(h.optJSONObject("title")); sub = text(h.optJSONObject("subtitle")); art = thumb(h.optJSONObject("thumbnail"))
        }
        val album = id.startsWith("MPRE")
        val tracks = mutableListOf<Track>()
        walk(j, "musicResponsiveListItemRenderer") { r ->
            (listItem(r) as? Item.Song)?.track?.let { t ->
                // Album rows leave out the artist and cover: they're the album's.
                tracks += if (album) t.copy(artist = t.artist.ifEmpty { artist }, album = t.album ?: title, art = t.art ?: art) else t
            }
        }
        return Collection(title, listOf(sub, artist).filter { it.isNotEmpty() }.joinToString(" · "), art, tracks.distinctBy { it.id })
    }

    /** A browse page made of shelves: home, charts, new releases, a mood or genre. */
    suspend fun shelves(browseId: String, params: String? = null, auth: Boolean = false): List<Shelf> {
        val body = JSONObject().put("browseId", browseId)
        if (params != null) body.put("params", params)
        val j = call("browse", body, auth)
        val out = mutableListOf<Shelf>()
        sections(j).forEach { s ->
            s.optJSONObject("musicCarouselShelfRenderer")?.let { carousel(it, "") }?.let(out::add)
            s.optJSONObject("musicShelfRenderer")?.let { m ->
                val items = mutableListOf<Item>()
                m.optJSONArray("contents")?.forEachObj { it.optJSONObject("musicResponsiveListItemRenderer")?.let(::listItem)?.let(items::add) }
                out += Shelf(text(m.optJSONObject("title")), items)
            }
            s.optJSONObject("gridRenderer")?.let { g ->
                val items = mutableListOf<Item>()
                g.optJSONArray("items")?.forEachObj { o ->
                    o.optJSONObject("musicTwoRowItemRenderer")?.let { twoRow(it, "") }?.let(items::add)
                    o.optJSONObject("musicNavigationButtonRenderer")?.let(::moodButton)?.let(items::add)
                }
                out += Shelf(text(g.optJSONObject("header")?.optJSONObject("gridHeaderRenderer")?.optJSONObject("title")), items)
            }
        }
        return out.filter { it.items.isNotEmpty() }
    }

    /** Your listening history on YouTube Music (signed in): songs under "Today", "Yesterday", "This week"… */
    suspend fun history(): List<Pair<String, Track>> {
        val j = call("browse", JSONObject().put("browseId", "FEmusic_history"), auth = true)
        val out = mutableListOf<Pair<String, Track>>()
        sections(j).forEach { s ->
            s.optJSONObject("musicShelfRenderer")?.let { m ->
                val when_ = text(m.optJSONObject("title"))
                m.optJSONArray("contents")?.forEachObj { o -> (o.optJSONObject("musicResponsiveListItemRenderer")?.let(::listItem) as? Item.Song)?.let { out += when_ to it.track } }
            }
        }
        return out
    }

    /** Songs you liked on YouTube Music (signed in). */
    suspend fun liked(): List<Track> {
        val j = call("browse", JSONObject().put("browseId", "FEmusic_liked_videos"), auth = true)
        val out = mutableListOf<Track>()
        walk(j, "musicResponsiveListItemRenderer") { r -> (listItem(r) as? Item.Song)?.let { out += it.track } }
        return out
    }

    // MARK: parsing

    private fun sections(j: JSONObject): List<JSONObject> {
        val out = mutableListOf<JSONObject>()
        walk(j, "sectionListRenderer") { s -> s.optJSONArray("contents")?.forEachObj(out::add) }
        return out
    }

    private fun carousel(c: JSONObject, artist: String): Shelf {
        val header = c.optJSONObject("header")?.optJSONObject("musicCarouselShelfBasicHeaderRenderer")
        val items = mutableListOf<Item>()
        c.optJSONArray("contents")?.forEachObj { o ->
            o.optJSONObject("musicTwoRowItemRenderer")?.let { twoRow(it, artist) }?.let(items::add)
            o.optJSONObject("musicResponsiveListItemRenderer")?.let(::listItem)?.let(items::add)
            o.optJSONObject("musicNavigationButtonRenderer")?.let(::moodButton)?.let(items::add)
        }
        return Shelf(text(header?.optJSONObject("title")), items, text(header?.optJSONObject("strapline")))
    }

    private fun moodButton(b: JSONObject): Item? {
        val be = b.optJSONObject("clickCommand")?.optJSONObject("browseEndpoint") ?: return null
        return Item.Mood(be.optString("browseId"), be.optString("params"), text(b.optJSONObject("buttonText")),
            b.optJSONObject("solid")?.optLong("leftStripeColor") ?: 0xFF555555)
    }

    /** A tile: album, playlist, artist, or a song/video. */
    private fun twoRow(r: JSONObject, artist: String): Item? {
        val title = text(r.optJSONObject("title")).ifEmpty { return null }
        val sub = text(r.optJSONObject("subtitle"))
        val art = thumb(r.optJSONObject("thumbnailRenderer"))
        val nav = r.optJSONObject("navigationEndpoint") ?: return null
        browseItem(nav, title, sub, art, artist)?.let { return it }
        val id = nav.optJSONObject("watchEndpoint")?.optString("videoId")?.takeIf { it.isNotEmpty() } ?: return null
        val parts = sub.split(" • ")
        val by = parts.firstOrNull { p -> p !in setOf("Song", "Video", "Single", "EP") && !p.endsWith(" views") && !p.endsWith(" plays") } ?: artist
        return Item.Song(Track(Source.YOUTUBE, id, title, by, null, 0, art), sub, video = sub.contains(" views"))
    }

    private fun browseItem(nav: JSONObject, title: String, sub: String, art: String?, artist: String = ""): Item? {
        val be = nav.optJSONObject("browseEndpoint") ?: return null
        val id = be.optString("browseId").ifEmpty { return null }
        return when (be.optJSONObject("browseEndpointContextSupportedConfigs")?.optJSONObject("browseEndpointContextMusicConfig")?.optString("pageType")) {
            "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK" -> Item.Album(id, title, sub, art, artist.ifEmpty { sub.split(" • ").getOrNull(1) ?: "" })
            "MUSIC_PAGE_TYPE_PLAYLIST" -> Item.Playlist(id, title, sub, art)
            "MUSIC_PAGE_TYPE_ARTIST" -> Item.Artist(id, title, sub, art)
            else -> null
        }
    }

    /** A list row: a song or video (has a video id), else an artist / album / playlist link. */
    fun listItem(r: JSONObject): Item? {
        val cols = r.optJSONArray("flexColumns") ?: return null
        fun col(i: Int) = cols.optJSONObject(i)?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")?.optJSONObject("text")
        val first = col(0)?.optJSONArray("runs")?.optJSONObject(0) ?: return null
        val title = text(col(0))
        val art = thumb(r.optJSONObject("thumbnail"))
        val meta = col(1)?.optJSONArray("runs")
        val sub = text(col(1))
        val id = r.optJSONObject("playlistItemData")?.optString("videoId")?.takeIf { it.isNotEmpty() }
            ?: first.optJSONObject("navigationEndpoint")?.optJSONObject("watchEndpoint")?.optString("videoId")?.takeIf { it.isNotEmpty() }
        if (id == null) {
            val nav = r.optJSONObject("navigationEndpoint") ?: first.optJSONObject("navigationEndpoint") ?: return null
            return browseItem(nav, title, sub.substringAfter(" • ", sub), art)
        }
        val artists = mutableListOf<String>()
        var album: String? = null
        var duration = 0L
        for (i in 0 until (meta?.length() ?: 0)) {
            val run = meta!!.getJSONObject(i)
            val t = run.optString("text")
            val page = run.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
                ?.optJSONObject("browseEndpointContextSupportedConfigs")?.optJSONObject("browseEndpointContextMusicConfig")?.optString("pageType")
            when {
                page == "MUSIC_PAGE_TYPE_ARTIST" || page == "MUSIC_PAGE_TYPE_USER_CHANNEL" -> artists += t
                page == "MUSIC_PAGE_TYPE_ALBUM" -> album = t
                Regex("^\\d+:\\d{2}(:\\d{2})?$").matches(t) -> duration = dur(t)
            }
        }
        // Third column / fixed column: the album or the length on some pages.
        for (i in 2 until cols.length()) text(col(i)).takeIf { Regex("^\\d+:\\d{2}(:\\d{2})?$").matches(it) }?.let { duration = dur(it) }
        r.optJSONArray("fixedColumns")?.forEachObj { f ->
            text(f.optJSONObject("musicResponsiveListItemFixedColumnRenderer")?.optJSONObject("text")).takeIf { Regex("^\\d+:\\d{2}(:\\d{2})?$").matches(it) }?.let { duration = dur(it) }
        }
        val kind = meta?.optJSONObject(0)?.optString("text")
        if (artists.isEmpty()) sub.split(" • ").firstOrNull { it.isNotEmpty() && it !in setOf("Song", "Video", "Episode") && !Regex("^\\d+:\\d{2}").matches(it) }?.let { artists += it }
        return Item.Song(Track(Source.YOUTUBE, id, title, artists.joinToString(", "), album, duration, art), sub, video = kind == "Video" || sub.contains(" views"))
    }

    fun text(o: JSONObject?): String {
        val runs = o?.optJSONArray("runs") ?: return o?.optString("simpleText") ?: ""
        return (0 until runs.length()).joinToString("") { runs.optJSONObject(it)?.optString("text") ?: "" }
    }

    /** The largest thumbnail anywhere under [o], asked for at 544 px (Images picks the size it needs). */
    fun thumb(o: JSONObject?): String? {
        var best: String? = null
        if (o != null) walkAll(o) { k, v ->
            if (k == "thumbnails" && v is JSONArray && v.length() > 0 && best == null) best = v.optJSONObject(v.length() - 1)?.optString("url")
        }
        return best?.replace(Regex("=w\\d+-h\\d+"), "=w544-h544")?.replace(Regex("^//"), "https://")
    }

    private fun dur(t: String?): Long = t?.takeIf { Regex("^\\d+:\\d{2}(:\\d{2})?$").matches(it) }
        ?.split(':')?.fold(0L) { a, p -> a * 60 + (p.toLongOrNull() ?: 0) }?.times(1000) ?: 0

    /** Every object stored under [key] anywhere in the response (not looking inside a match). */
    fun walk(v: Any?, key: String, f: (JSONObject) -> Unit) {
        when (v) {
            is JSONObject -> v.keys().forEach { k ->
                val x = v.opt(k)
                if (k == key && x is JSONObject) f(x) else walk(x, key, f)
            }
            is JSONArray -> for (i in 0 until v.length()) walk(v.opt(i), key, f)
        }
    }

    private fun walkAll(v: Any?, f: (String, Any?) -> Unit) {
        when (v) {
            is JSONObject -> v.keys().forEach { k -> val x = v.opt(k); f(k, x); walkAll(x, f) }
            is JSONArray -> for (i in 0 until v.length()) walkAll(v.opt(i), f)
        }
    }

    private inline fun JSONArray.forEachObj(f: (JSONObject) -> Unit) { for (i in 0 until length()) optJSONObject(i)?.let(f) }
}
