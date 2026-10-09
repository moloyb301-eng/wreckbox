package local.wreckbox.player

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Song radio, the way YouTube Music does it: every song has a radio mix ("RDAMVM" + its video id) that YouTube's
 * recommender fills with similar music — the same queue its own app plays after a song. No key, no account needed.
 *
 * A Spotify or phone song is first found on YouTube Music (title + artist) to seed its radio. Songs from the mix that
 * are already on the phone play from the phone's copy.
 */
object Radio {
    /** Similar songs to [seed], minus anything in [exclude] (track keys or "title|artist" names). */
    suspend fun similar(c: Context, seed: Track, exclude: Set<String>, max: Int = 25): List<Track> = withContext(Dispatchers.IO) {
        val id = if (seed.source == Source.YOUTUBE) seed.id else findOnYouTube(seed) ?: return@withContext emptyList()
        val mix = next(id).filter { it.id != id }
        // Phone copies by name, so a song you have plays from the file.
        val local = runCatching { Local.cached(c) }.getOrDefault(emptyList()).associateBy { name(it) }
        val seen = exclude.toMutableSet().apply { add(name(seed)) }
        mix.mapNotNull { t ->
            val n = name(t)
            if (t.key in seen || n in seen) return@mapNotNull null
            seen += n
            local[n] ?: t
        }.take(max)
    }

    /** "title|first artist", normalised — the same song across sources. */
    fun name(t: Track) = Search.norm(t.title.substringBefore(" (feat").substringBefore(" - ")) + "|" +
        Search.norm(t.artist.split(",", "&", " x ", " feat").first())

    /** The YouTube Music song for a Spotify / phone track: the best-ranked search hit with the same name. */
    private suspend fun findOnYouTube(t: Track): String? {
        val hits = runCatching { Search.youtube("${t.title} ${t.artist}") }.getOrDefault(emptyList())
        return (hits.firstOrNull { name(it) == name(t) } ?: Search.rank("${t.title} ${t.artist}", hits).firstOrNull())?.id
    }

    /** YouTube Music's "next" for the song's radio playlist: its up-next panel, ~50 songs. */
    private fun next(videoId: String): List<Track> {
        val body = JSONObject()
            .put("context", JSONObject().put("client", JSONObject().put("clientName", "WEB_REMIX").put("clientVersion", "1.20251001.01.00").put("hl", "en")))
            .put("videoId", videoId).put("playlistId", "RDAMVM$videoId").put("params", "wAEB").put("isAudioOnly", true)
        val c = URL("https://music.youtube.com/youtubei/v1/next?prettyPrint=false").openConnection() as HttpURLConnection
        c.requestMethod = "POST"
        c.doOutput = true
        c.connectTimeout = 10_000
        c.readTimeout = 15_000
        c.setRequestProperty("Content-Type", "application/json")
        c.setRequestProperty("Origin", "https://music.youtube.com")
        c.setRequestProperty("User-Agent", WebEngine.userAgent())
        c.outputStream.use { it.write(body.toString().toByteArray()) }
        val out = mutableListOf<Track>()
        walk(JSONObject(c.inputStream.bufferedReader().use { it.readText() })) { r -> item(r)?.let(out::add) }
        return out
    }

    private fun walk(v: Any?, f: (JSONObject) -> Unit) {
        when (v) {
            is JSONObject -> {
                v.optJSONObject("playlistPanelVideoRenderer")?.let { f(it); return }
                v.keys().forEach { walk(v.opt(it), f) }
            }
            is JSONArray -> for (i in 0 until v.length()) walk(v.opt(i), f)
        }
    }

    /** One song of the panel: "Artist • Album • Year" byline; fan uploads ("… views") are skipped. */
    private fun item(r: JSONObject): Track? {
        val id = r.optString("videoId").ifEmpty { return null }
        val title = r.optJSONObject("title")?.optJSONArray("runs")?.optJSONObject(0)?.optString("text") ?: return null
        val runs = r.optJSONObject("longBylineText")?.optJSONArray("runs") ?: JSONArray()
        val parts = (0 until runs.length()).map { runs.getJSONObject(it) }
        if (parts.any { it.optString("text").endsWith(" views") }) return null
        val artists = mutableListOf<String>()
        var album: String? = null
        for (p in parts) {
            val page = p.optJSONObject("navigationEndpoint")?.optJSONObject("browseEndpoint")
                ?.optJSONObject("browseEndpointContextSupportedConfigs")?.optJSONObject("browseEndpointContextMusicConfig")?.optString("pageType")
            when (page) {
                "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL" -> artists += p.optString("text")
                "MUSIC_PAGE_TYPE_ALBUM" -> album = p.optString("text")
            }
        }
        if (artists.isEmpty()) parts.firstOrNull()?.optString("text")?.let { artists += it }
        val length = r.optJSONObject("lengthText")?.optJSONArray("runs")?.optJSONObject(0)?.optString("text") ?: ""
        val ms = if (Regex("^\\d+:\\d{2}(:\\d{2})?$").matches(length)) length.split(':').fold(0L) { a, x -> a * 60 + x.toLong() } * 1000 else 0
        val thumbs = r.optJSONObject("thumbnail")?.optJSONArray("thumbnails")
        val art = thumbs?.optJSONObject(thumbs.length() - 1)?.optString("url")?.replace(Regex("=w\\d+-h\\d+"), "=w544-h544")
        return Track(Source.YOUTUBE, id, title, artists.joinToString(", "), album, ms, art)
    }
}
