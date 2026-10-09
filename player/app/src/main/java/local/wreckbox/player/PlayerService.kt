package local.wreckbox.player

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The playback service: owns the HybridPlayer and its media session. Media3 shows the media notification (also on the
 * lock screen) and keeps the service in the foreground while something plays, so it carries on with the screen off.
 * Web pages have no ExoPlayer holding the CPU and Wi-Fi awake, so we hold those while one plays.
 * Writes player.log every 10 s while playing (screen state + position) for testing over USB.
 */
@UnstableApi
class PlayerService : MediaSessionService() {
    lateinit var player: HybridPlayer
        private set
    private var session: MediaSession? = null
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null
    private val main = Handler(Looper.getMainLooper())
    private lateinit var log: File

    override fun onCreate() {
        super.onCreate()
        log = File(getExternalFilesDir(null), "player.log")
        if (BuildConfig.TEST_COMMANDS) android.webkit.WebView.setWebContentsDebuggingEnabled(true) // inspect the hidden pages over USB while testing
        AdBlock.enabled = getSharedPreferences("settings", MODE_PRIVATE).getBoolean("adblock", true)
        player = HybridPlayer(this) { holdLocks(it) }
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java).putExtra("page", "now"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        session = MediaSession.Builder(this, player).setSessionActivity(open)
            // No position re-send every 3 s: Android extrapolates it, and each update also goes to the Bluetooth headphones
            // over the audio link (they dropped audio). Real changes and seeks are still sent.
            .setPeriodicPositionUpdateEnabled(false)
            .build()
        // Our own screens use the player directly, so no controller ever "connects" — register the session ourselves
        // so Media3 posts the media notification (lock screen controls) and keeps the service in the foreground.
        addSession(session!!)
        instance = this
        // Callbacks are one-shot (a button pressed while the service was down must not run again on a later restart).
        val waiting = listeners.toList()
        listeners.clear()
        waiting.forEach { it(this) }
        PlayerWidget.render(this)
        // Display on/off: nothing animates or measures for a screen nobody can see (with "stay awake" or always-on
        // display the app can stay "visible" while the display is off).
        Screen.on.value = getSystemService(PowerManager::class.java).isInteractive
        registerReceiver(object : android.content.BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) { Screen.on.value = i.action == Intent.ACTION_SCREEN_ON }
        }, android.content.IntentFilter().apply { addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_SCREEN_OFF) })
        // Liking from the app shows on the widget too.
        kotlinx.coroutines.MainScope().launch { Library.get(this@PlayerService).data.collect { PlayerWidget.render() } }
        main.postDelayed(object : Runnable {
            override fun run() {
                tick()
                main.postDelayed(this, 30_000)
            }
        }, 30_000)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = session

    /** Swiped away from recents while paused: stop. While playing it keeps going. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!player.ui.value.playing) stopSelf()
    }

    private fun holdLocks(on: Boolean) {
        if (on) {
            if (wake == null) {
                wake = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "wreckbox:web")
                @Suppress("DEPRECATION")
                wifi = (applicationContext.getSystemService(WIFI_SERVICE) as WifiManager).createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "wreckbox:web")
            }
            if (wake?.isHeld == false) wake?.acquire(8 * 60 * 60 * 1000L)
            // The Wi-Fi lock only matters on Wi-Fi (on mobile data it just keeps the Wi-Fi radio busy).
            val onWifi = runCatching {
                val cm = getSystemService(android.net.ConnectivityManager::class.java)
                cm.getNetworkCapabilities(cm.activeNetwork)?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true
            }.getOrDefault(true)
            if (onWifi && wifi?.isHeld == false) wifi?.acquire()
            if (!onWifi && wifi?.isHeld == true) wifi?.release()
        } else {
            if (wake?.isHeld == true) wake?.release()
            if (wifi?.isHeld == true) wifi?.release()
        }
    }

    private fun tick() {
        val u = player.ui.value
        if (!u.playing) return
        player.savePosition()
        if (!BuildConfig.TEST_COMMANDS) return // the log is for testing over USB only
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        val t = u.current
        val line = "${SimpleDateFormat("HH:mm:ss", Locale.US).format(Date())} screen ${if (pm.isInteractive) "on" else "OFF"} " +
            "idle=${pm.isDeviceIdleMode} ${t?.source} ${player.positionMs() / 1000}/${player.durationMs() / 1000}s ${t?.artist} – ${t?.title} | ${player.webDebug()}\n"
        runCatching { log.appendText(line) }
    }

    override fun onDestroy() {
        holdLocks(false)
        session?.run { player.release(); release() }
        session = null
        instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile var instance: PlayerService? = null
            private set
        private val listeners = mutableListOf<(PlayerService) -> Unit>()

        /** Starts the service if needed and calls back once it's up. */
        fun connect(c: Context, f: (PlayerService) -> Unit): Boolean {
            instance?.let { f(it); return true }
            listeners += f
            // Android 12+ refuses to start a service from the background (e.g. a widget press with the app fully
            // closed): say so instead of crashing, so the caller can open the app instead.
            return runCatching { c.startService(Intent(c, PlayerService::class.java)) }
                .onFailure { listeners -= f }.isSuccess
        }
    }
}
