package local.wreckbox.player

import android.os.Build
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Settings → Report a problem: what the person wrote, the phone model and the app's recent log, sent to the WreckBox
 * bug relay (the same Cloudflare Worker the main app uses), which files it as an issue in wreckbox-bugs.
 */
object BugReport {
    private const val RELAY = "https://wreckbox-bug-relay.moloyb301.workers.dev"
    private const val KEY = "5f0221703ec26d88c14ba5578325fa57" // deters casual spam; not a secret (as in the main app)

    /** Null when sent, else why not. */
    suspend fun send(description: String, name: String): String? = withContext(Dispatchers.IO) {
        val ui = PlayerService.instance?.player?.ui?.value
        val body = JSONObject()
            .put("title", description.lineSequence().first().take(80))
            .put("description", description + (ui?.current?.let { "\n\nPlaying: ${it.title} — ${it.artist} (${it.source.label} ${it.id})" } ?: ""))
            .put("app", "WreckBox Player")
            .put("version", "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})")
            .put("platform", "android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}) · ${Build.MANUFACTURER} ${Build.MODEL}")
            .put("reporter", name.ifBlank { "anonymous" })
            .put("logs", Debug.tail(18_000))
        runCatching {
            val c = URL(RELAY).openConnection() as HttpURLConnection
            c.requestMethod = "POST"
            c.doOutput = true
            c.connectTimeout = 10_000
            c.readTimeout = 20_000
            c.setRequestProperty("Content-Type", "application/json")
            c.setRequestProperty("X-WreckBox-Key", KEY)
            c.outputStream.use { it.write(body.toString().toByteArray()) }
            when (c.responseCode) {
                200 -> null
                429 -> "Too many reports from here — try again in an hour"
                else -> "Couldn't send (${c.responseCode}) — try again"
            }
        }.getOrElse { "Couldn't send — check your connection" }
    }
}
