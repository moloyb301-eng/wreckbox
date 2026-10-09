package local.wreckbox.player

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.SweepGradient
import android.graphics.Typeface
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import org.json.JSONObject
import java.io.File
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlin.random.Random

// Home-screen player (moved here from the WreckBox app): a Y2K player shell — smoked translucent plastic with an
// iridescent rim and a glossy highlight, an LCD with ghost segments and glare, a round Sonique-style dial, tabs hanging
// off the bottom edge that pull out drawers (Equaliser, Queue, Options) — in the WreckBox design language: near-black
// glass, the lilac / light-blue / peach gradient, Doto for the display and dot labels, Urbanist for text.
//
// The shell, LCD, dial and EQ are bitmaps drawn at the widget's real width from the same dp grid as
// res/layout/wb_widget.xml (Geo). It reads the player directly (PlayerService) and is redrawn when it changes;
// buttons act on the player in this process. On the lock screen (Android's keyguard widgets) it's a compact LCD +
// transport (res/layout/wb_widget_lock.xml).
@UnstableApi
class PlayerWidget : AppWidgetProvider() {

    // The launcher asks again (it restarted, the widget was added): it needs everything, not just the changes.
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) { ids.forEach { forgetSent(it) }; render(context) }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = render(context)

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val action = intent.getStringExtra(EXTRA) ?: return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        when {
            // Drawers open / close inside the widget; one at a time.
            action.startsWith("drawer:") -> {
                val want = action.removePrefix("drawer:")
                prefs.edit().putString("drawer", if (prefs.getString("drawer", "") == want) "" else want).apply()
                render(context)
            }
            action == "open" -> context.startActivity(Intent(context, MainActivity::class.java).putExtra("page", "now").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            else -> act(context, action)
        }
    }

    /// The dp grid — the same numbers as wb_widget.xml.
    private object Geo {
        const val G = 14f            // gutter
        const val BODY_H = 204f
        const val R = 28f            // shell corner radius
        const val DIAL = 124f
        const val TOP = 44f          // LCD and dial top
        const val LCD_H = 104f
        const val SEEK_T = 158f
        const val SEEK_H = 6f
        const val TAB_GAP = 6f
        const val DRAWER_H = 176f
        const val IN_T = 18f
        const val IN_B = 16f
        const val SCALE = 2.5f       // bitmap pixels per dp
        const val DIAL_END = 22f     // dial's distance from the right edge (the pod around it stays inside)
        const val LCD_RIGHT = 170f   // the LCD stops short of the pod
        // The silhouette: a slab (y 30–178) with a raised bump top-left for the logo, a round pod on the right
        // (centred on the dial, r 84) swelling past the slab, tabs hanging below.
        const val SLAB_T = 36f
        const val SLAB_B = 178f
        const val POD_R = 80f
        const val DIAL_CY = TOP + DIAL / 2
        val TABS = listOf(88f, 76f, 84f) // Equaliser, Queue, Options at full size

        /// The tabs' widths at this widget width: full size, or squeezed so the last stays clear of the pod.
        fun tabs(w: Float): List<Float> {
            val podLeft = w - DIAL_END - DIAL / 2 - sqrt(POD_R * POD_R - (BODY_H - 28f - DIAL_CY) * (BODY_H - 28f - DIAL_CY))
            val room = podLeft - 10f - G - 2 * TAB_GAP
            val k = (room / TABS.sum()).coerceIn(0.6f, 1f)
            return TABS.map { it * k }
        }
        fun tabsEnd(w: Float) = G + tabs(w).sum() + 2 * TAB_GAP
    }

    /** Everything the widget shows, read from the player. */
    data class Snap(
        val title: String?, val artist: String?, val playing: Boolean, val posMs: Long, val durMs: Long,
        val track: String, val source: Source?, val quality: String?, val shuffle: Boolean, val repeat: Int,
        val liked: Boolean, val volume: Int, val upcoming: List<Pair<Int, Track>>, val eq: Eq.State, val alive: Boolean,
    ) {
        /** "FLAC 24/96", "MP3 320", "OPUS 160": the LCD's format badge. */
        val format get() = quality?.split(" · ")?.let { p ->
            if (p.size >= 2) "${p[0]} ${p[1].removePrefix("~").removeSuffix(" kbps").replace(",", "")}" else p[0]
        } ?: ""
    }

    companion object {
        const val PREFS = "wreckbox_widget"
        private const val EXTRA = "wb_action"
        private val presetLabels = listOf("Flat", "Bass", "Club", "Hip-hop", "Electro", "Vocal", "Treble", "Loud")
        private val presets get() = Eq.presets.keys.toList()
        private val presetIds = listOf(R.id.wb_p0, R.id.wb_p1, R.id.wb_p2, R.id.wb_p3, R.id.wb_p4, R.id.wb_p5, R.id.wb_p6, R.id.wb_p7)
        private val queueIds = listOf(R.id.wb_q0, R.id.wb_q1, R.id.wb_q2, R.id.wb_q3, R.id.wb_q4)

        // The app's palette
        private val TEXT = Color.parseColor("#F0FFFFFF")
        private val TEXT2 = Color.parseColor("#99FFFFFF")
        private val TEXT3 = Color.parseColor("#5CFFFFFF")
        private val PEACH = Color.parseColor("#FFEFAF86")
        private val LILAC = Color.parseColor("#FFBB96DA")
        private val BLUE = Color.parseColor("#FFA9C8F0")
        private val DRAWER = Color.parseColor("#FF131218")   // = wb_tab_active

        private var appContext: Context? = null
        private val main = Handler(Looper.getMainLooper())
        private val pending = Runnable { appContext?.let { render(it) } }

        /// The player changed: redraw soon (changes come in bursts).
        fun render() {
            main.removeCallbacks(pending)
            main.postDelayed(pending, 250)
        }

        private fun player() = PlayerService.instance?.player

        /// A button: done here on the player (the service is in this process). With the service not running (after a
        /// reboot, or the app was closed), transport keys open the app, which starts it and picks up the saved queue.
        private fun act(context: Context, action: String) {
            val audio = context.getSystemService(AudioManager::class.java)
            // Volume is the phone's media volume (shown with the system's slider), so it works for every source.
            when (action) {
                "volup", "voldown" -> {
                    audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, if (action == "volup") AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
                    return render(context)
                }
                "eqtoggle" -> { Eq.load(context); return Eq.setOn(!Eq.state.value.on) }
            }
            if (action.startsWith("preset:")) { Eq.load(context); Eq.choose(action.removePrefix("preset:")); return }
            val p = player()
            if (p == null) {
                // The service isn't running (app closed, phone restarted, update): start it right here — no screen
                // needed (and a background app can't open one anyway) — and press the button once it's up.
                val app = context.applicationContext
                val started = PlayerService.connect(app) { svc -> run(svc.player, action, app); render(app) }
                // Fully closed app on Android 12+: a background press can't start the service, so open the app (it
                // starts the service and runs the press).
                if (!started) context.startActivity(Intent(context, MainActivity::class.java).putExtra("page", "now").putExtra("widget", action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            }
            run(p, action, context)
            render(context)
        }

        /// Also used by MainActivity for a press that had to start the app first.
        fun run(p: HybridPlayer, action: String, context: Context) {
            when (action) {
                "toggle" -> p.toggle()
                "next" -> p.seekToNext()
                "previous" -> p.seekToPrevious()
                "back10" -> p.seekMs((p.positionMs() - 10_000).coerceAtLeast(0))
                "fwd10" -> p.seekMs(p.positionMs() + 10_000)
                "shuffle" -> p.setShuffle(!p.ui.value.shuffle)
                "repeat" -> p.cycleRepeat()
                "like" -> p.current()?.let { Library.get(context).toggleLike(it) }
                else -> if (action.startsWith("jump:")) action.removePrefix("jump:").toIntOrNull()?.let(p::jumpTo)
            }
        }

        private fun intent(context: Context, action: String, code: Int): PendingIntent =
            PendingIntent.getBroadcast(
                context, code,
                Intent(context, PlayerWidget::class.java).putExtra(EXTRA, action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        fun snap(context: Context): Snap {
            val audio = context.getSystemService(AudioManager::class.java)
            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
            val volume = audio.getStreamVolume(AudioManager.STREAM_MUSIC) * 100 / max
            Eq.load(context)
            val p = player()
            if (p == null) {
                // Not running: what was playing last (the saved queue), paused.
                val saved = runCatching {
                    val j = JSONObject(File(context.filesDir, "queue.json").readText())
                    val q = j.optJSONArray("queue").toTracks()
                    q.getOrNull(j.optInt("index", -1))?.let { it to "%03d/%03d".format(j.optInt("index") + 1, q.size) }
                }.getOrNull()
                val t = saved?.first
                return Snap(t?.title, t?.artist, false, 0, t?.durationMs ?: 0, saved?.second ?: "", t?.source, t?.let { Quality.cached(it) },
                    false, Player.REPEAT_MODE_OFF, t?.let { Library.get(context).isLiked(it) } ?: false, volume, emptyList(), Eq.state.value, false)
            }
            val u = p.ui.value
            val t = u.current
            return Snap(t?.title, t?.artist, u.playing, p.positionMs(), p.durationMs(),
                if (t == null) "" else "%03d/%03d".format(u.index + 1, u.queue.size), t?.source, u.quality, u.shuffle, u.repeat,
                t?.let { Library.get(context).isLiked(it) } ?: false, volume,
                u.queue.withIndex().filter { it.index > u.index }.take(queueIds.size).map { it.index to it.value }, Eq.state.value, true)
        }

        fun render(context: Context) {
            appContext = context.applicationContext
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, PlayerWidget::class.java))
            if (ids.isEmpty()) return
            val s = snap(context)
            for (id in ids) {
                val o = manager.getAppWidgetOptions(id)
                val lock = o.getInt(AppWidgetManager.OPTION_APPWIDGET_HOST_CATEGORY, -1) == AppWidgetProviderInfo_KEYGUARD
                // The width the launcher gave this widget (portrait).
                val w = o.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).takeIf { it > 0 } ?: if (lock) 300 else 340
                if (lock) { runCatching { manager.updateAppWidget(id, lockViews(context, w.toFloat(), s)) }; continue }
                val key = "$w|${context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("drawer", "")}"
                val full = fullKey[id] != key
                if (full) { fullKey[id] = key; sent.remove(id) }
                runCatching {
                    val v = views(context, w.toFloat(), s, id, full)
                    if (full) manager.updateAppWidget(id, v) else manager.partiallyUpdateAppWidget(id, v)
                }.onFailure { fullKey.remove(id) }
            }
            if (s.playing) startTicking(context) // the clock is a Doto image: redrawn once a second while playing
        }

        private const val AppWidgetProviderInfo_KEYGUARD = 2 // AppWidgetProviderInfo.WIDGET_CATEGORY_KEYGUARD

        // MARK: sending only what changed
        //
        // A full update (all pictures) goes out only when the widget's size, the open drawer or the screen it's on
        // changes; otherwise each picture is sent only if what it shows changed (a key per view), as a partial update.
        // The casing, dial and drawer trays are drawn once per size and reused.

        private val fullKey = mutableMapOf<Int, String>()
        private val sent = mutableMapOf<Int, MutableMap<Int, String>>()
        private val shapes = object : android.util.LruCache<String, Bitmap>(24 * 1024 * 1024) {
            override fun sizeOf(key: String, value: Bitmap) = value.byteCount
        }
        fun forgetSent(widget: Int) { fullKey.remove(widget); sent.remove(widget) }

        private fun shape(key: String, make: () -> Bitmap): Bitmap = shapes.get(key) ?: make().also { shapes.put(key, it) }

        /// Sets an image only if its key changed since it was last sent to this widget (or on a full update).
        private fun img(v: RemoteViews, widget: Int, view: Int, key: String, make: () -> Bitmap) {
            val m = sent.getOrPut(widget) { mutableMapOf() }
            if (m[view] == key) return
            m[view] = key
            v.setImageViewBitmap(view, make())
        }

        private fun prop(v: RemoteViews, widget: Int, view: Int, key: String, set: () -> Unit) {
            val m = sent.getOrPut(widget) { mutableMapOf() }
            if (m[view] == key) return
            m[view] = key
            set()
        }

        private fun views(context: Context, w: Float, s: Snap, widget: Int, full: Boolean): RemoteViews {
            fonts(context)
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val v = RemoteViews(context.packageName, R.layout.wb_widget)
            val drawer = prefs.getString("drawer", "") ?: ""
            val eq = s.eq
            val wk = w.toInt()

            // Body
            img(v, widget, R.id.wb_body_bg, "$wk|${s.playing}") { shape("body|$wk|${s.playing}") { body(w, s.playing) } }
            img(v, widget, R.id.wb_lcd, "$wk|${s.title}|${s.artist}|${s.track}|${s.format}|${s.shuffle}|${s.volume}|${s.source}") {
                lcd(w - Geo.G - Geo.LCD_RIGHT, Geo.LCD_H, s)
            }
            img(v, widget, R.id.wb_dial, "dial") { shape("dial") { dial() } }
            // Spectrum: the music's real levels (still when there's nothing to measure)
            v.setImageViewBitmap(R.id.wb_sf0, spectrumFrame(Levels.bands.value))
            img(v, widget, R.id.wb_clock, "${s.posMs / 1000}|${s.playing}|${s.title != null}") { clock(context, s.posMs, s.playing, s.title != null) }
            v.setProgressBar(R.id.wb_progress, 1000, if (s.durMs > 0) (s.posMs * 1000 / s.durMs).toInt().coerceIn(0, 1000) else 0, false)
            prop(v, widget, R.id.wb_play, "${s.playing}") { v.setImageViewResource(R.id.wb_play, if (s.playing) R.drawable.wb_icb_pause else R.drawable.wb_icb_play) }

            if (full) {
                // Tabs: the open one takes the drawer's colour and flows into it
                val widths = Geo.tabs(w)
                for ((i, tab) in listOf(Triple(R.id.wb_tab_eq, "eq", "Equaliser"), Triple(R.id.wb_tab_queue, "queue", "Queue"), Triple(R.id.wb_tab_controls, "controls", "Options")).withIndex()) {
                    val (id, name, label) = tab
                    val open = drawer == name
                    if (Build.VERSION.SDK_INT >= 31) v.setViewLayoutWidth(id, widths[i], TypedValue.COMPLEX_UNIT_DIP)
                    // Closed (no drawer): complete keys; a drawer open: the open tab flows into it, the other sits on its edge.
                    v.setInt(id, "setBackgroundResource", when { open -> R.drawable.wb_tab_active; drawer.isEmpty() -> R.drawable.wb_tab_closed; else -> R.drawable.wb_tab_idle })
                    v.setImageViewBitmap(id, ui(context, label, if (widths[i] < 70f) 10.5f else 12f, 700, if (open) LILAC else TEXT2))
                }
                v.setViewVisibility(R.id.wb_drawer_eq, if (drawer == "eq") View.VISIBLE else View.GONE)
                v.setViewVisibility(R.id.wb_drawer_queue, if (drawer == "queue") View.VISIBLE else View.GONE)
                v.setViewVisibility(R.id.wb_drawer_controls, if (drawer == "controls") View.VISIBLE else View.GONE)
            }

            // Drawers (only the open one is drawn)
            if (drawer == "eq") {
                img(v, widget, R.id.wb_drawer_eq_bg, "$wk") { shape("drawer|$wk|0") { drawerShell(w, 0) } }
                val inner = w - 2 * Geo.G
                val note = if (s.source == Source.SPOTIFY) "Not on Spotify" else null
                img(v, widget, R.id.wb_eq_curve, "$wk|${eq.gains}|${eq.on}|${eq.preset}|$note") {
                    eqPanel((inner - 8) * 11 / 21, Geo.DRAWER_H - Geo.IN_T - Geo.IN_B, eq.gains, eq.on, eq.preset, note)
                }
                img(v, widget, R.id.wb_presets_label, "p") { dot(context, "Presets", 8.5f, TEXT3) }
                prop(v, widget, -1, "eqon|${eq.on}") {
                    v.setInt(R.id.wb_eq_on, "setBackgroundResource", if (eq.on) R.drawable.wb_toggle_on else R.drawable.wb_chip)
                    v.setImageViewBitmap(R.id.wb_eq_on, ui(context, if (eq.on) "On" else "Off", 10.5f, 700, if (eq.on) Color.parseColor("#FF141218") else TEXT2))
                }
                presetIds.forEachIndexed { i, id ->
                    val on = presets[i] == eq.preset
                    prop(v, widget, id, "$on") {
                        v.setInt(id, "setBackgroundResource", if (on) R.drawable.wb_chip_on else R.drawable.wb_chip)
                        v.setImageViewBitmap(id, ui(context, presetLabels[i], 11f, 600, if (on) Color.BLACK else TEXT2))
                    }
                }
            }
            if (drawer == "queue") {
                img(v, widget, R.id.wb_drawer_queue_bg, "$wk") { shape("drawer|$wk|1") { drawerShell(w, 1) } }
                val rowW = w - 2 * Geo.G - 20
                queueIds.forEachIndexed { i, id ->
                    val item = s.upcoming.getOrNull(i)
                    val key = "$wk|${item?.first}|${item?.second?.key}|${s.upcoming.isEmpty()}"
                    img(v, widget, id, key) { queueRow(context, rowW, item?.first, item?.second, i == 0 && s.upcoming.isEmpty()) }
                    if (item != null) prop(v, widget, -100 - i, "${item.first}") { v.setOnClickPendingIntent(id, intent(context, "jump:${item.first}", 100 + i)) }
                }
            }
            if (drawer == "controls") {
                img(v, widget, R.id.wb_drawer_controls_bg, "$wk") { shape("drawer|$wk|2") { drawerShell(w, 2) } }
                val info = listOfNotNull(
                    if (s.track.isEmpty()) "Nothing queued" else "Trk ${s.track}",
                    s.source?.let { if (it == Source.YOUTUBE) "YouTube Music" else it.label },
                    s.quality,
                ).joinToString(" · ")
                img(v, widget, R.id.wb_info, info) { dot(context, info, 8.5f, TEXT3) }
                val repeatLabel = when (s.repeat) { Player.REPEAT_MODE_ONE -> "Repeat 1"; Player.REPEAT_MODE_ALL -> "Repeat on"; else -> "Repeat" }
                for ((id, t, lit) in listOf(
                    Triple(R.id.wb_back10, "−10 s", false), Triple(R.id.wb_fwd10, "+10 s", false),
                    Triple(R.id.wb_restart, if (s.shuffle) "Shuffle on" else "Shuffle", s.shuffle),
                    Triple(R.id.wb_stop, repeatLabel, s.repeat != Player.REPEAT_MODE_OFF),
                    Triple(R.id.wb_handoff, if (s.liked) "♥ Liked" else "♡ Like", s.liked),
                    Triple(R.id.wb_open, "Open app", false),
                )) {
                    prop(v, widget, id, "$t|$lit") {
                        v.setImageViewBitmap(id, ui(context, t, 12f, 600, if (lit) Color.BLACK else TEXT))
                        if (id != R.id.wb_handoff) v.setInt(id, "setBackgroundResource", if (lit) R.drawable.wb_chip_on else R.drawable.wb_chip)
                        else v.setInt(id, "setBackgroundResource", if (lit) R.drawable.wb_chip_smart else R.drawable.wb_chip)
                    }
                }
            }

            // Buttons (they don't change: set with the full update)
            if (full) {
                val clicks = mapOf(
                    R.id.wb_play to "toggle", R.id.wb_prev to "previous", R.id.wb_next to "next",
                    R.id.wb_voldown to "voldown", R.id.wb_volup to "volup", R.id.wb_lcd to "open",
                    R.id.wb_tab_controls to "drawer:controls", R.id.wb_tab_eq to "drawer:eq", R.id.wb_tab_queue to "drawer:queue",
                    R.id.wb_back10 to "back10", R.id.wb_fwd10 to "fwd10", R.id.wb_restart to "shuffle", R.id.wb_stop to "repeat",
                    R.id.wb_handoff to "like", R.id.wb_open to "open", R.id.wb_eq_on to "eqtoggle",
                ) + presetIds.mapIndexed { i, id -> id to "preset:${presets[i]}" }
                clicks.entries.forEachIndexed { n, (id, action) -> v.setOnClickPendingIntent(id, intent(context, action, n)) }
            }
            return v
        }

        /// The lock-screen widget: the LCD (clock, format, title, artist, seek) over a row of keys.
        private fun lockViews(context: Context, w: Float, s: Snap): RemoteViews {
            fonts(context)
            val v = RemoteViews(context.packageName, R.layout.wb_widget_lock)
            v.setImageViewBitmap(R.id.wb_lock_bg, lockShell(w))
            v.setImageViewBitmap(R.id.wb_lcd, lcd(w - 2 * Geo.G, Geo.LCD_H, s))
            v.setImageViewBitmap(R.id.wb_clock, clock(context, s.posMs, s.playing, s.title != null))
            v.setProgressBar(R.id.wb_progress, 1000, if (s.durMs > 0) (s.posMs * 1000 / s.durMs).toInt().coerceIn(0, 1000) else 0, false)
            v.setImageViewResource(R.id.wb_play, if (s.playing) R.drawable.wb_icb_pause else R.drawable.wb_icb_play)
            for ((id, t) in listOf(R.id.wb_like to if (s.liked) "♥" else "♡", R.id.wb_shuffle to "Shuf")) {
                val lit = if (id == R.id.wb_like) s.liked else s.shuffle
                v.setImageViewBitmap(id, ui(context, t, if (id == R.id.wb_like) 16f else 11.5f, 700, if (lit) Color.BLACK else TEXT))
                v.setInt(id, "setBackgroundResource", if (lit) R.drawable.wb_chip_on else R.drawable.wb_chip)
            }
            v.setImageViewBitmap(R.id.wb_prev, glyph(context, false))
            v.setImageViewBitmap(R.id.wb_next, glyph(context, true))
            val clicks = mapOf(R.id.wb_play to "toggle", R.id.wb_prev to "previous", R.id.wb_next to "next", R.id.wb_like to "like",
                R.id.wb_shuffle to "shuffle", R.id.wb_lcd to "open")
            clicks.entries.forEachIndexed { n, (id, action) -> v.setOnClickPendingIntent(id, intent(context, action, 200 + n)) }
            return v
        }

        // MARK: the clock, ticking while playing

        private var ticking = false
        private var wantsLevels = false

        private fun startTicking(context: Context) {
            if (ticking) return
            ticking = true
            val app = context.applicationContext
            main.postDelayed(object : Runnable {
                override fun run() {
                    val p = player()
                    val u = p?.ui?.value
                    val manager = AppWidgetManager.getInstance(app)
                    val ids = manager.getAppWidgetIds(ComponentName(app, PlayerWidget::class.java))
                    val screenOn = app.getSystemService(android.os.PowerManager::class.java).isInteractive
                    // The widget's spectrum listens only while the screen is on and something plays.
                    val want = screenOn && p != null && u?.playing == true && ids.isNotEmpty()
                    if (want != wantsLevels) { wantsLevels = want; if (want) Levels.want() else Levels.unwant() }
                    if (p == null || u == null || !u.playing || u.current == null || ids.isEmpty()) { ticking = false; return }
                    // Screen off: nobody sees the widget — check back in a few seconds instead of redrawing.
                    if (!screenOn) { main.postDelayed(this, 3000); return }
                    val ms = p.positionMs()
                    val dur = p.durationMs()
                    for (id in ids) {
                        val lock = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_HOST_CATEGORY, -1) == AppWidgetProviderInfo_KEYGUARD
                        val v = RemoteViews(app.packageName, if (lock) R.layout.wb_widget_lock else R.layout.wb_widget)
                        v.setImageViewBitmap(R.id.wb_clock, clock(app, ms, true, true))
                        if (!lock) v.setImageViewBitmap(R.id.wb_sf0, spectrumFrame(Levels.bands.value))
                        if (dur > 0) v.setProgressBar(R.id.wb_progress, 1000, (ms * 1000 / dur).toInt().coerceIn(0, 1000), false)
                        runCatching { manager.partiallyUpdateAppWidget(id, v) }
                    }
                    main.postDelayed(this, 1000 - System.currentTimeMillis() % 1000)
                }
            }, 1000)
        }

        /// A queue row in the drawer: Doto position number, Urbanist title, dim artist. Empty: a hint on the first row.
        private fun queueRow(context: Context, wDp: Float, index: Int?, t: Track?, hint: Boolean): Bitmap {
            val d = context.resources.displayMetrics.density
            val b = Bitmap.createBitmap(max(1, (wDp * d).roundToInt()), max(1, (22 * d).roundToInt()), Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            val y = 15.5f * d
            if (t == null || index == null) {
                if (hint) c.drawText("Nothing up next", 4 * d, y, paint { typeface = urbanist(500); textSize = 12f * d; color = TEXT3 })
                return b
            }
            c.drawText("%02d".format(index + 1), 4 * d, y, paint { typeface = dotFace(); isFakeBoldText = true; textSize = 11f * d; color = LILAC })
            val tp = paint { typeface = urbanist(650); textSize = 12.5f * d; color = TEXT }
            val ap = paint { typeface = urbanist(500); textSize = 11f * d; color = TEXT2 }
            val x = 28 * d
            val room = b.width - x - 4 * d
            val title = fit(t.title, tp, room * 0.62f)
            c.drawText(title, x, y, tp)
            val ax = x + tp.measureText(title) + 8 * d
            c.drawText(fit(t.artist, ap, b.width - ax - 4 * d), ax, y, ap)
            c.drawLine(4 * d, b.height - 0.5f * d, b.width - 4 * d, b.height - 0.5f * d, paint { color = Color.argb(18, 255, 255, 255); strokeWidth = d * 0.6f })
            return b
        }

        /// Previous / next glyphs for the lock-screen keys.
        private fun glyph(context: Context, next: Boolean): Bitmap {
            val d = context.resources.displayMetrics.density
            val s = 18 * d
            val b = Bitmap.createBitmap(s.roundToInt(), s.roundToInt(), Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            if (!next) { c.scale(-1f, 1f, s / 2, s / 2) }
            val g = paint { color = TEXT }
            c.drawPath(Path().apply { moveTo(s * 0.18f, s * 0.2f); lineTo(s * 0.68f, s * 0.5f); lineTo(s * 0.18f, s * 0.8f); close() }, g)
            c.drawRect(s * 0.7f, s * 0.2f, s * 0.82f, s * 0.8f, g)
            return b
        }

        // MARK: fonts and labels (the app's: Doto for the display and dot labels, Urbanist for text)

        private var doto: Typeface? = null
        private var urbanist: Typeface? = null
        private fun fonts(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            if (doto == null) doto = runCatching { context.resources.getFont(R.font.doto) }.getOrNull()
            if (urbanist == null) urbanist = runCatching { context.resources.getFont(R.font.urbanist) }.getOrNull()
        }

        private fun urbanist(weight: Int): Typeface {
            val base = urbanist ?: Typeface.SANS_SERIF
            return if (Build.VERSION.SDK_INT >= 28) Typeface.create(base, weight, false) else Typeface.create(base, if (weight >= 600) Typeface.BOLD else Typeface.NORMAL)
        }

        private fun dotFace(): Typeface = doto ?: Typeface.MONOSPACE

        private fun paint(block: Paint.() -> Unit) = Paint(Paint.ANTI_ALIAS_FLAG).apply(block)

        /// A label bitmap at the screen's density (its ImageView centres it).
        private fun labelBitmap(context: Context, s: String, p: Paint): Bitmap {
            val d = context.resources.displayMetrics.density
            val pad = 4 * d
            val b = Bitmap.createBitmap(max(1, (p.measureText(s) + pad * 2).roundToInt()), max(1, (p.textSize * 1.5f).roundToInt()), Bitmap.Config.ARGB_8888)
            Canvas(b).drawText(s, pad, b.height / 2f - (p.descent() + p.ascent()) / 2, p)
            return b
        }

        /// Urbanist, like the app's text (weight 400–800).
        private fun ui(context: Context, s: String, sp: Float, weight: Int, color: Int): Bitmap =
            labelBitmap(context, s, paint { typeface = urbanist(weight); textSize = sp * context.resources.displayMetrics.density; this.color = color })

        /// The app's DotLabel: Doto caps, spaced out.
        private fun dot(context: Context, s: String, sp: Float, color: Int): Bitmap =
            labelBitmap(context, s.uppercase(), paint { typeface = dotFace(); isFakeBoldText = true; textSize = sp * context.resources.displayMetrics.density; letterSpacing = 0.15f; this.color = color })

        /// The clock: peach Doto digits over faint "88:88" segments, with a soft glow, and the state mark before it.
        private fun clock(context: Context, ms: Long, playing: Boolean, loaded: Boolean): Bitmap {
            fonts(context)
            val d = context.resources.displayMetrics.density
            val b = Bitmap.createBitmap((116 * d).roundToInt(), (32 * d).roundToInt(), Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            val p = paint { typeface = dotFace(); isFakeBoldText = true; textSize = 25f * d; letterSpacing = 0.04f }
            val y = b.height / 2f - (p.descent() + p.ascent()) / 2
            val x = 13 * d
            // State mark: ▶ playing, ❚❚ paused, ■ stopped
            val mark = paint { color = LILAC }
            val cy = b.height / 2f
            when {
                playing -> c.drawPath(Path().apply { moveTo(1 * d, cy - 5 * d); lineTo(8 * d, cy); lineTo(1 * d, cy + 5 * d); close() }, mark)
                loaded -> { c.drawRect(1 * d, cy - 5 * d, 3.4f * d, cy + 5 * d, mark); c.drawRect(5.6f * d, cy - 5 * d, 8 * d, cy + 5 * d, mark) }
                else -> c.drawRect(1 * d, cy - 4 * d, 8 * d, cy + 4 * d, mark)
            }
            c.drawText("88:88", x, y, Paint(p).apply { color = Color.argb(30, 239, 175, 134) })
            val s = (ms / 1000).coerceAtLeast(0)
            val t = "%02d:%02d".format(s / 60 % 100, s % 60)
            c.drawText(t, x, y, Paint(p).apply { color = PEACH; setShadowLayer(6 * d, 0f, 0f, Color.argb(150, 239, 175, 134)) })
            return b
        }

        // MARK: drawing (in dp; the canvas is scaled to Geo.SCALE pixels per dp)

        private fun canvas(wDp: Float, hDp: Float): Pair<Bitmap, Canvas> {
            val b = Bitmap.createBitmap(max(1, (wDp * Geo.SCALE).roundToInt()), max(1, (hDp * Geo.SCALE).roundToInt()), Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            c.scale(Geo.SCALE, Geo.SCALE)
            return b to c
        }

        /// lilac → light blue → peach by height, like the app's visualisers.
        private fun dotColor(h: Float): Int {
            fun mix(a: Int, b: Int, t: Float) = Color.rgb(
                (Color.red(a) + (Color.red(b) - Color.red(a)) * t).toInt(),
                (Color.green(a) + (Color.green(b) - Color.green(a)) * t).toInt(),
                (Color.blue(a) + (Color.blue(b) - Color.blue(a)) * t).toInt(),
            )
            return if (h < 0.5f) mix(LILAC, BLUE, h * 2) else mix(BLUE, PEACH, (h - 0.5f) * 2)
        }

        private fun smart(x0: Float, x1: Float, alpha: Int = 255) =
            LinearGradient(x0, 0f, x1, 0f, intArrayOf(Color.argb(alpha, 169, 200, 240), Color.argb(alpha, 239, 175, 134), Color.argb(alpha, 187, 150, 218)), null, Shader.TileMode.CLAMP)

        /// The casing: violet graphite with granite flecks (Sonique's texture, in the app's near-black), a sheen and a
        /// specular line along the top, a real bevel (light top-left, dark bottom-right) and the app's iridescent rim.
        /// An open edge (where body and drawer join) gets no rim or bevel.
        private fun shell(c: Canvas, w: Float, h: Float, path: Path, openTop: Boolean, openBottom: Boolean, base: Int?) {
            c.drawPath(path, paint {
                shader = if (base != null) LinearGradient(0f, 0f, 0f, h, base, Color.parseColor("#FF0E0D13"), Shader.TileMode.CLAMP)
                else LinearGradient(0f, 0f, 0f, h, intArrayOf(Color.parseColor("#FF34303F"), Color.parseColor("#FF1F1C27"), Color.parseColor("#FF1C1A23")), floatArrayOf(0f, 0.55f, 1f), Shader.TileMode.CLAMP)
            })
            c.save()
            c.clipPath(path)
            val rnd = Random(if (base == null) 7 else 31)
            val fleck = paint {}
            repeat((w * h / 7).toInt()) {
                fleck.color = if (rnd.nextBoolean()) Color.argb(rnd.nextInt(10, 34), 255, 255, 255) else Color.argb(rnd.nextInt(30, 80), 0, 0, 0)
                c.drawCircle(rnd.nextFloat() * w, rnd.nextFloat() * h, rnd.nextFloat() * 0.75f + 0.2f, fleck)
            }
            // Faint swirls, like Sonique's organic shell
            val swirl = paint { style = Paint.Style.STROKE; strokeWidth = 0.6f; color = Color.argb(14, 187, 150, 218) }
            repeat(16) { i -> c.drawCircle(w * 0.2f, h + 60f, 70f + i * 12f, swirl) }
            if (!openTop) {
                c.drawRect(0f, 0f, w, h * 0.4f, Paint().apply { shader = LinearGradient(0f, 0f, 0f, h * 0.4f, Color.argb(26, 255, 255, 255), Color.TRANSPARENT, Shader.TileMode.CLAMP) })
                c.drawRoundRect(RectF(Geo.R, 2.4f, w - Geo.R, 3.4f), 1f, 1f, paint { shader = LinearGradient(Geo.R, 0f, w - Geo.R, 0f, intArrayOf(Color.TRANSPARENT, Color.argb(90, 255, 255, 255), Color.TRANSPARENT), null, Shader.TileMode.CLAMP) })
            }
            c.restore()
            c.save()
            c.clipRect(0f, if (openTop) 1.5f else 0f, w, if (openBottom) h - 1.5f else h)
            // Bevel inside the rim
            c.save()
            c.clipPath(path)
            c.drawPath(path, paint { style = Paint.Style.STROKE; strokeWidth = 4.5f; shader = LinearGradient(0f, 0f, w * 0.4f, h, Color.argb(70, 255, 255, 255), Color.argb(110, 0, 0, 0), Shader.TileMode.CLAMP) })
            c.restore()
            c.drawPath(path, paint { style = Paint.Style.STROKE; strokeWidth = 1.6f; shader = smart(0f, w, 200) })
            c.restore()
        }

        /// A small machine screw, for the old-hardware feel.
        private fun screw(c: Canvas, x: Float, y: Float) {
            c.drawCircle(x, y, 3.8f, paint { shader = RadialGradient(x - 1.3f, y - 1.3f, 4.6f, Color.parseColor("#FFB5B1BF"), Color.parseColor("#FF2A2733"), Shader.TileMode.CLAMP) })
            c.drawCircle(x, y, 3.8f, paint { style = Paint.Style.STROKE; strokeWidth = 0.6f; color = Color.BLACK })
            c.drawLine(x - 2.3f, y + 1f, x + 2.3f, y - 1f, paint { strokeWidth = 1f; color = Color.parseColor("#FF141218") })
        }

        /// A raised plate (bevelled, flecked) — the pod the dial sits on.
        private fun plate(c: Canvas, r: RectF, radius: Float) {
            c.drawRoundRect(RectF(r.left + 1.5f, r.top + 3f, r.right + 1.5f, r.bottom + 3f), radius, radius, paint { color = Color.argb(150, 0, 0, 0) })
            val path = Path().apply { addRoundRect(r, radius, radius, Path.Direction.CW) }
            c.drawPath(path, paint { shader = LinearGradient(0f, r.top, 0f, r.bottom, Color.parseColor("#FF3A3646"), Color.parseColor("#FF17151D"), Shader.TileMode.CLAMP) })
            c.save()
            c.clipPath(path)
            val rnd = Random(11)
            val fleck = paint {}
            repeat((r.width() * r.height() / 7).toInt()) {
                fleck.color = if (rnd.nextBoolean()) Color.argb(rnd.nextInt(10, 34), 255, 255, 255) else Color.argb(rnd.nextInt(30, 80), 0, 0, 0)
                c.drawCircle(r.left + rnd.nextFloat() * r.width(), r.top + rnd.nextFloat() * r.height(), rnd.nextFloat() * 0.75f + 0.2f, fleck)
            }
            c.drawPath(path, paint { style = Paint.Style.STROKE; strokeWidth = 4f; shader = LinearGradient(r.left, r.top, r.right, r.bottom, Color.argb(80, 255, 255, 255), Color.argb(120, 0, 0, 0), Shader.TileMode.CLAMP) })
            c.restore()
            c.drawPath(path, paint { style = Paint.Style.STROKE; strokeWidth = 0.8f; color = Color.BLACK })
        }

        /// The body's outline, Sonique-style: one smooth shape — the logo bump flowing into the slab through an S-curve,
        /// the slab filleted into the round pod, the pod swelling past the slab top and bottom.
        private fun bodyOutline(w: Float): Path {
            val l = 1.5f
            val t = Geo.SLAB_T
            val bt = Geo.SLAB_B
            val cx = w - Geo.DIAL_END - Geo.DIAL / 2
            val cy = Geo.DIAL_CY
            val r = Geo.POD_R
            val xt = cx - sqrt(r * r - (cy - t) * (cy - t))
            val xb = cx - sqrt(r * r - (bt - cy) * (bt - cy))
            val bumpEnd = minOf(186f, xt - 28f)
            val bumpStart = bumpEnd - 36f
            fun on(a: Double) = Pair(cx + r * kotlin.math.cos(Math.toRadians(a)).toFloat(), cy + r * kotlin.math.sin(Math.toRadians(a)).toFloat())
            val aTop = Math.toDegrees(atan2((t - cy).toDouble(), (xt - cx).toDouble())) + 12
            val aBot = Math.toDegrees(atan2((bt - cy).toDouble(), (xb - cx).toDouble())) - 12
            val (p1x, p1y) = on(aTop)
            val (p2x, p2y) = on(aBot)
            // Tangents (clockwise) at the two pod points, for smooth fillets
            val t1x = -kotlin.math.sin(Math.toRadians(aTop)).toFloat()
            val t1y = kotlin.math.cos(Math.toRadians(aTop)).toFloat()
            val t2x = -kotlin.math.sin(Math.toRadians(aBot)).toFloat()
            val t2y = kotlin.math.cos(Math.toRadians(aBot)).toFloat()
            val r1 = 18f
            val r2 = 24f
            return Path().apply {
                moveTo(l + r1, 4f)
                lineTo(bumpStart, 4f)
                cubicTo(bumpStart + 20f, 4f, bumpEnd - 20f, t, bumpEnd, t)              // the S-curve down to the slab
                lineTo(xt - 20f, t)
                cubicTo(xt - 6f, t, p1x - t1x * 12f, p1y - t1y * 12f, p1x, p1y)           // fillet into the pod
                arcTo(RectF(cx - r, cy - r, cx + r, cy + r), aTop.toFloat(), (aBot - aTop + 360).toFloat() % 360)
                cubicTo(p2x + t2x * 12f, p2y + t2y * 12f, xb - 6f, bt, xb - 20f, bt)      // fillet out of the pod
                lineTo(l + r2, bt)
                quadTo(l, bt, l, bt - r2)
                lineTo(l, 4f + r1)
                quadTo(l, 4f, l + r1, 4f)
                close()
            }
        }

        /// A drawer's outline: a tray whose top steps down past the tabs with an S-curve (the tabs plug into it).
        private fun drawerOutline(w: Float, h: Float): Path {
            val l = 1.5f
            val tabsEnd = Geo.tabsEnd(w)
            val drop = 12f
            val r = 26f
            return Path().apply {
                moveTo(l, 12f)
                quadTo(l, 0f, l + 12f, 0f)
                lineTo(tabsEnd + 10f, 0f)
                cubicTo(tabsEnd + 26f, 0f, tabsEnd + 26f, drop, tabsEnd + 42f, drop)
                lineTo(w - l - 18f, drop)
                quadTo(w - l, drop, w - l, drop + 18f)
                lineTo(w - l, h - l - r)
                quadTo(w - l, h - l, w - l - r, h - l)
                lineTo(l + r, h - l)
                quadTo(l, h - l, l, h - l - r)
                close()
            }
        }

        private fun roundRect(r: RectF, tl: Float, tr: Float, br: Float, bl: Float) =
            Path().apply { addRoundRect(r, floatArrayOf(tl, tl, tr, tr, br, br, bl, bl), Path.Direction.CW) }

        /// The app's icon tile: the pixel-art record on a beige rounded square (theme.dart PixelRecordLogo).
        private fun pixelRecord(c: Canvas, x: Float, y: Float, size: Float) {
            c.drawRoundRect(RectF(x, y, x + size, y + size), size * 0.225f, size * 0.225f, paint {
                shader = LinearGradient(0f, y, 0f, y + size, Color.parseColor("#FFF1ECE4"), Color.parseColor("#FFDCD5CA"), Shader.TileMode.CLAMP)
            })
            val inner = size * 0.78f
            val ox = x + (size - inner) / 2
            val oy = y + (size - inner) / 2
            val px = inner / 32
            val cell = Paint()
            for (gy in 0 until 32) for (gx in 0 until 32) {
                val dx = gx - 15.5
                val dy = gy - 15.5
                val r = sqrt(dx * dx + dy * dy)
                val angle = atan2(dy, dx) * 180 / Math.PI
                cell.color = when {
                    r < 1.6 -> continue
                    r < 3.6 -> LILAC
                    r < 5.6 -> PEACH
                    r < 6.3 -> Color.parseColor("#FF050506")
                    r < 14.6 -> {
                        val glint = (angle > -150 && angle < -118) || (angle > 30 && angle < 62)
                        val band = ((r - 6.3) / 1.7).toInt() % 2 == 0
                        Color.parseColor(if (glint) (if (band) "#FF4A4A56" else "#FF5C5C6A") else (if (band) "#FF15151A" else "#FF202027"))
                    }
                    r < 15.6 -> Color.parseColor("#FF34343E")
                    else -> continue
                }
                c.drawRect(ox + gx * px, oy + gy * px, ox + (gx + 1) * px + 0.05f, oy + (gy + 1) * px + 0.05f, cell)
            }
        }

        /// A recessed bed: a dark lip around the LCD / seek bar so they sit into the shell.
        private fun bed(c: Canvas, r: RectF, radius: Float) {
            c.drawRoundRect(RectF(r.left - 2, r.top - 2, r.right + 2, r.bottom + 2), radius + 2, radius + 2, paint {
                shader = LinearGradient(0f, r.top, 0f, r.bottom, Color.parseColor("#FF020203"), Color.parseColor("#33FFFFFF"), Shader.TileMode.CLAMP)
            })
        }

        /// The body: the funky casing (bodyOutline), the raised pod the dial sits on (with four screws), the logo bump
        /// (tile + glowing WRECKBOX), the LCD and seek beds.
        private fun body(w: Float, playing: Boolean): Bitmap {
            val h = Geo.BODY_H
            val (b, c) = canvas(w, h)
            shell(c, w, h, bodyOutline(w), openTop = false, openBottom = false, base = null)
            // The pod: a raised round plate under the dial, screwed down at the diagonals
            val cx = w - Geo.DIAL_END - Geo.DIAL / 2
            val cy = Geo.DIAL_CY
            plateCircle(c, cx, cy, Geo.POD_R - 7f)
            for (a in listOf(45.0, 135.0, 225.0, 315.0)) {
                screw(c, cx + (Geo.POD_R - 12f) * kotlin.math.cos(Math.toRadians(a)).toFloat(), cy + (Geo.POD_R - 12f) * kotlin.math.sin(Math.toRadians(a)).toFloat())
            }
            // Logo bump: the app's tile + WRECKBOX in Doto with a glowing gradient fill and a dark outline
            // Header, centred on the strip between the bump's top edge (y 4) and the LCD bed (y TOP − 2), its left edge on
            // the LCD's: the tile, then WRECKBOX centred on its letters' measured height (not its font metrics).
            val midY = (4f + Geo.TOP - 2f) / 2
            val tile = 20f
            pixelRecord(c, Geo.G, midY - tile / 2, tile)
            val word = paint { typeface = dotFace(); isFakeBoldText = true; textSize = 13.5f; letterSpacing = 0.16f }
            val bounds = android.graphics.Rect()
            word.getTextBounds("WRECKBOX", 0, 8, bounds)
            val wx = Geo.G + tile + 9f
            val wy = midY - (bounds.top + bounds.bottom) / 2f
            c.drawText("WRECKBOX", wx, wy, Paint(word).apply { color = Color.argb(160, 187, 150, 218); setShadowLayer(5f, 0f, 0f, LILAC) })
            c.drawText("WRECKBOX", wx, wy, Paint(word).apply { style = Paint.Style.STROKE; strokeWidth = 1.6f; color = Color.parseColor("#FF0B0A0F") })
            c.drawText("WRECKBOX", wx, wy, Paint(word).apply { shader = LinearGradient(wx, 0f, wx + word.measureText("WRECKBOX"), 0f, intArrayOf(BLUE, PEACH, LILAC), null, Shader.TileMode.CLAMP) })
            // Status light on the slab, right of the bump
            c.drawCircle(w - Geo.LCD_RIGHT - 6f, Geo.SLAB_T + 7f, 2.6f, paint { color = if (playing) PEACH else Color.argb(50, 255, 255, 255); if (playing) setShadowLayer(5f, 0f, 0f, PEACH) })
            bed(c, RectF(Geo.G, Geo.TOP, w - Geo.LCD_RIGHT, Geo.TOP + Geo.LCD_H), 12f)
            bed(c, RectF(Geo.G, Geo.SEEK_T, w - Geo.LCD_RIGHT, Geo.SEEK_T + Geo.SEEK_H), 3f)
            screw(c, 11f, Geo.SLAB_B - 11f)
            return b
        }

        /// A round raised plate (bevelled, flecked) for the pod.
        private fun plateCircle(c: Canvas, cx: Float, cy: Float, r: Float) {
            c.drawCircle(cx + 1.5f, cy + 3f, r, paint { color = Color.argb(150, 0, 0, 0) })
            val path = Path().apply { addCircle(cx, cy, r, Path.Direction.CW) }
            c.drawPath(path, paint { shader = LinearGradient(0f, cy - r, 0f, cy + r, Color.parseColor("#FF3E3A4B"), Color.parseColor("#FF15131B"), Shader.TileMode.CLAMP) })
            c.save()
            c.clipPath(path)
            val rnd = Random(11)
            val fleck = paint {}
            repeat((r * r * 4 / 7).toInt()) {
                fleck.color = if (rnd.nextBoolean()) Color.argb(rnd.nextInt(10, 34), 255, 255, 255) else Color.argb(rnd.nextInt(30, 80), 0, 0, 0)
                c.drawCircle(cx - r + rnd.nextFloat() * 2 * r, cy - r + rnd.nextFloat() * 2 * r, rnd.nextFloat() * 0.75f + 0.2f, fleck)
            }
            c.drawPath(path, paint { style = Paint.Style.STROKE; strokeWidth = 4f; shader = LinearGradient(cx - r, cy - r, cx + r, cy + r, Color.argb(90, 255, 255, 255), Color.argb(130, 0, 0, 0), Shader.TileMode.CLAMP) })
            c.restore()
            c.drawPath(path, paint { style = Paint.Style.STROKE; strokeWidth = 0.8f; color = Color.BLACK })
        }

        /// The lock-screen widget's casing: the body's shell as a plain rounded slab (no pod, no tabs).
        private fun lockShell(w: Float): Bitmap {
            val h = Geo.LCD_H + Geo.SEEK_H + 2 * Geo.G + 12f + 52f
            val (b, c) = canvas(w, h)
            shell(c, w, h, roundRect(RectF(1.5f, 1.5f, w - 1.5f, h - 1.5f), Geo.R, Geo.R, Geo.R, Geo.R), openTop = false, openBottom = false, base = null)
            bed(c, RectF(Geo.G, Geo.G, w - Geo.G, Geo.G + Geo.LCD_H), 12f)
            bed(c, RectF(Geo.G, Geo.G + Geo.LCD_H + 8f, w - Geo.G, Geo.G + Geo.LCD_H + 8f + Geo.SEEK_H), 3f)
            return b
        }

        /// A drawer: the same casing as a tray (drawerOutline) hanging off the tabs; the open tab flows into it (the
        /// rim is left out under that tab).
        private fun drawerShell(w: Float, tab: Int): Bitmap {
            val h = Geo.DRAWER_H
            val (b, c) = canvas(w, h)
            shell(c, w, h, drawerOutline(w, h), openTop = false, openBottom = false, base = DRAWER)
            val widths = Geo.tabs(w)
            val tabL = Geo.G + widths.take(tab).sum() + tab * Geo.TAB_GAP
            val tabR = tabL + widths[tab]
            c.drawRect(tabL + 1f, 0f, tabR - 1f, 3f, Paint().apply { color = DRAWER })
            screw(c, 11f, h - 11f)
            screw(c, w - 11f, h - 11f)
            return b
        }

        /// The LCD: deep violet glass with Sonique's ripple rings (in lilac), ghost dots, scanlines and a glare; the
        /// track counter, title and artist. The clock and the animated spectrum are separate images on top.
        private fun lcd(w: Float, h: Float, s: Snap): Bitmap {
            val title = s.title
            val (b, c) = canvas(w, h)
            val r = RectF(0f, 0f, w, h)
            c.save()
            c.clipPath(Path().apply { addRoundRect(r, 12f, 12f, Path.Direction.CW) })
            c.drawRect(r, Paint().apply { shader = RadialGradient(w * 0.88f, h * 1.1f, w, Color.parseColor("#FF2A1F3D"), Color.parseColor("#FF07060B"), Shader.TileMode.CLAMP) })
            val ring = paint { style = Paint.Style.STROKE; strokeWidth = 2.2f }
            for (i in 1..26) {
                ring.color = Color.argb(max(6, 46 - i * 2), 187, 150, 218)
                c.drawCircle(w * 0.88f, h * 1.1f, i * 8f, ring)
            }
            val ghost = paint { color = Color.argb(9, 255, 255, 255) }
            var y = 3f
            while (y < h) { var x = 3f; while (x < w) { c.drawCircle(x, y, 0.5f, ghost); x += 3.4f }; y += 3.4f }
            val scan = Paint().apply { color = Color.argb(26, 0, 0, 0) }
            y = 0f
            while (y < h) { c.drawRect(0f, y, w, y + 0.7f, scan); y += 2f }
            c.drawText(s.track.takeIf { it.isNotEmpty() }?.let { "TRK $it" } ?: "TRK ---/---", 10f, 50f,
                paint { typeface = dotFace(); isFakeBoldText = true; textSize = 8.5f; letterSpacing = 0.15f; color = Color.argb(150, 187, 150, 218) })
            // Badges on the same row, right: source · format · shuffle · volume
            val chip = paint { typeface = dotFace(); isFakeBoldText = true; textSize = 7.5f; letterSpacing = 0.1f; color = LILAC }
            var bx = w - 10f
            for (t in listOf("VOL ${s.volume}", if (s.shuffle) "SHUF" else "", s.format, when (s.source) { Source.LOCAL -> "PHONE"; Source.YOUTUBE -> "YTM"; Source.SPOTIFY -> "SPOT"; null -> "" }).filter { it.isNotEmpty() }) {
                val tw = chip.measureText(t) + 10f
                bx -= tw
                c.drawRoundRect(RectF(bx, 42f, bx + tw, 53f), 3f, 3f, paint { style = Paint.Style.STROKE; strokeWidth = 0.8f; color = Color.argb(140, 187, 150, 218) })
                c.drawText(t, bx + 5f, 50.4f, chip)
                bx -= 4f
            }
            c.drawLine(10f, 57f, w - 10f, 57f, paint { color = Color.argb(40, 187, 150, 218); strokeWidth = 0.8f })
            val tp = paint { typeface = urbanist(700); textSize = 14.5f; color = TEXT; setShadowLayer(4f, 0f, 0f, Color.argb(120, 187, 150, 218)) }
            c.drawText(fit(title ?: "Nothing playing", tp, w - 20f), 10f, 77f, tp)
            val ap = paint { typeface = urbanist(500); textSize = 11.5f; color = TEXT2 }
            c.drawText(fit(s.artist ?: "Tap play to pick up where you left off", ap, w - 20f), 10f, 93f, ap)
            c.drawPath(Path().apply { moveTo(w * 0.52f, 0f); lineTo(w * 0.76f, 0f); lineTo(w * 0.46f, h); lineTo(w * 0.22f, h); close() },
                Paint().apply { shader = LinearGradient(0f, 0f, 0f, h, Color.argb(20, 255, 255, 255), Color.argb(2, 255, 255, 255), Shader.TileMode.CLAMP) })
            c.restore()
            c.drawRoundRect(RectF(0.5f, 0.5f, w - 0.5f, h - 0.5f), 12f, 12f, paint { style = Paint.Style.STROKE; strokeWidth = 1f; color = Color.argb(60, 187, 150, 218) })
            return b
        }

        /// The spectrum: 8 columns × 6 dots lit by the music's real levels (Levels), lilac → peach. No levels (paused,
        /// Spotify, screen just turned on): all dots dim — nothing made up.
        private fun spectrumFrame(bands: FloatArray?): Bitmap {
            val w = 62f
            val h = 30f
            val (b, c) = canvas(w, h)
            val cols = Levels.BANDS
            val rows = 6
            val gap = 1.6f
            val dw = (w - (cols - 1) * gap) / cols
            val dh = (h - (rows - 1) * gap) / rows
            for (i in 0 until cols) {
                val lit = if (bands == null) 0 else (bands[i] * rows + 0.35f).toInt().coerceIn(0, rows)
                for (row in 0 until rows) {
                    val x0 = i * (dw + gap)
                    val y0 = h - (row + 1) * dh - row * gap
                    val on = row < lit
                    val color = if (on) dotColor(row / (rows - 1f)) else Color.argb(22, 255, 255, 255)
                    c.drawRoundRect(RectF(x0, y0, x0 + dw, y0 + dh), 0.9f, 0.9f, paint { this.color = color })
                }
            }
            return b
        }

        /// The dial: a graphite jog ring with the iridescent rim, four glossy raised keys (previous, next, volume up /
        /// down) and a well for the candy play button. Glyphs sit at each key's centre — where the touch targets are.
        private fun dial(): Bitmap {
            val d = Geo.DIAL
            val (b, c) = canvas(d, d)
            val cx = d / 2
            val cy = d / 2
            val outer = d / 2 - 1.5f
            c.drawCircle(cx, cy, outer, paint { shader = RadialGradient(cx - 20f, cy - 24f, outer * 1.5f, Color.parseColor("#FF4A4558"), Color.parseColor("#FF100E15"), Shader.TileMode.CLAMP) })
            c.drawCircle(cx, cy, outer - 2f, paint { style = Paint.Style.STROKE; strokeWidth = 3.5f; shader = LinearGradient(0f, 0f, d, d, Color.argb(90, 255, 255, 255), Color.argb(130, 0, 0, 0), Shader.TileMode.CLAMP) })
            c.drawCircle(cx, cy, outer, paint { style = Paint.Style.STROKE; strokeWidth = 1.6f; shader = SweepGradient(cx, cy, intArrayOf(BLUE, PEACH, LILAC, BLUE), null) })
            val rIn = 36f
            val rOut = 55f
            for (k in 0 until 4) {
                val start = -90f + k * 90f - 42f
                val path = Path().apply {
                    arcTo(RectF(cx - rOut, cy - rOut, cx + rOut, cy + rOut), start, 84f)
                    arcTo(RectF(cx - rIn, cy - rIn, cx + rIn, cy + rIn), start + 84f, -84f)
                    close()
                }
                // Raised key: drop shadow, body, gloss on the top-left
                c.save(); c.translate(0.8f, 1.6f); c.drawPath(path, paint { color = Color.argb(150, 0, 0, 0) }); c.restore()
                c.drawPath(path, paint { shader = LinearGradient(0f, 0f, d, d, Color.parseColor("#FF3D3949"), Color.parseColor("#FF1A1822"), Shader.TileMode.CLAMP) })
                c.save(); c.clipPath(path)
                c.drawCircle(cx - 14f, cy - 18f, rOut, paint { shader = RadialGradient(cx - 14f, cy - 18f, rOut, Color.argb(60, 255, 255, 255), Color.TRANSPARENT, Shader.TileMode.CLAMP) })
                c.restore()
                c.drawPath(path, paint { style = Paint.Style.STROKE; strokeWidth = 0.8f; color = Color.argb(70, 255, 255, 255) })
            }
            val mid = (rIn + rOut) / 2
            val glyph = paint { color = Color.argb(235, 255, 255, 255); setShadowLayer(1.2f, 0f, 0.8f, Color.BLACK) }
            val g = 4.4f
            c.drawRoundRect(RectF(cx - g, cy - mid - 0.9f, cx + g, cy - mid + 0.9f), 0.8f, 0.8f, glyph)
            c.drawRoundRect(RectF(cx - 0.9f, cy - mid - g, cx + 0.9f, cy - mid + g), 0.8f, 0.8f, glyph)
            c.drawRoundRect(RectF(cx - g, cy + mid - 0.9f, cx + g, cy + mid + 0.9f), 0.8f, 0.8f, glyph)
            val lx = cx - mid
            c.drawRect(lx - 4.6f, cy - 4.4f, lx - 3f, cy + 4.4f, glyph)
            c.drawPath(Path().apply { moveTo(lx + 4.6f, cy - 4.6f); lineTo(lx - 2.6f, cy); lineTo(lx + 4.6f, cy + 4.6f); close() }, glyph)
            val rx = cx + mid
            c.drawRect(rx + 3f, cy - 4.4f, rx + 4.6f, cy + 4.4f, glyph)
            c.drawPath(Path().apply { moveTo(rx - 4.6f, cy - 4.6f); lineTo(rx + 2.6f, cy); lineTo(rx - 4.6f, cy + 4.6f); close() }, glyph)
            val tiny = paint { typeface = dotFace(); isFakeBoldText = true; textSize = 5.5f; letterSpacing = 0.15f; color = Color.argb(170, 187, 150, 218); textAlign = Paint.Align.CENTER }
            c.drawText("VOL", cx, cy - mid + 11.5f, tiny)
            c.drawText("VOL", cx, cy + mid - 7f, tiny)
            c.drawCircle(cx, cy, 33f, paint { color = Color.parseColor("#FF07060A") })
            c.drawCircle(cx, cy, 33f, paint { style = Paint.Style.STROKE; strokeWidth = 1f; shader = LinearGradient(0f, cy - 33f, 0f, cy + 33f, Color.argb(140, 0, 0, 0), Color.argb(60, 255, 255, 255), Shader.TileMode.CLAMP) })
            return b
        }

        /// The app's EQ: ten dot columns from −12 to +12 dB, lit from the 0 line, lilac → peach; preset name on top.
        private fun eqPanel(w: Float, h: Float, gains: List<Float>, on: Boolean, preset: String, note: String?): Bitmap {
            val (b, c) = canvas(w, h)
            val r = RectF(0.5f, 0.5f, w - 0.5f, h - 0.5f)
            c.drawRoundRect(r, 12f, 12f, paint { shader = LinearGradient(0f, 0f, 0f, h, Color.parseColor("#FF120F1A"), Color.parseColor("#FF07060A"), Shader.TileMode.CLAMP) })
            c.drawRoundRect(r, 12f, 12f, paint { style = Paint.Style.STROKE; strokeWidth = 1.5f; color = Color.parseColor("#FF050407") })
            c.drawText("EQUALISER", 10f, 17f, paint { typeface = dotFace(); isFakeBoldText = true; textSize = 8.5f; letterSpacing = 0.15f; color = TEXT3 })
            c.drawText(note ?: if (on) preset else "Off", w - 10f, 17f, paint { typeface = urbanist(650); textSize = 10.5f; color = if (on) LILAC else TEXT3; textAlign = Paint.Align.RIGHT })
            val dots = 13
            val half = dots / 2
            val top = 28f
            val bottom = h - 18f
            val step = (bottom - top) / (dots - 1)
            val colW = (w - 20f) / 10
            val names = listOf("32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K")
            val bandLabel = paint { typeface = dotFace(); isFakeBoldText = true; textSize = 6f; color = TEXT3; textAlign = Paint.Align.CENTER }
            for (i in 0 until 10) {
                val x = 10f + colW * (i + 0.5f)
                val level = (gains[i] / 12f * half).roundToInt()
                for (row in 0 until dots) {
                    val k = half - row
                    val lit = (level > 0 && k in 1..level) || (level < 0 && k < 0 && k >= level)
                    val color = when {
                        k == 0 -> TEXT3
                        lit && on -> dotColor(row / (dots - 1f))
                        lit -> Color.argb(90, 255, 255, 255)
                        else -> Color.argb(18, 255, 255, 255)
                    }
                    val yy = top + row * step
                    c.drawRoundRect(RectF(x - 3.4f, yy - 1.3f, x + 3.4f, yy + 1.3f), 1f, 1f, paint { this.color = color; if (lit && on) setShadowLayer(2.5f, 0f, 0f, color) })
                }
                c.drawText(names[i], x, h - 7f, bandLabel)
            }
            return b
        }

        private fun fit(s: String, p: Paint, w: Float): String {
            if (p.measureText(s) <= w) return s
            var n = s.length
            while (n > 1 && p.measureText(s.take(n) + "…") > w) n--
            return s.take(n) + "…"
        }
    }
}
