package local.wreckbox.player

import android.content.Context

/** Lines in player.log (test builds only, read over USB) — why a part of Home or an import came out empty. */
object Debug {
    private var dir: java.io.File? = null
    fun init(c: Context) { if (BuildConfig.TEST_COMMANDS) dir = c.getExternalFilesDir(null) }
    fun log(what: String) {
        val d = dir ?: return
        runCatching {
            java.io.File(d, "player.log").appendText("${java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US).format(java.util.Date())} $what\n")
        }
    }
}
