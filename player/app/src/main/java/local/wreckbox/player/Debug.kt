package local.wreckbox.player

import android.content.Context

/**
 * The app's log (player.log): why a song skipped, a part of Home came out empty, an import failed. Kept in every build
 * (trimmed to its newest ~300 KB) so Settings → Report a problem can send it; test builds can also read it over USB.
 */
object Debug {
    private const val MAX_BYTES = 600_000L
    private var dir: java.io.File? = null
    fun init(c: Context) { dir = c.getExternalFilesDir(null) }
    private fun file() = dir?.let { java.io.File(it, "player.log") }

    @Synchronized
    fun log(what: String) {
        val f = file() ?: return
        runCatching {
            f.appendText("${java.text.SimpleDateFormat("MM-dd HH:mm:ss", java.util.Locale.US).format(java.util.Date())} $what\n")
            if (f.length() > MAX_BYTES) f.writeText(f.readText().takeLast((MAX_BYTES / 2).toInt()).substringAfter('\n'))
        }
    }

    /** The newest [chars] of the log. */
    fun tail(chars: Int): String = runCatching { file()?.takeIf { it.exists() }?.readText()?.takeLast(chars)?.substringAfter('\n') }.getOrNull() ?: ""
}
