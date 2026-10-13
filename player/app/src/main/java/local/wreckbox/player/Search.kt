package local.wreckbox.player

import android.content.ContentUris
import android.content.Context
import android.provider.MediaStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.text.Normalizer
import kotlin.math.ln

/** A song in the results: the copy that plays, the same song from the other sources, whether it's a video upload. */
data class Hit(val track: Track, val alts: List<Track> = emptyList(), val video: Boolean = false)

/**
 * One search across the phone, YouTube Music and Spotify, with our own ranking.
 *
 *  - Candidates: the on-phone index (your files, likes, playlists, history — instant, offline), YouTube Music (its own
 *    web API, no key; also matches lyrics; gives the top result, artists, albums, playlists and its spelling fix), and
 *    Spotify (the signed-in web player's search page, read by the hidden SpotifySearch page).
 *  - Understanding: MusicBrainz says which artist the words mean, spelled right, with their other names; a fixed
 *    spelling is searched too.
 *  - Results arrive as each source answers ([stream]); the same song from several sources is one row that plays the
 *    best copy (phone file first).
 *  - Ranking ([score]): words matched (typo- and spelling-tolerant), the artist matching, the original over covers /
 *    live / remixes / lyric videos unless asked, official songs over video uploads, and you — songs and artists you
 *    play and like, and which result you picked last time you searched the same thing.
 */
object Search {
    class Results(
        val query: String,
        val top: Item? = null,
        val hits: List<Hit> = emptyList(),
        val artists: List<Item.Artist> = emptyList(),
        val albums: List<Item.Album> = emptyList(),
        val playlists: List<Item.Playlist> = emptyList(),
        /** A spelling fix that was searched as well ("Showing results for …"). */
        val corrected: String? = null,
        /** Services that couldn't be reached (offline, signed out, timed out). */
        val failed: List<String> = emptyList(),
        val done: Boolean = false,
    )

    /** The results so far, again each time a source answers; the last one has done = true. */
    fun stream(c: Context, q: String): Flow<Results> = channelFlow {
        val started = System.currentTimeMillis()
        val lock = Mutex()
        val tracks = mutableListOf<Pair<Track, Boolean>>() // (track, is a video upload)
        var top: Item? = null
        val artists = mutableListOf<Item.Artist>()
        val albums = mutableListOf<Item.Album>()
        val playlists = mutableListOf<Item.Playlist>()
        var corrected: String? = null
        var mb: MusicBrainz.Artist? = null
        val failed = mutableListOf<String>()
        var pending = 1 // until every source has been started
        val times = mutableListOf<String>()
        // Scores are worked out once per song; a new scoring (and a fresh memo) only when the meaning changes
        // (a spelling fix, MusicBrainz's artist).
        var scoring = Scoring(c, q, null)

        suspend fun publish() {
            if (scoring.q != (corrected ?: q) || scoring.mb != mb) scoring = Scoring(c, corrected ?: q, mb)
            val hits = withContext(Dispatchers.Default) { rank(scoring, tracks) }
            send(Results(q, top, hits, artists.distinctBy { it.id }, albums.distinctBy { it.id }, playlists.distinctBy { it.id }, corrected, failed.toList(), pending == 0))
        }

        suspend fun add(f: suspend () -> Unit) { lock.withLock { f(); publish() } }

        fun source(name: String, report: Boolean, work: suspend () -> Unit) {
            pending++
            launch {
                val ok = runCatching { work() }.isSuccess
                lock.withLock {
                    pending--
                    times += "$name ${System.currentTimeMillis() - started}ms${if (ok) "" else " (failed)"}"
                    if (!ok && report) failed += name
                    publish()
                }
            }
        }

        // The network first (so it's under way while the phone searches itself), YouTube before anything else. Both
        // YouTube searches are shared with search-while-typing: if typing already started them, they're reused.
        source("YouTube Music", true) {
            val r = YtCache.mixed(q).await()
            add {
                top = r.top
                tracks += r.songs.map { it.track to it.video }
                artists += r.artists; albums += r.albums; playlists += r.playlists
                if (r.corrected != null && Search.norm(r.corrected) != Search.norm(q)) corrected = r.corrected
            }
        }
        // YouTube Music, songs only: more of them than the mixed list has.
        source("YouTube songs", false) {
            val songs = YtCache.songs(q).await()
            add { tracks += songs.map { it to false } }
        }
        if (LoginActivity.signedIn(Service.SPOTIFY)) source("Spotify", true) {
            // The hidden page is a WebView: main thread.
            val found = withContext(Dispatchers.Main) { withTimeoutOrNull(15_000) { SpotifySearch.get(c).search(q) } } ?: error("timed out")
            add { tracks += found.map { it to false } }
        }
        // MusicBrainz: the artist meant, with their other names; a misspelt artist is searched again spelled right.
        source("MusicBrainz", false) {
            val a = MusicBrainz.artist(c, q) ?: return@source
            lock.withLock { mb = a }
            val nq = Search.norm(q)
            if (a.names.none { it == nq || nq.contains(it) } && corrected == null) {
                val fixed = a.name
                lock.withLock { corrected = fixed; publish() }
                val more = runCatching { YtCache.mixed(fixed).await() }.getOrNull()
                if (more != null) add {
                    if (top == null) top = more.top
                    tracks += more.songs.map { it.track to it.video }
                    artists += more.artists; albums += more.albums
                }
            } else lock.withLock { publish() }
        }
        // Your own music: on the phone, instant.
        val mine = withContext(Dispatchers.Default) { SearchIndex.search(c, q) }
        lock.withLock {
            tracks.addAll(0, mine.map { it to false })
            times += "phone ${System.currentTimeMillis() - started}ms"
            pending--
            publish()
        }
        // Wait for the rest, then log how long each took (test builds).
        while (true) { val p = lock.withLock { pending }; if (p == 0) break; kotlinx.coroutines.delay(50) }
        Debug.log("search \"$q\": ${times.joinToString(", ")}")
    }

    /**
     * YouTube Music searches, shared between search-while-typing and the full search, kept 10 minutes: typing starts
     * them, Enter reuses them (often already answered). A failed one is forgotten so the next try asks again.
     */
    object YtCache {
        private class Entry<T>(val at: Long, val job: Deferred<T>)
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        private val mixed = object : LinkedHashMap<String, Entry<YouTubeMusic.Results>>(32, 0.75f, true) {
            override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Entry<YouTubeMusic.Results>>?) = size > 40
        }
        private val songs = object : LinkedHashMap<String, Entry<List<Track>>>(32, 0.75f, true) {
            override fun removeEldestEntry(e: MutableMap.MutableEntry<String, Entry<List<Track>>>?) = size > 40
        }

        @Synchronized fun mixed(q: String): Deferred<YouTubeMusic.Results> = get(mixed, q) { YouTubeMusic.search(q) }
        @Synchronized fun songs(q: String): Deferred<List<Track>> = get(songs, q) { youtube(q) }

        private fun <T> get(map: LinkedHashMap<String, Entry<T>>, q: String, f: suspend () -> T): Deferred<T> {
            val k = norm(q)
            map[k]?.let { e ->
                val stale = System.currentTimeMillis() - e.at > 10 * 60_000L
                val broken = e.job.isCompleted && e.job.getCompletionExceptionOrNull() != null
                if (!stale && !broken) return e.job
            }
            return scope.async { f() }.also { map[k] = Entry(System.currentTimeMillis(), it) }
        }
    }

    /** Words that mark something other than the original song — ranked down unless the search asks for them. */
    private val noise = listOf("cover", "karaoke", "instrumental", "8 bit", "dance", "choreography", "tutorial", "reaction",
        "slowed", "reverb", "sped up", "nightcore", "originally performed", "tribute", "lesson", "piano version", "status",
        "live", "remix", "mashup", "lofi", "lo fi", "8d", "lyrics", "lyrical", "bass boosted", "extended", "unplugged", "acoustic", "whatsapp")
        .map { it to Regex("\\b$it\\b") }

    /** Merges the same song from several sources into one hit and puts the nearest first. */
    private fun rank(ctx: Scoring, list: List<Pair<Track, Boolean>>): List<Hit> {
        val groups = LinkedHashMap<String, MutableList<Pair<Track, Boolean>>>()
        list.forEach { (t, v) -> groups.getOrPut(Radio.name(t)) { mutableListOf() }.let { g -> if (g.none { it.first.key == t.key }) g += t to v } }
        return groups.values.map { g ->
            // The copy that plays: phone file, then the official YouTube Music song, then Spotify, then a video upload.
            val sorted = g.sortedBy { (t, v) -> when { t.source == Source.LOCAL -> 0; t.source == Source.YOUTUBE && !v -> 1; t.source == Source.SPOTIFY -> 2; else -> 3 } }
            val (main, video) = sorted.first()
            val best = g.maxOf { (t, v) -> ctx.memo.getOrPut("${t.key}|$v") { score(ctx, t, v) } }
            Hit(main.copy(art = main.art ?: g.firstNotNullOfOrNull { it.first.art }, album = main.album ?: g.firstNotNullOfOrNull { it.first.album }),
                sorted.drop(1).map { it.first }, video) to best
        }.withIndex().sortedWith(compareByDescending<IndexedValue<Pair<Hit, Double>>> { it.value.second }.thenBy { it.index }).map { it.value.first }
    }

    /** The songs for a query, merged and ranked (search-while-typing's preview). */
    fun rank(c: Context, q: String, list: List<Pair<Track, Boolean>>): List<Hit> = rank(Scoring(c, q, null), list)

    /** For radio: plain tracks, nearest first (no personal ranking, no merging). */
    fun rank(q: String, list: List<Track>): List<Track> {
        val ctx = Scoring(null, q, null)
        return list.withIndex().sortedWith(compareByDescending<IndexedValue<Track>> { score(ctx, it.value, false) }.thenBy { it.index }).map { it.value }
    }

    private class Scoring(c: Context?, val q: String, val mb: MusicBrainz.Artist?) {
        val memo = HashMap<String, Double>()
        val nq = norm(Fuzzy.devanagari(q))
        val words = nq.split(' ').filter { it.isNotEmpty() }
        val history = c?.let { History.get(it) }
        val liked = c?.let { Library.get(it).data.value.likes.map { t -> t.key }.toSet() } ?: emptySet()
        val clicks = c?.let { Clicks.forQuery(it, q) } ?: emptyMap()
        /** The typed words that are the artist's name (or one of their other names). */
        val artistWords = mb?.names?.firstOrNull { n -> nq.contains(n) }?.split(' ')?.toSet() ?: emptySet()
    }

    private fun score(x: Scoring, t: Track, video: Boolean): Double {
        val title = norm(Fuzzy.devanagari(t.title))
        val artist = norm(Fuzzy.devanagari(t.artist))
        val tw = title.split(' ').filter { it.isNotEmpty() }
        val aw = artist.split(' ').filter { it.isNotEmpty() }
        val alw = norm(t.album ?: "").split(' ').filter { it.isNotEmpty() }
        var matched = 0.0
        var artistHit = false
        x.words.forEachIndexed { i, w ->
            val last = i == x.words.lastIndex
            val inTitle = tw.maxOfOrNull { Fuzzy.word(w, it, last) } ?: 0.0
            var inArtist = aw.maxOfOrNull { Fuzzy.word(w, it, last) } ?: 0.0
            // A word of the artist's other name (MusicBrainz) counts as the artist when the track's artist is them.
            if (inArtist == 0.0 && w in x.artistWords && x.mb != null && x.mb.names.any { n -> artist.contains(n) }) inArtist = 0.9
            val inAlbum = (alw.maxOfOrNull { Fuzzy.word(w, it, last) } ?: 0.0) * 0.8
            if (w.length > 2 && inArtist >= 0.7 && inArtist >= inTitle) artistHit = true
            matched += maxOf(inTitle, inArtist, inAlbum)
        }
        var s = matched / x.words.size.coerceAtLeast(1)
        if (artistHit) s += 0.6
        if (x.mb != null && x.mb.names.any { n -> artist.contains(n) }) s += 0.3
        if (title == x.nq || x.words.all { w -> tw.any { Fuzzy.word(w, it, false) > 0 } } && tw.size <= x.words.size + 1) s += 0.5
        s -= 0.4 * tw.count { w -> x.words.none { w.contains(it) } }.toDouble() / tw.size.coerceAtLeast(1)
        val all = "$title $artist"
        if (noise.any { (n, re) -> !x.nq.contains(n) && re.containsMatchIn(all) }) s -= 1.0
        if (video && !t.artist.endsWith("VEVO") && !t.artist.endsWith(" - Topic")) s -= 0.3
        if (t.source == Source.LOCAL) s += 0.2
        // You: liked, played (and not skipped), your artists, and what you picked for this search before.
        if (t.key in x.liked) s += 0.4
        x.history?.let { h ->
            h.stat(t)?.let { st -> s += (st.score * 0.1).coerceIn(-0.4, 0.5) }
            s += (ln(1 + h.artistScore(t.artist).coerceAtLeast(0.0)) * 0.15).coerceAtMost(0.45)
        }
        x.clicks[Radio.name(t)]?.let { s += 0.8 * it.coerceAtMost(3) }
        return s
    }

    fun norm(s: String) = Normalizer.normalize(s.lowercase(), Normalizer.Form.NFD)
        .replace(Regex("\\p{M}"), "").replace(Regex("[^\\p{L}\\p{N} ]"), " ").replace(Regex("\\s+"), " ").trim()

    // MARK: YouTube Music songs (also used by radio)

    private const val SONGS = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    private const val VIDEOS = "EgWKAQIQAWoMEA4QChADEAQQCRAF"

    suspend fun youtube(q: String): List<Track> = coroutineScope {
        val songs = async { ytQuery(q, SONGS) }
        val videos = async { ytQuery(q, VIDEOS).take(5) }
        (songs.await() + videos.await()).distinctBy { it.id }
    }

    private suspend fun ytQuery(q: String, params: String): List<Track> {
        val j = YouTubeMusic.call("search", JSONObject().put("query", q).put("params", params))
        val out = mutableListOf<Track>()
        YouTubeMusic.walk(j, "musicResponsiveListItemRenderer") { r -> (YouTubeMusic.listItem(r) as? Item.Song)?.let { out += it.track } }
        return out
    }
}

/** Which result you played after searching something: picked again, it ranks first next time. */
object Clicks {
    private fun prefs(c: Context) = c.getSharedPreferences("search", Context.MODE_PRIVATE)

    fun forQuery(c: Context, q: String): Map<String, Int> {
        val o = runCatching { JSONObject(prefs(c).getString("clicks", "{}")!!) }.getOrNull()?.optJSONObject(Search.norm(q)) ?: return emptyMap()
        return o.keys().asSequence().associateWith { o.optInt(it) }
    }

    fun picked(c: Context, q: String, t: Track) {
        if (q.isBlank()) return
        val all = runCatching { JSONObject(prefs(c).getString("clicks", "{}")!!) }.getOrDefault(JSONObject())
        val k = Search.norm(q)
        val o = all.optJSONObject(k) ?: JSONObject()
        val n = Radio.name(t)
        o.put(n, o.optInt(n) + 1)
        all.put(k, o)
        // Keep the newest 300 searches.
        if (all.length() > 300) all.keys().asSequence().toList().take(all.length() - 300).forEach { all.remove(it) }
        prefs(c).edit().putString("clicks", all.toString()).apply()
    }
}

/** The searches you made, newest first (the empty Search page lists them). */
object RecentSearches {
    private fun prefs(c: Context) = c.getSharedPreferences("search", Context.MODE_PRIVATE)

    fun all(c: Context): List<String> = runCatching { JSONArray(prefs(c).getString("recent", "[]")!!) }.getOrNull()
        ?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()

    fun add(c: Context, q: String) = save(c, (listOf(q.trim()) + all(c).filter { !it.equals(q.trim(), ignoreCase = true) }).take(20))
    fun remove(c: Context, q: String) = save(c, all(c).filter { it != q })
    fun clear(c: Context) = save(c, emptyList())
    private fun save(c: Context, l: List<String>) = prefs(c).edit().putString("recent", JSONArray(l).toString()).apply()
}

/** Music files Android has indexed on this phone. */
object Local {
    fun all(c: Context): List<Track> = query(c, null, null)

    /** The phone's songs, read once and kept (Home, search and radio share it); [refresh] after a rescan. */
    @Volatile private var cache: List<Track>? = null
    fun cached(c: Context): List<Track> = cache ?: all(c).also { cache = it }
    fun refresh(c: Context): List<Track> = all(c).also { cache = it }

    /** Folders are re-indexed at most twice a day (it's disk work), or when asked. */
    fun scanDue(c: Context) = System.currentTimeMillis() - c.getSharedPreferences("settings", Context.MODE_PRIVATE).getLong("lastScan", 0) > 12 * 3600_000L

    /**
     * Asks Android to index Music/ and Download/ (files moved there by other apps — e.g. the WreckBox app's
     * Tracks/ — aren't always in its index). Calls back when done.
     */
    fun rescan(c: Context, done: () -> Unit) {
        val root = android.os.Environment.getExternalStorageDirectory().path
        val dirs = arrayOf("$root/Music", "$root/Download")
        var left = dirs.size
        c.getSharedPreferences("settings", Context.MODE_PRIVATE).edit().putLong("lastScan", System.currentTimeMillis()).apply()
        android.media.MediaScannerConnection.scanFile(c, dirs, null) { _, _ -> if (--left == 0) done() }
    }

    fun search(c: Context, q: String): List<Track> {
        val words = Search.norm(q).split(' ').filter { it.isNotEmpty() }
        return cached(c).filter { t -> val s = Search.norm("${t.title} ${t.artist} ${t.album ?: ""}"); words.all { s.contains(it) } }
    }

    /** Folders that hold chat audio, recordings and system sounds, not music. */
    private val notMusicDirs = listOf("whatsapp", "telegram", "signal", "recordings", "recorder", "call", "voice", "ringtones",
        "notifications", "alarms", "sounds", "podcasts", "audiobooks", "android/media")
    /** Names chat apps and recorders give files: AUD-20190301-WA0012, PTT-…, a bare timestamp, "recording (3)". */
    private val notMusicName = Regex("^(aud|ptt)-\\d{8}-wa\\d+.*|^(recording|voice|call|rec)[ _-]*(\\(\\d+\\)|\\d+)\\S*(\\.\\w+)?$|^\\d{6,}(\\.\\w+)?$", RegexOption.IGNORE_CASE)

    /** Only music: no ringtones, notification sounds, alarms, recordings, chat audio or voice notes, nothing under a minute. */
    private fun query(c: Context, sel: String?, args: Array<String>?): List<Track> {
        val out = mutableListOf<Track>()
        val cols = arrayOf(MediaStore.Audio.Media._ID, MediaStore.Audio.Media.TITLE, MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM, MediaStore.Audio.Media.DURATION, MediaStore.Audio.Media.RELATIVE_PATH,
            MediaStore.Audio.Media.DISPLAY_NAME, MediaStore.Audio.Media.MIME_TYPE, MediaStore.Audio.Media.SIZE) +
            (if (android.os.Build.VERSION.SDK_INT >= 30) arrayOf(MediaStore.Audio.Media.BITRATE) else emptyArray()) +
            (if (android.os.Build.VERSION.SDK_INT >= 34) arrayOf(MediaStore.Audio.Media.SAMPLERATE, MediaStore.Audio.Media.BITS_PER_SAMPLE) else emptyArray())
        var where = "${MediaStore.Audio.Media.IS_MUSIC} != 0 AND ${MediaStore.Audio.Media.DURATION} >= 60000" +
            " AND ${MediaStore.Audio.Media.IS_RINGTONE} = 0 AND ${MediaStore.Audio.Media.IS_NOTIFICATION} = 0" +
            " AND ${MediaStore.Audio.Media.IS_ALARM} = 0 AND ${MediaStore.Audio.Media.IS_PODCAST} = 0"
        if (android.os.Build.VERSION.SDK_INT >= 31) where += " AND ${MediaStore.Audio.Media.IS_RECORDING} = 0"
        if (android.os.Build.VERSION.SDK_INT >= 29) where += " AND ${MediaStore.Audio.Media.IS_AUDIOBOOK} = 0"
        c.contentResolver.query(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, cols, where + (sel?.let { " AND $it" } ?: ""),
            args, "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE")?.use { cur ->
            while (cur.moveToNext()) {
                val dir = (cur.getString(5) ?: "").lowercase()
                val title = cur.getString(1) ?: ""
                val file = cur.getString(6) ?: ""
                if (notMusicDirs.any { dir.contains(it) } || notMusicName.matches(title) || notMusicName.matches(file)) continue
                val id = cur.getLong(0)
                val uri = ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
                val t = Track(Source.LOCAL, uri.toString(), title, (cur.getString(2) ?: "").replace("<unknown>", ""),
                    // Files with no album tag come back with their folder's name as the album: not an album.
                    cur.getString(3)?.takeIf { it != "<unknown>" && !it.equals(dir.trimEnd('/').substringAfterLast('/'), ignoreCase = true) },
                    cur.getLong(4), "$uri/albumart")
                fun col(n: String) = cur.getColumnIndex(n).takeIf { it >= 0 }
                Quality.put(t, Quality.label(cur.getString(7), file, cur.getLong(8), cur.getLong(4),
                    col(MediaStore.Audio.Media.BITRATE)?.let { cur.getLong(it) } ?: 0,
                    col(MediaStore.Audio.Media.SAMPLERATE)?.let { cur.getInt(it) } ?: 0,
                    col(MediaStore.Audio.Media.BITS_PER_SAMPLE)?.let { cur.getInt(it) } ?: 0))
                out += t
            }
        }
        return out
    }
}
