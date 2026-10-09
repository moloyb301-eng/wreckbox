package local.wreckbox.player

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.net.HttpURLConnection
import java.net.URL

/**
 * New versions: Player releases are tagged player-v… in wreckbox-releases. Checked when the app opens, at most twice a
 * day; Home shows a card that opens the download page.
 */
object Updates {
    const val PAGE = "https://wreckbox-api.moloyb301.workers.dev/player"
    /** The newer version's number, or null. */
    val available = MutableStateFlow<String?>(null)

    suspend fun check(c: Context) = withContext(Dispatchers.IO) {
        val prefs = c.getSharedPreferences("settings", Context.MODE_PRIVATE)
        val cached = prefs.getString("newestPlayer", null)
        if (System.currentTimeMillis() - prefs.getLong("updateChecked", 0) < 12 * 3600_000L) { available.value = cached?.takeIf { newer(it, BuildConfig.VERSION_NAME) }; return@withContext }
        val newest = runCatching {
            val conn = URL("https://api.github.com/repos/moloyb301-eng/wreckbox-releases/releases?per_page=30").openConnection() as HttpURLConnection
            conn.setRequestProperty("accept", "application/vnd.github+json")
            conn.connectTimeout = 8000
            conn.readTimeout = 10000
            val a = JSONArray(conn.inputStream.bufferedReader().use { it.readText() })
            (0 until a.length()).map { a.getJSONObject(it) }
                .filter { !it.optBoolean("draft") && it.optString("tag_name").startsWith("player-v") }
                .map { it.optString("tag_name").removePrefix("player-v") }
                .maxWithOrNull { x, y -> if (newer(x, y)) 1 else if (newer(y, x)) -1 else 0 }
        }.getOrNull()
        prefs.edit().putLong("updateChecked", System.currentTimeMillis()).putString("newestPlayer", newest).apply()
        available.value = newest?.takeIf { newer(it, BuildConfig.VERSION_NAME) }
    }

    fun newer(a: String, b: String): Boolean {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) if (x.getOrElse(i) { 0 } != y.getOrElse(i) { 0 }) return x.getOrElse(i) { 0 } > y.getOrElse(i) { 0 }
        return false
    }
}
