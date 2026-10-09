package local.wreckbox.player

import android.content.ContentUris
import android.content.Context
import android.provider.MediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.Normalizer

/**
 * One search across the phone, YouTube Music and Spotify, merged into the nearest results.
 *  - YouTube Music: its own web API (the one music.youtube.com uses — no key). It also matches lyrics, so a line from
 *    a song finds it.
 *  - Spotify: the signed-in web player's search page, read by the hidden search page (SpotifySearch in WebEngine).
 *  - Phone: the music Android knows about (MediaStore).
 */
object Search {
    /** The merged results, plus which services couldn't be reached (offline, signed out, timed out) so the page can say so. */
    class Found(val tracks: List<Track>, val failed: List<String>)

    suspend fun all(c: Context, q: String): Found = coroutineScope {
        val failed = java.util.Collections.synchronizedList(mutableListOf<String>())
        val yt = async(Dispatchers.IO) { runCatching { youtube(q) }.getOrElse { failed += "YouTube Music"; emptyList() } }
        val sp = async { withTimeoutOrNull(15_000) { runCatching { SpotifySearch.get(c).search(q) }.getOrNull() } ?: run { failed += "Spotify"; emptyList() } }
        val local = async(Dispatchers.IO) { runCatching { Local.search(c, q) }.getOrDefault(emptyList()) }
        Found(rank(q, local.await() + yt.await() + sp.await()), failed.toList())
    }

    /** Words that mark something other than the original song — skipped unless the search asks for them. */
    private val noise = setOf("cover", "karaoke", "instrumental", "8 bit", "dance", "choreography", "tutorial", "reaction",
        "slowed", "reverb", "sped up", "nightcore", "originally performed", "tribute", "lesson", "piano version", "status")

    /**
     * Nearest first: every typed word should be in the title or artist; the artist field matching counts extra
     * (so "liggi ritviz" puts Ritviz's Liggi above covers titled "Liggi - Ritviz"); covers, karaoke, dance videos
     * and the like drop unless asked for; titles with lots of extra words drop a little. Ties keep the services' order.
     */
    fun rank(q: String, list: List<Track>): List<Track> {
        val nq = norm(q)
        val words = nq.split(' ').filter { it.isNotEmpty() }
        fun score(t: Track): Double {
            val title = norm(t.title)
            val artist = norm(t.artist)
            val all = "$title $artist ${norm(t.album ?: "")}"
            val tw = title.split(' ').filter { it.isNotEmpty() }
            var s = words.count { all.contains(it) }.toDouble() / words.size.coerceAtLeast(1)
            if (words.any { it.length > 2 && artist.contains(it) }) s += 0.6
            if (title == nq || words.all { title.contains(it) } && tw.size <= words.size + 1) s += 0.5
            s -= 0.4 * tw.count { w -> words.none { w.contains(it) } }.toDouble() / tw.size.coerceAtLeast(1)
            if (noise.any { all.contains(it) && !nq.contains(it) }) s -= 1.0
            if (t.source == Source.LOCAL) s += 0.2
            return s
        }
        return list.withIndex().sortedWith(compareByDescending<IndexedValue<Track>> { score(it.value) }.thenBy { it.index }).map { it.value }
    }

    fun norm(s: String) = Normalizer.normalize(s.lowercase(), Normalizer.Form.NFD)
        .replace(Regex("\\p{M}"), "").replace(Regex("[^\\p{L}\\p{N} ]"), " ").replace(Regex("\\s+"), " ").trim()

    // MARK: YouTube Music

    private const val SONGS = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    private const val VIDEOS = "EgWKAQIQAWoMEA4QChADEAQQCRAF"

    suspend fun youtube(q: String): List<Track> = coroutineScope {
        val songs = async { ytQuery(q, SONGS) }
        val videos = async { ytQuery(q, VIDEOS).take(5) }
        (songs.await() + videos.await()).distinctBy { it.id }
    }

    private suspend fun ytQuery(q: String, params: String): List<Track> = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("context", JSONObject().put("client", JSONObject().put("clientName", "WEB_REMIX").put("clientVersion", "1.20251001.01.00").put("hl", "en")))
            .put("query", q).put("params", params)
        val c = URL("https://music.youtube.com/youtubei/v1/search?prettyPrint=false").openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.doOutput = true
        c.connectTimeout = 10_000
        c.readTimeout = 15_000
        c.setRequestProperty("Content-Type", "application/json")
        c.setRequestProperty("Origin", "https://music.youtube.com")
        c.setRequestProperty("User-Agent", WebEngine.userAgent())
        c.outputStream.use { it.write(body.toString().toByteArray()) }
        val text = c.inputStream.bufferedReader().use { it.readText() }
        val out = mutableListOf<Track>()
        walk(JSONObject(text)) { r -> ytItem(r)?.let(out::add) }
        out
    }

    /** Every musicResponsiveListItemRenderer anywhere in the response. */
    private fun walk(v: Any?, f: (JSONObject) -> Unit) {
        when (v) {
            is JSONObject -> {
                v.optJSONObject("musicResponsiveListItemRenderer")?.let { f(it); return }
                v.keys().forEach { walk(v.opt(it), f) }
            }
            is JSONArray -> for (i in 0 until v.length()) walk(v.opt(i), f)
        }
    }

    private fun ytItem(r: JSONObject): Track? {
        val cols = r.optJSONArray("flexColumns") ?: return null
        fun runs(i: Int) = cols.optJSONObject(i)?.optJSONObject("musicResponsiveListItemFlexColumnRenderer")?.optJSONObject("text")?.optJSONArray("runs")
        val title = runs(0)?.optJSONObject(0)?.optString("text") ?: return null
        val id = r.optJSONObject("playlistItemData")?.optString("videoId")?.takeIf { it.isNotEmpty() }
            ?: runs(0)?.optJSONObject(0)?.optJSONObject("navigationEndpoint")?.optJSONObject("watchEndpoint")?.optString("videoId")?.takeIf { it.isNotEmpty() }
            ?: return null
        val artists = mutableListOf<String>()
        var album: String? = null
        var duration = 0L
        val meta = runs(1)
        for (i in 0 until (meta?.length() ?: 0)) {
            val run = meta!!.getJSONObject(i)
            val text = run.optString("text")
            val page = run.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
                ?.optJSONObject("browseEndpointContextSupportedConfigs")?.optJSONObject("browseEndpointContextMusicConfig")?.optString("pageType")
            when {
                page == "MUSIC_PAGE_TYPE_ARTIST" || page == "MUSIC_PAGE_TYPE_USER_CHANNEL" -> artists += text
                page == "MUSIC_PAGE_TYPE_ALBUM" -> album = text
                Regex("^\\d+:\\d{2}(:\\d{2})?$").matches(text) -> duration = text.split(':').fold(0L) { a, p -> a * 60 + p.toLong() } * 1000
            }
        }
        if (artists.isEmpty()) meta?.optJSONObject(0)?.optString("text")?.takeIf { it !in setOf("Song", "Video") }?.let { artists += it }
        val thumbs = r.optJSONObject("thumbnail")?.optJSONObject("musicThumbnailRenderer")?.optJSONObject("thumbnail")?.optJSONArray("thumbnails")
        val art = thumbs?.optJSONObject(thumbs.length() - 1)?.optString("url")
            ?.replace(Regex("=w\\d+-h\\d+"), "=w544-h544")
        return Track(Source.YOUTUBE, id, title, artists.joinToString(", "), album, duration, art)
    }
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
