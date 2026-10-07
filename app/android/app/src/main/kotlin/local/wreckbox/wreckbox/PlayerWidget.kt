package local.wreckbox.wreckbox

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
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
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.RemoteViews
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt
import kotlin.random.Random

// Home-screen player: a Y2K player shell — smoked translucent plastic with an iridescent rim and a glossy highlight,
// an LCD with ghost segments and glare, a round Sonique-style dial, tabs hanging off the bottom edge that pull out
// drawers — built in the app's own design language: its near-black glass, the lilac / light-blue / peach gradient,
// Doto for the display and dot labels, Urbanist for text, white and glass pills. The body and an open drawer are
// drawn as one continuous shape.
//
// The shell, LCD, dial and EQ are bitmaps drawn at the widget's real width from the same dp grid as
// res/layout/wb_widget.xml (Geo). The app pushes what's playing (update(), from Dart through MainActivity);
// buttons go back to the app's Dart side on the audio service's engine ("wreckbox/widget").
class PlayerWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = render(context)

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = render(context)

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val action = intent.getStringExtra(EXTRA) ?: return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        when (action) {
            // Drawers open / close inside the widget; one at a time.
            "drawer:controls", "drawer:eq" -> {
                val want = action.removePrefix("drawer:")
                prefs.edit().putString("drawer", if (prefs.getString("drawer", "") == want) "" else want).apply()
                render(context)
            }
            "open" -> context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            else -> toApp(context, action)
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
        const val TAB_EQ_W = 104f
        const val TAB_GAP = 6f
        const val TAB_OPT_W = 92f
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
    }

    companion object {
        const val PREFS = "wreckbox_widget"
        private const val EXTRA = "wb_action"
        private const val ENGINE = "audio_service_engine"
        val presets = listOf("Flat", "Bass boost", "Club", "Hip-hop", "Electronic", "Vocal", "Treble", "Loudness")
        private val presetLabels = listOf("Flat", "Bass", "Club", "Hip-hop", "Electro", "Vocal", "Treble", "Loud")
        private val frameIds = listOf(R.id.wb_sf0, R.id.wb_sf1, R.id.wb_sf2, R.id.wb_sf3, R.id.wb_sf4, R.id.wb_sf5, R.id.wb_sf6, R.id.wb_sf7)
        private val presetIds = listOf(R.id.wb_p0, R.id.wb_p1, R.id.wb_p2, R.id.wb_p3, R.id.wb_p4, R.id.wb_p5, R.id.wb_p6, R.id.wb_p7)

        // The app's palette (theme.dart)
        private val TEXT = Color.parseColor("#F0FFFFFF")
        private val TEXT2 = Color.parseColor("#99FFFFFF")
        private val TEXT3 = Color.parseColor("#5CFFFFFF")
        private val HAIR = Color.parseColor("#14FFFFFF")
        private val PEACH = Color.parseColor("#FFEFAF86")
        private val LILAC = Color.parseColor("#FFBB96DA")
        private val BLUE = Color.parseColor("#FFA9C8F0")
        private val DRAWER = Color.parseColor("#FF131218")   // = wb_tab_active

        /// Called by MainActivity when the app's Dart side reports a change.
        fun update(context: Context, state: Map<*, *>) {
            val e = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            for ((k, v) in state) {
                when (v) {
                    is String -> e.putString(k as String, v)
                    is Boolean -> e.putBoolean(k as String, v)
                    is Int -> e.putLong(k as String, v.toLong())
                    is Long -> e.putLong(k as String, v)
                    is Double -> e.putFloat(k as String, v.toFloat())
                    null -> e.remove(k as String)
                }
            }
            e.apply()
            render(context)
        }

        /// A button for the app: run it on the Dart side if the app (its audio service) is alive, else open the app.
        private fun toApp(context: Context, action: String) {
            val engine = FlutterEngineCache.getInstance().get(ENGINE)
            if (engine == null) {
                context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            }
            Handler(Looper.getMainLooper()).post {
                MethodChannel(engine.dartExecutor.binaryMessenger, "wreckbox/widget").invokeMethod("action", action)
            }
        }

        private fun intent(context: Context, action: String, code: Int): PendingIntent =
            PendingIntent.getBroadcast(
                context, code,
                Intent(context, PlayerWidget::class.java).putExtra(EXTRA, action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )

        fun render(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            for (id in manager.getAppWidgetIds(ComponentName(context, PlayerWidget::class.java))) {
                // The width the launcher gave this widget (portrait).
                val w = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH).takeIf { it > 0 } ?: 340
                runCatching { manager.updateAppWidget(id, views(context, w.toFloat())) }
            }
        }

        private fun views(context: Context, w: Float): RemoteViews {
            fonts(context)
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val v = RemoteViews(context.packageName, R.layout.wb_widget)
            val playing = p.getBoolean("playing", false)
            val title = p.getString("title", null)
            val drawer = p.getString("drawer", "") ?: ""
            val eqOn = p.getBoolean("eqOn", true)
            val device = p.getString("device", "PHONE") ?: "PHONE"

            // Body
            v.setImageViewBitmap(R.id.wb_body_bg, body(w, p, drawer.isNotEmpty(), playing))
            v.setImageViewBitmap(R.id.wb_lcd, lcd(w - Geo.G - Geo.LCD_RIGHT, Geo.LCD_H, p, title, playing))
            v.setImageViewBitmap(R.id.wb_dial, dial())
            // Spectrum: 8 frames the launcher flips through, half a beat apart (the track's BPM)
            for ((f, id) in frameIds.withIndex()) v.setImageViewBitmap(id, spectrumFrame(title, playing, f))
            val bpm = p.getFloat("bpm", 120f).takeIf { it in 60f..200f } ?: 120f
            v.setInt(R.id.wb_spectrum, "setFlipInterval", (30000f / bpm).roundToInt().coerceIn(110, 300))
            val pos = if (title == null) 0 else p.getLong("positionMs", 0)
            val since = if (playing) System.currentTimeMillis() - p.getLong("wallMs", System.currentTimeMillis()) else 0
            v.setImageViewBitmap(R.id.wb_clock, clock(context, pos + since, playing, title != null))
            if (playing) startTicking(context) // the clock is a Doto image: redrawn once a second while playing
            val dur = p.getLong("durationMs", 0)
            v.setProgressBar(R.id.wb_progress, 1000, if (dur > 0) ((pos + since) * 1000 / dur).toInt().coerceIn(0, 1000) else 0, false)
            v.setImageViewResource(R.id.wb_play, if (playing) R.drawable.wb_icb_pause else R.drawable.wb_icb_play)

            // Tabs: the open one takes the drawer's colour and flows into it
            for ((tab, name, label) in listOf(Triple(R.id.wb_tab_eq, "eq", "Equaliser"), Triple(R.id.wb_tab_controls, "controls", "Options"))) {
                val open = drawer == name
                v.setInt(tab, "setBackgroundResource", if (open) R.drawable.wb_tab_active else R.drawable.wb_tab_idle)
                v.setImageViewBitmap(tab, ui(context, label, 12f, 700, if (open) LILAC else TEXT2))
            }

            // Drawers
            v.setViewVisibility(R.id.wb_drawer_eq, if (drawer == "eq") View.VISIBLE else View.GONE)
            v.setViewVisibility(R.id.wb_drawer_controls, if (drawer == "controls") View.VISIBLE else View.GONE)
            if (drawer == "eq") {
                v.setImageViewBitmap(R.id.wb_drawer_eq_bg, drawerShell(w, "eq"))
                val inner = w - 2 * Geo.G
                v.setImageViewBitmap(R.id.wb_eq_curve, eqPanel((inner - 8) * 11 / 21, Geo.DRAWER_H - Geo.IN_T - Geo.IN_B, p.getString("gains", "") ?: "", eqOn, p.getString("eqPreset", "Flat") ?: "Flat"))
                v.setImageViewBitmap(R.id.wb_presets_label, dot(context, "Presets", 8.5f, TEXT3))
                v.setInt(R.id.wb_eq_on, "setBackgroundResource", if (eqOn) R.drawable.wb_toggle_on else R.drawable.wb_chip)
                v.setImageViewBitmap(R.id.wb_eq_on, ui(context, if (eqOn) "On" else "Off", 10.5f, 700, if (eqOn) Color.parseColor("#FF141218") else TEXT2))
                val preset = p.getString("eqPreset", "Flat")
                presetIds.forEachIndexed { i, id ->
                    val on = presets[i] == preset
                    v.setInt(id, "setBackgroundResource", if (on) R.drawable.wb_chip_on else R.drawable.wb_chip)
                    v.setImageViewBitmap(id, ui(context, presetLabels[i], 11f, 600, if (on) Color.BLACK else TEXT2))
                }
            }
            if (drawer == "controls") {
                v.setImageViewBitmap(R.id.wb_drawer_controls_bg, drawerShell(w, "controls"))
                val track = p.getString("track", null)?.takeIf { it.isNotEmpty() }
                v.setImageViewBitmap(R.id.wb_info, dot(context, "${if (track == null) "Nothing queued" else "Trk $track"} · on $device", 8.5f, TEXT3))
                for ((id, t) in listOf(R.id.wb_back10 to "−10 s", R.id.wb_fwd10 to "+10 s", R.id.wb_restart to "Restart", R.id.wb_stop to "Stop", R.id.wb_open to "Open app",
                    R.id.wb_handoff to if (device == "PHONE") "Play on Mac" else "Play here")) {
                    v.setImageViewBitmap(id, ui(context, t, 12f, 600, TEXT))
                }
            }

            // Buttons
            val clicks = mapOf(
                R.id.wb_play to "toggle", R.id.wb_prev to "previous", R.id.wb_next to "next",
                R.id.wb_voldown to "voldown", R.id.wb_volup to "volup", R.id.wb_lcd to "open",
                R.id.wb_tab_controls to "drawer:controls", R.id.wb_tab_eq to "drawer:eq",
                R.id.wb_back10 to "back10", R.id.wb_fwd10 to "fwd10", R.id.wb_restart to "restart", R.id.wb_stop to "stop",
                R.id.wb_handoff to "handoff", R.id.wb_open to "open", R.id.wb_eq_on to "eqtoggle",
            ) + presetIds.mapIndexed { i, id -> id to "preset:${presets[i]}" }
            clicks.entries.forEachIndexed { n, (id, action) -> v.setOnClickPendingIntent(id, intent(context, action, n)) }
            return v
        }

        // MARK: the clock, ticking while playing

        private val ticker = Handler(Looper.getMainLooper())
        private var ticking = false

        private fun startTicking(context: Context) {
            if (ticking) return
            ticking = true
            val app = context.applicationContext
            ticker.postDelayed(object : Runnable {
                override fun run() {
                    val p = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    if (!p.getBoolean("playing", false) || p.getString("title", null) == null) { ticking = false; return }
                    val ms = p.getLong("positionMs", 0) + System.currentTimeMillis() - p.getLong("wallMs", System.currentTimeMillis())
                    val manager = AppWidgetManager.getInstance(app)
                    val ids = manager.getAppWidgetIds(ComponentName(app, PlayerWidget::class.java))
                    if (ids.isEmpty()) { ticking = false; return }
                    val v = RemoteViews(app.packageName, R.layout.wb_widget)
                    v.setImageViewBitmap(R.id.wb_clock, clock(app, ms, true, true))
                    val dur = p.getLong("durationMs", 0)
                    if (dur > 0) v.setProgressBar(R.id.wb_progress, 1000, (ms * 1000 / dur).toInt().coerceIn(0, 1000), false)
                    runCatching { manager.partiallyUpdateAppWidget(ids, v) }
                    ticker.postDelayed(this, 1000 - System.currentTimeMillis() % 1000)
                }
            }, 1000)
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
            val tabsEnd = Geo.G + Geo.TAB_EQ_W + Geo.TAB_GAP + Geo.TAB_OPT_W
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
        private fun body(w: Float, p: SharedPreferences, drawerOpen: Boolean, playing: Boolean): Bitmap {
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
            pixelRecord(c, 14f, 7f, 20f)
            val word = paint { typeface = dotFace(); isFakeBoldText = true; textSize = 13.5f; letterSpacing = 0.16f }
            val wx = 14f + 20f + 8f
            val wy = 22.5f
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

        /// A drawer: the same casing as a tray (drawerOutline) hanging off the tabs; the open tab flows into it (the
        /// rim is left out under that tab).
        private fun drawerShell(w: Float, which: String): Bitmap {
            val h = Geo.DRAWER_H
            val (b, c) = canvas(w, h)
            shell(c, w, h, drawerOutline(w, h), openTop = false, openBottom = false, base = DRAWER)
            val tabL = Geo.G + if (which == "eq") 0f else Geo.TAB_EQ_W + Geo.TAB_GAP
            val tabR = tabL + if (which == "eq") Geo.TAB_EQ_W else Geo.TAB_OPT_W
            c.drawRect(tabL + 1f, 0f, tabR - 1f, 3f, Paint().apply { color = DRAWER })
            screw(c, 11f, h - 11f)
            screw(c, w - 11f, h - 11f)
            return b
        }

        /// The LCD: deep violet glass with Sonique's ripple rings (in lilac), ghost dots, scanlines and a glare; the
        /// track counter, title and artist. The clock and the animated spectrum are separate images on top.
        private fun lcd(w: Float, h: Float, p: SharedPreferences, title: String?, playing: Boolean): Bitmap {
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
            c.drawText(p.getString("track", null)?.takeIf { it.isNotEmpty() }?.let { "TRK $it" } ?: "TRK ---/---", 10f, 50f,
                paint { typeface = dotFace(); isFakeBoldText = true; textSize = 8.5f; letterSpacing = 0.15f; color = Color.argb(150, 187, 150, 218) })
            // Badges on the same row, right: device · format
            val chip = paint { typeface = dotFace(); isFakeBoldText = true; textSize = 7.5f; letterSpacing = 0.1f; color = LILAC }
            var bx = w - 10f
            for (t in listOf(p.getString("device", "PHONE") ?: "PHONE", p.getString("format", "") ?: "").filter { it.isNotEmpty() }) {
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
            c.drawText(fit(p.getString("artist", null) ?: "Tap play to pick up where you left off", ap, w - 20f), 10f, 93f, ap)
            c.drawPath(Path().apply { moveTo(w * 0.52f, 0f); lineTo(w * 0.76f, 0f); lineTo(w * 0.46f, h); lineTo(w * 0.22f, h); close() },
                Paint().apply { shader = LinearGradient(0f, 0f, 0f, h, Color.argb(20, 255, 255, 255), Color.argb(2, 255, 255, 255), Shader.TileMode.CLAMP) })
            c.restore()
            c.drawRoundRect(RectF(0.5f, 0.5f, w - 0.5f, h - 0.5f), 12f, 12f, paint { style = Paint.Style.STROKE; strokeWidth = 1f; color = Color.argb(60, 187, 150, 218) })
            return b
        }

        /// One frame of the spectrum (12 × 6 dots, lilac → peach): frames alternate kick / off-beat so the launcher's
        /// flipping, timed to the BPM, pulses with the music. Paused: every frame is the same low still.
        private fun spectrumFrame(title: String?, playing: Boolean, f: Int): Bitmap {
            val w = 62f
            val h = 30f
            val (b, c) = canvas(w, h)
            val cols = 12
            val rows = 6
            val gap = 1.4f
            val dw = (w - (cols - 1) * gap) / cols
            val dh = (h - (rows - 1) * gap) / rows
            val rnd = Random((title ?: "").hashCode() * 31 + if (playing) f else 0)
            // A spectrum's shape: strong lows falling off to the highs; the kick lifts the lows on the beat frames,
            // the rest jitters frame to frame.
            val kick = if (f % 2 == 0) 1f else 0.25f
            for (i in 0 until cols) {
                val t = i / (cols - 1f)
                val shape = 0.85f - 0.55f * t
                val level = when {
                    title == null -> 0f
                    !playing -> shape * 0.35f
                    else -> (shape * (0.45f + 0.4f * kick * (1f - t)) + (rnd.nextFloat() - 0.5f) * 0.45f).coerceIn(0.08f, 1f)
                }
                val lit = (level * rows).roundToInt()
                for (row in 0 until rows) {
                    val x0 = i * (dw + gap)
                    val y0 = h - (row + 1) * dh - row * gap
                    val on = row < lit
                    val color = if (on) dotColor(row / (rows - 1f)) else Color.argb(22, 255, 255, 255)
                    c.drawRoundRect(RectF(x0, y0, x0 + dw, y0 + dh), 0.9f, 0.9f, paint { this.color = color; if (on && row == lit - 1) setShadowLayer(1.4f, 0f, 0f, color) })
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
        private fun eqPanel(w: Float, h: Float, csv: String, on: Boolean, preset: String): Bitmap {
            val gains = csv.split(",").mapNotNull { it.toFloatOrNull() }.let { if (it.size == 10) it else List(10) { 0f } }
            val (b, c) = canvas(w, h)
            val r = RectF(0.5f, 0.5f, w - 0.5f, h - 0.5f)
            c.drawRoundRect(r, 12f, 12f, paint { shader = LinearGradient(0f, 0f, 0f, h, Color.parseColor("#FF120F1A"), Color.parseColor("#FF07060A"), Shader.TileMode.CLAMP) })
            c.drawRoundRect(r, 12f, 12f, paint { style = Paint.Style.STROKE; strokeWidth = 1.5f; color = Color.parseColor("#FF050407") })
            c.drawText("EQUALISER", 10f, 17f, paint { typeface = dotFace(); isFakeBoldText = true; textSize = 8.5f; letterSpacing = 0.15f; color = TEXT3 })
            c.drawText(if (on) preset else "Off", w - 10f, 17f, paint { typeface = urbanist(650); textSize = 10.5f; color = if (on) LILAC else TEXT3; textAlign = Paint.Align.RIGHT })
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
