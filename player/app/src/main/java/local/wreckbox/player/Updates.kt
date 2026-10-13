package local.wreckbox.player

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * New versions: Player releases are tagged player-v… in wreckbox-releases. Checked every time the app opens or comes
 * back to the front (at most once a minute), through our server (it keeps the newest version even when GitHub is busy);
 * GitHub directly if the server can't be reached. Home shows a card that opens the download page.
 */
object Updates {
    const val PAGE = "https://wreckbox-api.moloyb301.workers.dev/player"
    private const val LATEST = "https://wreckbox-api.moloyb301.workers.dev/v1/player/latest"
    /** The newer version's number, or null. */
    val available = MutableStateFlow<String?>(null)
    @Volatile private var lastCheck = 0L

    suspend fun check(c: Context) = withContext(Dispatchers.IO) {
        val prefs = c.getSharedPreferences("settings", Context.MODE_PRIVATE)
        val cached = prefs.getString("newestPlayer", null)
        available.value = cached?.takeIf { newer(it, BuildConfig.VERSION_NAME) }
        if (System.currentTimeMillis() - lastCheck < 60_000L) return@withContext
        lastCheck = System.currentTimeMillis()
        val newest = runCatching { JSONObject(get(LATEST)).optString("version").ifEmpty { null } }.getOrNull()
            ?: runCatching {
                val a = JSONArray(get("https://api.github.com/repos/moloyb301-eng/wreckbox-releases/releases?per_page=30"))
                (0 until a.length()).map { a.getJSONObject(it) }
                    .filter { !it.optBoolean("draft") && it.optString("tag_name").startsWith("player-v") }
                    .map { it.optString("tag_name").removePrefix("player-v") }
                    .maxWithOrNull { x, y -> if (newer(x, y)) 1 else if (newer(y, x)) -1 else 0 }
            }.getOrNull()
            ?: return@withContext // offline: keep what we knew
        prefs.edit().putString("newestPlayer", newest).apply()
        available.value = newest.takeIf { newer(it, BuildConfig.VERSION_NAME) }
    }

    private fun get(url: String): String {
        val conn = URL(url).openConnection() as HttpURLConnection
        conn.setRequestProperty("accept", "application/json")
        conn.useCaches = false
        conn.connectTimeout = 8000
        conn.readTimeout = 10000
        return conn.inputStream.bufferedReader().use { it.readText() }
    }

    fun newer(a: String, b: String): Boolean {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) if (x.getOrElse(i) { 0 } != y.getOrElse(i) { 0 }) return x.getOrElse(i) { 0 } > y.getOrElse(i) { 0 }
        return false
    }
}
