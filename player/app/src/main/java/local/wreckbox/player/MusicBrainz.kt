package local.wreckbox.player

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * MusicBrainz (the open music encyclopedia, no key): what artist a search means, spelled right, with the other names
 * they go by (aliases, other scripts — "Arjit Singh" → Arijit Singh, "अरिजीत सिंह"). Search uses it to fix typos and to
 * count an alias as the artist. Answers are cached on the phone (mb.json); MusicBrainz asks for at most one request a
 * second and a User-Agent that says who's asking.
 */
object MusicBrainz {
    data class Artist(val name: String, val aliases: List<String>) {
        /** Every name, normalised. */
        val names get() = (listOf(name) + aliases).map { Search.norm(it) }.filter { it.isNotEmpty() }.distinct()
    }

    private const val AGENT = "WreckBoxPlayer/${BuildConfig.VERSION_NAME} ( https://github.com/moloyb301-eng/wreckbox )"
    private val gate = Mutex()
    private var lastCall = 0L
    private var cache: JSONObject? = null
    private lateinit var file: File

    /**
     * The artist [q] most likely names (or starts with), or null when MusicBrainz isn't sure. Only confident matches
     * count: score 95+, and the name close to what was typed (so "tum hi ho" doesn't turn into some band).
     */
    suspend fun artist(c: Context, q: String): Artist? = withContext(Dispatchers.IO) {
        val key = Search.norm(q)
        if (key.length < 3) return@withContext null
        val cached = cache(c).optJSONObject(key)
        if (cached != null && System.currentTimeMillis() - cached.optLong("at") < 30 * 86_400_000L) return@withContext parse(cached)
        val result = runCatching { fetch(key) }
        if (result.isFailure) return@withContext null // offline: ask again next time
        val found = result.getOrNull()
        synchronized(this@MusicBrainz) {
            cache(c).put(key, (found?.let { JSONObject().put("name", it.name).put("aliases", JSONArray(it.aliases)) } ?: JSONObject()).put("at", System.currentTimeMillis()))
            runCatching { file.writeText(cache(c).toString()) }
        }
        found
    }

    private fun parse(j: JSONObject) = j.optString("name").takeIf { it.isNotEmpty() }?.let { n ->
        Artist(n, j.optJSONArray("aliases")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList())
    }

    /** null = asked, nothing confident (cached too, so it isn't asked again); throws when MusicBrainz can't be reached. */
    private suspend fun fetch(key: String): Artist? {
        val text = gate.withLock {
            val wait = 1100 - (System.currentTimeMillis() - lastCall)
            if (wait > 0) kotlinx.coroutines.delay(wait)
            lastCall = System.currentTimeMillis()
            val conn = URL("https://musicbrainz.org/ws/2/artist?fmt=json&limit=5&query=${URLEncoder.encode(key, "UTF-8")}").openConnection() as HttpURLConnection
            conn.setRequestProperty("User-Agent", AGENT)
            conn.setRequestProperty("Accept", "application/json")
            conn.connectTimeout = 6000
            conn.readTimeout = 8000
            conn.inputStream.bufferedReader().use { it.readText() }
        }
        val artists = JSONObject(text).optJSONArray("artists") ?: return null
        for (i in 0 until artists.length()) {
            val a = artists.getJSONObject(i)
            if (a.optInt("score") < 95) break
            val aliases = a.optJSONArray("aliases")?.let { x -> (0 until x.length()).mapNotNull { x.optJSONObject(it)?.optString("name") } } ?: emptyList()
            val art = Artist(a.optString("name"), aliases.filter { it.isNotEmpty() }.distinct().take(12))
            // Close to what was typed: some name of theirs is within a couple of typos of the query (or of its start).
            if (art.names.any { n -> close(key, n) || (key.startsWith(n) && n.length >= 4) }) return art
        }
        return null
    }

    /** Within ~1 typo per 4 letters. */
    fun close(a: String, b: String): Boolean {
        if (a == b) return true
        val limit = (maxOf(a.length, b.length) / 4).coerceIn(1, 3)
        return kotlin.math.abs(a.length - b.length) <= limit && Fuzzy.distance(a, b, limit) <= limit
    }

    private fun cache(c: Context): JSONObject {
        cache?.let { return it }
        file = File(c.filesDir, "mb.json")
        return (runCatching { JSONObject(file.readText()) }.getOrNull() ?: JSONObject()).also { cache = it }
    }
}
