package local.wreckbox.player

import android.content.Context
import android.net.Uri
import android.util.JsonReader
import android.util.JsonToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.InputStream
import java.io.InputStreamReader
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.zip.ZipInputStream

/**
 * Brings your listening history in, so search and Home know your taste from day one:
 *  - YouTube Music (signed in): your history page (the last few months) and liked songs.
 *  - Spotify (signed in): Liked Songs, your profile's top tracks this month and top artists — read from the signed-in web
 *    player's pages (SpotifySearch), no developer key. (Spotify's Web API refuses the web player's token, so no plays.)
 *  - A data export file, for everything you ever played: Spotify's "Extended streaming history" (or the shorter
 *    "Account data"), or Google Takeout's YouTube watch-history.json. Zip or the JSON files themselves.
 * Everything stays on the phone (History). The services are read again at most twice a day ([auto]).
 */
object Import {
    /** A line for Settings: what's importing / what the last import found. */
    val status = MutableStateFlow<String?>(null)

    private fun prefs(c: Context) = c.getSharedPreferences("import", Context.MODE_PRIVATE)

    /** On app start: read each signed-in service again if it's been 12 hours. */
    suspend fun auto(c: Context): Int {
        val p = prefs(c)
        val now = System.currentTimeMillis()
        var added = 0
        if (LoginActivity.signedIn(Service.YOUTUBE) && now - p.getLong("ytAt", 0) > 12 * 3600_000L)
            runCatching { added += youtube(c) }.onFailure { Debug.log("import youtube failed: $it") }
        if (LoginActivity.signedIn(Service.SPOTIFY) && now - p.getLong("spAt", 0) > 12 * 3600_000L)
            runCatching { added += spotify(c) }.onFailure { Debug.log("import spotify failed: $it") }
        Debug.log("import: ${status.value}")
        return added
    }

    /** YouTube Music history + likes. Returns how many new plays were added. */
    suspend fun youtube(c: Context): Int {
        status.value = "Reading your YouTube Music history…"
        val h = History.get(c)
        val items = YouTubeMusic.history()
        val liked = runCatching { YouTubeMusic.liked() }.getOrDefault(emptyList())
        // The page has no times, only "Today", "Yesterday", "This week"…: only the songs above the newest one we saw last
        // time are new, and each gets a time inside its section.
        val p = prefs(c)
        val lastTop = p.getString("ytTop", null)
        val fresh = items.takeWhile { it.second.id != lastTop }
        val now = System.currentTimeMillis()
        val plays = fresh.mapIndexed { i, (section, t) -> History.Play(t, sectionTime(section, now) - i * 60_000L, t.durationMs) }
        val added = h.importPlays("youtube", plays, newerOnly = false)
        h.importFavourites("youtube-liked", liked, 1.0)
        p.edit().putLong("ytAt", now).apply { items.firstOrNull()?.let { putString("ytTop", it.second.id) } }.apply()
        status.value = "YouTube Music: $added new plays, ${liked.size} liked songs"
        return added
    }

    private fun sectionTime(section: String, now: Long): Long {
        val day = 86_400_000L
        return when (section.lowercase()) {
            "today" -> now
            "yesterday" -> now - day
            "this week" -> now - 3 * day
            "last week" -> now - 10 * day
            else -> runCatching {
                // "September 2026" or "September"
                val parts = section.split(' ')
                val month = java.time.Month.valueOf(parts[0].uppercase())
                val year = parts.getOrNull(1)?.toIntOrNull() ?: LocalDateTime.now().year
                LocalDateTime.of(year, month, 15, 12, 0).toInstant(ZoneOffset.UTC).toEpochMilli()
            }.getOrDefault(now - 30 * day)
        }
    }

    /** Spotify through the signed-in web player. */
    suspend fun spotify(c: Context): Int {
        status.value = "Reading your Spotify history…"
        val j = withTimeoutOrNull(180_000) { SpotifySearch.get(c).library() } ?: run { status.value = "Spotify didn't answer — try again"; error("no answer") }
        j.optString("error").takeIf { it.isNotEmpty() }?.let { status.value = "Spotify: couldn't read your history ($it)"; error(it) }
        val h = History.get(c)
        fun tracks(a: JSONArray?) = (0 until (a?.length() ?: 0)).mapNotNull { i -> a!!.optJSONObject(i)?.let(::spTrack) }
        val recent = j.optJSONArray("recent")
        val plays = (0 until (recent?.length() ?: 0)).mapNotNull { i ->
            val o = recent!!.getJSONObject(i)
            val t = spTrack(o) ?: return@mapNotNull null
            History.Play(t, runCatching { Instant.parse(o.optString("at")).toEpochMilli() }.getOrDefault(0), t.durationMs)
        }.filter { it.at > 0 }
        val added = h.importPlays("spotify", plays)
        // Top songs: the short-term list counts most (what you're into now).
        h.importFavourites("spotify-top-long", tracks(j.optJSONArray("top_long_term")), 1.0)
        h.importFavourites("spotify-top-medium", tracks(j.optJSONArray("top_medium_term")), 1.3)
        h.importFavourites("spotify-top-short", tracks(j.optJSONArray("top_short_term")), 1.6)
        val saved = tracks(j.optJSONArray("saved"))
        h.importFavourites("spotify-saved", saved, 1.0)
        j.optJSONArray("artists")?.let { a -> h.importArtists("spotify-artists", (0 until a.length()).map { a.getString(it) }) }
        prefs(c).edit().putLong("spAt", System.currentTimeMillis()).apply()
        status.value = "Spotify: ${saved.size} liked songs, ${j.optJSONArray("top_short_term")?.length() ?: 0} top tracks, ${j.optJSONArray("artists")?.length() ?: 0} top artists"
        return added
    }

    private fun spTrack(o: JSONObject): Track? {
        val id = o.optString("id").ifEmpty { return null }
        return Track(Source.SPOTIFY, id, o.optString("name"), o.optString("artists"), o.optString("album").ifEmpty { null }, o.optLong("dur"),
            o.optString("art").ifEmpty { null })
    }

    // MARK: export files

    /** A Spotify or Google data export (zip or JSON). Returns how many plays were added. */
    suspend fun file(c: Context, uri: Uri): Int = withContext(Dispatchers.IO) {
        status.value = "Reading the export…"
        val plays = mutableListOf<Pair<String, History.Play>>()
        val name = (runCatching {
            c.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull() ?: uri.lastPathSegment ?: "").lowercase()
        c.contentResolver.openInputStream(uri)?.use { input ->
            if (name.endsWith(".zip")) {
                val zip = ZipInputStream(input)
                while (true) {
                    val e = zip.nextEntry ?: break
                    val n = e.name.substringAfterLast('/').lowercase()
                    if (!e.isDirectory && n.endsWith(".json") && (n.contains("streaming_history") || n.contains("streaminghistory") || n.contains("watch-history"))) {
                        plays += readPlays(zip)
                    }
                }
            } else plays += readPlays(input)
        }
        if (plays.isEmpty()) {
            status.value = if (name.endsWith(".html")) "That's the HTML version — in Google Takeout choose JSON as the history format" else "No listening history found in that file"
            return@withContext 0
        }
        val h = History.get(c)
        val added = plays.groupBy({ it.first }, { it.second }).entries.sumOf { (src, list) -> h.importPlays(src, list.sortedBy { it.at }) }
        status.value = "Imported $added plays from the export"
        added
    }

    /** Reads one JSON file of plays, streaming (a Spotify extended history file can be tens of MB). */
    private fun readPlays(input: InputStream): List<Pair<String, History.Play>> {
        val out = mutableListOf<Pair<String, History.Play>>()
        // Not closing the reader: inside a zip that would close the whole zip stream.
        val r = JsonReader(InputStreamReader(input, Charsets.UTF_8))
        if (r.peek() != JsonToken.BEGIN_ARRAY) return out
        r.beginArray()
        while (r.hasNext()) {
            val o = mutableMapOf<String, String>()
            if (r.peek() != JsonToken.BEGIN_OBJECT) { r.skipValue(); continue }
            r.beginObject()
            while (r.hasNext()) {
                val k = r.nextName()
                when (r.peek()) {
                    JsonToken.STRING -> o[k] = r.nextString()
                    JsonToken.NUMBER -> o[k] = r.nextString()
                    JsonToken.BEGIN_ARRAY -> if (k == "subtitles") {
                        r.beginArray()
                        while (r.hasNext()) {
                            r.beginObject()
                            while (r.hasNext()) { val sk = r.nextName(); if (sk == "name" && r.peek() == JsonToken.STRING) o["subtitle"] = o["subtitle"] ?: r.nextString() else r.skipValue() }
                            r.endObject()
                        }
                        r.endArray()
                    } else r.skipValue()
                    else -> r.skipValue()
                }
            }
            r.endObject()
            parsePlay(o)?.let(out::add)
        }
        r.endArray()
        return out
    }

    private val spotifyShort = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")

    private fun parsePlay(o: Map<String, String>): Pair<String, History.Play>? {
        // Spotify extended streaming history
        o["master_metadata_track_name"]?.let { title ->
            val ms = o["ms_played"]?.toLongOrNull() ?: 0
            if (ms < 30_000) return null
            val id = o["spotify_track_uri"]?.substringAfterLast(':') ?: ""
            val at = runCatching { Instant.parse(o["ts"]).toEpochMilli() }.getOrNull() ?: return null
            return "spotify-export" to History.Play(Track(Source.SPOTIFY, id, title, o["master_metadata_album_artist_name"] ?: "",
                o["master_metadata_album_album_name"]), at, ms)
        }
        // Spotify account data (shorter history, no song ids)
        o["trackName"]?.let { title ->
            val ms = o["msPlayed"]?.toLongOrNull() ?: 0
            if (ms < 30_000) return null
            val at = runCatching { LocalDateTime.parse(o["endTime"], spotifyShort).toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull() ?: return null
            return "spotify-export" to History.Play(Track(Source.SPOTIFY, "", title, o["artistName"] ?: ""), at, ms)
        }
        // Google Takeout watch history: YouTube Music plays (and songs from artists' "- Topic" channels on YouTube)
        o["titleUrl"]?.let { url ->
            val header = o["header"] ?: ""
            val channel = o["subtitle"] ?: ""
            if (header != "YouTube Music" && !channel.endsWith(" - Topic")) return null
            val id = Regex("[?&]v=([^&]+)").find(url)?.groupValues?.get(1) ?: return null
            val title = (o["title"] ?: return null).removePrefix("Watched ")
            val at = runCatching { Instant.parse(o["time"]).toEpochMilli() }.getOrNull() ?: return null
            return "youtube-export" to History.Play(Track(Source.YOUTUBE, id, title, channel.removeSuffix(" - Topic")), at)
        }
        return null
    }
}
