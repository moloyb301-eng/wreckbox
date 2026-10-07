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
import android.graphics.DashPathEffect
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.random.Random

// Home-screen player in a Y2K skin: Sonique's speckled gunmetal casing, glossy candy buttons and green ripple LCD,
// with Winamp's display (clock, format badges, track counter, spectrum), seek bar and EQUALIZER / OPTIONS tabs that
// open drawers under the body. The casing, LCD and EQ screen are drawn here at the widget's real size from the same
// dp measurements as res/layout/wb_widget.xml (Geo), so every control sits in its well.
//
// The app pushes what's playing (update(), from Dart through MainActivity); buttons go back to the app's Dart side
// on the audio service's engine ("wreckbox/widget").
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

    /// Layout measurements in dp — the same numbers as wb_widget.xml.
    private object Geo {
        const val BODY_H = 186f
        const val LCD_L = 16f
        const val LCD_T = 34f
        const val LCD_R = 116f
        const val LCD_H = 104f
        const val SEEK_L = 18f
        const val SEEK_T = 146f
        const val SEEK_R = 118f
        const val SEEK_H = 7f
        const val TABS_T = 160f
        const val DRAWER_H = 150f
        const val IN_L = 16f
        const val IN_T = 12f
        const val IN_B = 22f
        const val SCALE = 2.5f // bitmap pixels per dp: crisp enough, light on memory
    }

    companion object {
        const val PREFS = "wreckbox_widget"
        private const val EXTRA = "wb_action"
        private const val ENGINE = "audio_service_engine"
        val presets = listOf("Flat", "Bass boost", "Club", "Hip-hop", "Electronic", "Vocal", "Treble", "Loudness")
        private val presetLabels = listOf("FLAT", "BASS", "CLUB", "HIP-HOP", "ELECTRO", "VOCAL", "TREBLE", "LOUD")
        private val presetIds = listOf(R.id.wb_p0, R.id.wb_p1, R.id.wb_p2, R.id.wb_p3, R.id.wb_p4, R.id.wb_p5, R.id.wb_p6, R.id.wb_p7)

        private val LIME = Color.parseColor("#FFB6FF6A")
        private val GREEN = Color.parseColor("#FF5ED13A")
        private val INK = Color.parseColor("#FF0B2A10")
        private val KHAKI = Color.parseColor("#FFD8C46A")

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

        private fun views(context: Context, wDp: Float): RemoteViews {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val v = RemoteViews(context.packageName, R.layout.wb_widget)
            val playing = p.getBoolean("playing", false)
            val title = p.getString("title", null)
            val drawer = p.getString("drawer", "") ?: ""
            val eqOn = p.getBoolean("eqOn", true)
            val device = p.getString("device", "PHONE") ?: "PHONE"

            // Body: casing + LCD, the live clock, the seek bar
            v.setImageViewBitmap(R.id.wb_body_bg, body(context, wDp))
            val pos = if (title == null) 0 else p.getLong("positionMs", 0)
            val since = if (playing) System.currentTimeMillis() - p.getLong("wallMs", System.currentTimeMillis()) else 0
            v.setImageViewBitmap(R.id.wb_lcd, lcd(context, wDp - Geo.LCD_L - Geo.LCD_R, Geo.LCD_H, p, title, playing))
            v.setImageViewBitmap(R.id.wb_clock, clock(context, pos + since))
            if (playing) startTicking(context) // the clock in Doto is an image: the app redraws it once a second
            val dur = p.getLong("durationMs", 0)
            v.setProgressBar(R.id.wb_progress, 1000, if (dur > 0) ((pos + since) * 1000 / dur).toInt().coerceIn(0, 1000) else 0, false)
            v.setImageViewResource(R.id.wb_play, if (playing) R.drawable.wb_icw_pause else R.drawable.wb_icw_play)

            // Tabs + drawers
            v.setViewVisibility(R.id.wb_drawer_eq, if (drawer == "eq") View.VISIBLE else View.GONE)
            v.setViewVisibility(R.id.wb_drawer_controls, if (drawer == "controls") View.VISIBLE else View.GONE)
            for ((tab, name, text) in listOf(Triple(R.id.wb_tab_eq, "eq", "equalizer"), Triple(R.id.wb_tab_controls, "controls", "options"))) {
                val lit = drawer == name
                v.setInt(tab, "setBackgroundResource", if (lit) R.drawable.wb_tab_lit else R.drawable.wb_tab)
                v.setImageViewBitmap(tab, text(context, text, if (lit) Style.LIT else Style.STAMP, 11f))
            }
            if (drawer == "eq") {
                v.setImageViewBitmap(R.id.wb_drawer_eq_bg, drawerBg(wDp, "equalizer"))
                val inner = wDp - 2 * Geo.IN_L
                v.setImageViewBitmap(R.id.wb_eq_curve, eqScreen(context, (inner - 8) * 11 / 21, Geo.DRAWER_H - Geo.IN_T - Geo.IN_B, p.getString("gains", "") ?: "", eqOn))
                v.setInt(R.id.wb_eq_on, "setBackgroundResource", if (eqOn) R.drawable.wb_led_on else R.drawable.wb_led)
                v.setImageViewBitmap(R.id.wb_eq_on, text(context, if (eqOn) "EQ ON" else "EQ OFF", if (eqOn) Style.INK else Style.LED, 9.5f))
                v.setImageViewBitmap(R.id.wb_presets_label, text(context, "PRESETS", Style.DIM, 9f))
                val preset = p.getString("eqPreset", "Flat")
                presetIds.forEachIndexed { i, id ->
                    val on = presets[i] == preset
                    v.setInt(id, "setBackgroundResource", if (on) R.drawable.wb_preset_on else 0)
                    v.setImageViewBitmap(id, text(context, presetLabels[i], if (on) Style.INK else Style.LED, 10f))
                }
            }
            if (drawer == "controls") {
                v.setImageViewBitmap(R.id.wb_drawer_controls_bg, drawerBg(wDp, "options"))
                v.setImageViewBitmap(R.id.wb_info, text(context, "${if (title == null) "NOTHING QUEUED" else "TRACK ${p.getString("track", "")}"} · ON $device", Style.LED, 10f))
                for ((id, t) in listOf(R.id.wb_back10 to "-10 S", R.id.wb_fwd10 to "+10 S", R.id.wb_restart to "RESTART", R.id.wb_open to "OPEN APP",
                    R.id.wb_handoff to if (device == "PHONE") "PLAY ON MAC" else "PLAY HERE")) {
                    v.setImageViewBitmap(id, text(context, t, Style.LED, 11f))
                }
            }

            // Buttons
            val clicks = mapOf(
                R.id.wb_play to "toggle", R.id.wb_prev to "previous", R.id.wb_next to "next", R.id.wb_stop to "stop",
                R.id.wb_voldown to "voldown", R.id.wb_volup to "volup", R.id.wb_lcd to "open",
                R.id.wb_tab_controls to "drawer:controls", R.id.wb_tab_eq to "drawer:eq",
                R.id.wb_back10 to "back10", R.id.wb_fwd10 to "fwd10", R.id.wb_restart to "restart",
                R.id.wb_handoff to "handoff", R.id.wb_open to "open", R.id.wb_eq_on to "eqtoggle",
            ) + presetIds.mapIndexed { i, id -> id to "preset:${presets[i]}" }
            clicks.entries.forEachIndexed { n, (id, action) -> v.setOnClickPendingIntent(id, intent(context, action, n)) }
            return v
        }

        // MARK: labels in the app's fonts, aged

        /// LED = Doto in green phosphor (glow, a little bleed); INK = dark Doto on a lit key; DIM = faint phosphor;
        /// STAMP = Urbanist stamped into the metal (dark cut, light lip).
        private enum class Style { LED, INK, DIM, STAMP, LIT }

        /// A label bitmap at the screen's density (the ImageView centres it), in Doto or Urbanist.
        private fun text(context: Context, s: String, style: Style, sp: Float): Bitmap {
            fonts(context)
            val d = context.resources.displayMetrics.density
            val p = paint {
                typeface = if (style == Style.STAMP || style == Style.LIT) Typeface.create(urbanist ?: Typeface.SANS_SERIF, Typeface.BOLD) else doto ?: Typeface.MONOSPACE
                isFakeBoldText = true
                textSize = sp * d
                letterSpacing = if (style == Style.STAMP || style == Style.LIT) 0.12f else 0.06f
            }
            val label = if (style == Style.STAMP || style == Style.LIT) s.lowercase() else s.uppercase()
            val pad = 6 * d
            val w = (p.measureText(label) + pad * 2).roundToInt()
            val h = (sp * d * 1.6f + pad).roundToInt()
            val b = Bitmap.createBitmap(max(1, w), max(1, h), Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            val x = pad
            val y = h / 2f - (p.descent() + p.ascent()) / 2
            when (style) {
                Style.STAMP -> {
                    c.drawText(label, x, y + 0.8f * d, Paint(p).apply { color = Color.argb(110, 255, 255, 255) })
                    c.drawText(label, x, y - 0.6f * d, Paint(p).apply { color = Color.argb(200, 0, 0, 0) })
                    c.drawText(label, x, y, Paint(p).apply { color = Color.parseColor("#FF9CA2AA") })
                }
                Style.INK -> c.drawText(label, x, y, Paint(p).apply { color = INK })
                Style.DIM -> c.drawText(label, x, y, Paint(p).apply { color = Color.argb(150, 94, 209, 58) })
                Style.LED, Style.LIT -> phosphor(c, label, x, y, p, d)
            }
            return b
        }

        /// Old green-screen glow: a soft halo, a slight sideways bleed, then the bright text.
        private fun phosphor(c: Canvas, s: String, x: Float, y: Float, base: Paint, d: Float) {
            c.drawText(s, x, y, Paint(base).apply { color = GREEN; setShadowLayer(5f * d, 0f, 0f, GREEN) })
            c.drawText(s, x + 0.7f * d, y, Paint(base).apply { color = Color.argb(90, 182, 255, 106) })
            c.drawText(s, x, y, Paint(base).apply { color = LIME })
        }

        /// The clock in Doto: dim "88:88" segments behind lit digits, like an LCD, with the phosphor glow.
        private fun clock(context: Context, ms: Long): Bitmap {
            fonts(context)
            val d = context.resources.displayMetrics.density
            val p = paint { typeface = doto ?: Typeface.MONOSPACE; isFakeBoldText = true; textSize = 25f * d; letterSpacing = 0.04f }
            val s = (ms / 1000).coerceAtLeast(0)
            val t = "%02d:%02d".format(s / 60 % 100, s % 60)
            val w = (130 * d).roundToInt()
            val h = (30 * d).roundToInt()
            val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            val y = h / 2f - (p.descent() + p.ascent()) / 2
            val x = 14 * d
            c.drawText("88:88", x, y, Paint(p).apply { color = Color.argb(34, 140, 255, 110) })
            phosphor(c, t, x, y, p, d)
            return b
        }

        private val ticker = Handler(Looper.getMainLooper())
        private var ticking = false

        /// While playing (the app is alive then), redraw just the clock every second.
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
                    v.setImageViewBitmap(R.id.wb_clock, clock(app, ms))
                    val dur = p.getLong("durationMs", 0)
                    if (dur > 0) v.setProgressBar(R.id.wb_progress, 1000, (ms * 1000 / dur).toInt().coerceIn(0, 1000), false)
                    runCatching { manager.partiallyUpdateAppWidget(ids, v) }
                    ticker.postDelayed(this, 1000 - System.currentTimeMillis() % 1000)
                }
            }, 1000)
        }

        // MARK: drawing (all in dp; the canvas is scaled to Geo.SCALE pixels per dp)

        private var doto: Typeface? = null
        private var urbanist: Typeface? = null
        private fun fonts(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            if (doto == null) doto = runCatching { context.resources.getFont(R.font.doto) }.getOrNull()
            if (urbanist == null) urbanist = runCatching { context.resources.getFont(R.font.urbanist) }.getOrNull()
        }

        private fun canvas(wDp: Float, hDp: Float): Pair<Bitmap, Canvas> {
            val b = Bitmap.createBitmap(max(1, (wDp * Geo.SCALE).roundToInt()), max(1, (hDp * Geo.SCALE).roundToInt()), Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            c.scale(Geo.SCALE, Geo.SCALE)
            return b to c
        }

        private fun paint(block: Paint.() -> Unit) = Paint(Paint.ANTI_ALIAS_FLAG).apply(block)

        /// Speckled gunmetal, like Sonique's casing: a dark gradient, granite flecks, faint swirls, a bevel, a black rim.
        private fun gunmetal(c: Canvas, r: RectF, path: Path, seed: Int) {
            c.drawPath(path, paint {
                shader = LinearGradient(0f, r.top, 0f, r.bottom, intArrayOf(Color.parseColor("#FF5A5F67"), Color.parseColor("#FF2E3136"), Color.parseColor("#FF1B1D21")), floatArrayOf(0f, 0.45f, 1f), Shader.TileMode.CLAMP)
            })
            c.save()
            c.clipPath(path)
            val rnd = Random(seed)
            val fleck = paint {}
            repeat((r.width() * r.height() / 9).toInt()) {
                fleck.color = if (rnd.nextBoolean()) Color.argb(rnd.nextInt(18, 60), 255, 255, 255) else Color.argb(rnd.nextInt(30, 90), 0, 0, 0)
                c.drawCircle(r.left + rnd.nextFloat() * r.width(), r.top + rnd.nextFloat() * r.height(), rnd.nextFloat() * 0.9f + 0.25f, fleck)
            }
            val swirl = paint { style = Paint.Style.STROKE; strokeWidth = 0.6f; color = Color.argb(22, 255, 255, 255) }
            repeat(14) { i -> c.drawCircle(r.left + r.width() * 0.18f, r.bottom + 40f, 60f + i * 13f, swirl) }
            c.restore()
            c.drawPath(path, paint {
                style = Paint.Style.STROKE; strokeWidth = 2.2f
                shader = LinearGradient(r.left, r.top, r.right, r.bottom, Color.parseColor("#CC9AA1AB"), Color.parseColor("#CC0A0B0D"), Shader.TileMode.CLAMP)
            })
            c.drawPath(path, paint { style = Paint.Style.STROKE; strokeWidth = 0.8f; color = Color.BLACK })
        }

        /// A recessed well (dark at the top-left, a light lip at the bottom-right) the screens and seek bar sit in.
        private fun well(c: Canvas, r: RectF, radius: Float) {
            c.drawRoundRect(RectF(r.left - 3, r.top - 3, r.right + 3, r.bottom + 3), radius + 3, radius + 3, paint {
                shader = LinearGradient(r.left, r.top, r.right, r.bottom, Color.parseColor("#FF0A0B0D"), Color.parseColor("#FF7C838D"), Shader.TileMode.CLAMP)
            })
            c.drawRoundRect(RectF(r.left - 1, r.top - 1, r.right + 1, r.bottom + 1), radius + 1, radius + 1, paint { color = Color.parseColor("#FF0B0C0E") })
        }

        private fun screw(c: Canvas, x: Float, y: Float) {
            c.drawCircle(x, y, 4.2f, paint { shader = RadialGradient(x - 1.5f, y - 1.5f, 5f, Color.parseColor("#FFB9BEC6"), Color.parseColor("#FF2C2F34"), Shader.TileMode.CLAMP) })
            c.drawCircle(x, y, 4.2f, paint { style = Paint.Style.STROKE; strokeWidth = 0.6f; color = Color.BLACK })
            c.drawLine(x - 2.6f, y + 1.2f, x + 2.6f, y - 1.2f, paint { strokeWidth = 1.1f; color = Color.parseColor("#FF15171A") })
        }

        /// "wreckbox" in chunky slanted lowercase, lime-to-green with a black outline, like Sonique's logo.
        private fun logo(c: Canvas, x: Float, y: Float, size: Float) {
            val base = paint {
                typeface = Typeface.create(urbanist ?: Typeface.SANS_SERIF, Typeface.BOLD)
                isFakeBoldText = true
                textSize = size
                textSkewX = -0.22f
            }
            val text = "wreckbox"
            c.drawText(text, x + 1.2f, y + 1.6f, Paint(base).apply { color = Color.argb(170, 0, 0, 0) })
            c.drawText(text, x, y, Paint(base).apply { style = Paint.Style.STROKE; strokeWidth = 3.2f; color = Color.parseColor("#FF07140A") })
            c.drawText(text, x, y, Paint(base).apply { shader = LinearGradient(0f, y - size, 0f, y, Color.parseColor("#FFE8FFB0"), Color.parseColor("#FF3FBF2A"), Shader.TileMode.CLAMP) })
        }

        /// Small text drawn on the casing (Urbanist) or a screen (Doto).
        private fun label(size: Float, align: Paint.Align, color: Int = KHAKI, screen: Boolean = false) = paint {
            typeface = if (screen) doto ?: Typeface.MONOSPACE else Typeface.create(urbanist ?: Typeface.SANS_SERIF, Typeface.BOLD)
            isFakeBoldText = true; textSize = size; this.color = color; textAlign = align; letterSpacing = 0.08f
        }

        /// Casing text stamped into the metal: dark cut above, light lip below.
        private fun stamped(c: Canvas, s: String, x: Float, y: Float, p: Paint) {
            c.drawText(s, x, y + 0.5f, Paint(p).apply { color = Color.argb(90, 255, 255, 255) })
            c.drawText(s, x, y - 0.4f, Paint(p).apply { color = Color.argb(200, 0, 0, 0) })
            c.drawText(s, x, y, p)
        }

        /// The body: casing, the raised pod behind the candy buttons, the screen well, the seek groove, logo, screws.
        private fun body(context: Context, w: Float): Bitmap {
            fonts(context)
            val h = Geo.BODY_H
            val (b, c) = canvas(w, h)
            val r = RectF(1f, 1f, w - 1, h - 1)
            gunmetal(c, r, Path().apply { addRoundRect(r, 30f, 30f, Path.Direction.CW) }, 7)
            val pod = RectF(w - 112f, 24f, w - 8f, 166f)
            c.drawRoundRect(RectF(pod.left + 2, pod.top + 3, pod.right + 2, pod.bottom + 3), 46f, 46f, paint { color = Color.argb(120, 0, 0, 0) })
            gunmetal(c, pod, Path().apply { addRoundRect(pod, 46f, 46f, Path.Direction.CW) }, 11)
            well(c, RectF(Geo.LCD_L, Geo.LCD_T, w - Geo.LCD_R, Geo.LCD_T + Geo.LCD_H), 10f)
            well(c, RectF(Geo.SEEK_L, Geo.SEEK_T, w - Geo.SEEK_R, Geo.SEEK_T + Geo.SEEK_H), 4f)
            c.drawLine(18f, Geo.TABS_T - 0.5f, w - 120f, Geo.TABS_T - 0.5f, paint { color = Color.argb(140, 0, 0, 0); strokeWidth = 1f })
            logo(c, 22f, 25f, 19f)
            stamped(c, "audio console", w - 122f, 24f, label(8f, Paint.Align.RIGHT))
            for ((x, y) in listOf(12f to 12f, w - 12f to 12f, 12f to h - 12f, w - 12f to h - 12f)) screw(c, x, y)
            return b
        }

        /// A drawer pulled out under the body: same casing, square top (it slides from under), rounded bottom.
        private fun drawerBg(w: Float, name: String): Bitmap {
            val h = Geo.DRAWER_H
            val (b, c) = canvas(w, h)
            val r = RectF(8f, 0f, w - 8f, h - 1)
            gunmetal(c, r, Path().apply { addRoundRect(r, floatArrayOf(0f, 0f, 0f, 0f, 26f, 26f, 26f, 26f), Path.Direction.CW) }, name.length * 31)
            c.drawRect(RectF(r.left, 0f, r.right, 7f), paint { shader = LinearGradient(0f, 0f, 0f, 7f, Color.argb(200, 0, 0, 0), Color.TRANSPARENT, Shader.TileMode.CLAMP) })
            well(c, RectF(Geo.IN_L, Geo.IN_T, w - Geo.IN_L, h - Geo.IN_B), 10f)
            stamped(c, "audio enhancement · $name", w / 2, h - 8f, label(8f, Paint.Align.CENTER))
            screw(c, 20f, h - 11f)
            screw(c, w - 20f, h - 11f)
            return b
        }

        /// Green screen with Sonique's ripples and Winamp's readout: ▶ / ❚❚, badges, spectrum, track counter, title.
        private fun lcd(context: Context, w: Float, h: Float, p: SharedPreferences, title: String?, playing: Boolean): Bitmap {
            fonts(context)
            val (b, c) = canvas(w, h)
            val r = RectF(0f, 0f, w, h)
            c.save()
            c.clipPath(Path().apply { addRoundRect(r, 10f, 10f, Path.Direction.CW) })
            c.drawRect(r, paint { shader = RadialGradient(w * 0.85f, h * 1.05f, w * 0.9f, Color.parseColor("#FF0F4A1D"), Color.parseColor("#FF03110A"), Shader.TileMode.CLAMP) })
            val ring = paint { style = Paint.Style.STROKE; strokeWidth = 2.4f }
            for (i in 1..24) {
                ring.color = Color.argb(max(10, 64 - i * 2), 70, 200, 80)
                c.drawCircle(w * 0.85f, h * 1.05f, i * 8.5f, ring)
            }
            val scan = Paint().apply { color = Color.argb(28, 0, 0, 0) }
            var y = 0f
            while (y < h) { c.drawRect(0f, y, w, y + 0.6f, scan); y += 2f }
            c.drawRect(RectF(0f, 0f, w, h * 0.42f), Paint().apply { shader = LinearGradient(0f, 0f, 0f, h * 0.42f, Color.argb(34, 255, 255, 255), Color.TRANSPARENT, Shader.TileMode.CLAMP) })

            val mono = doto ?: Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            // State glyph, left of the live clock (which sits on top of this bitmap)
            val glyph = paint { color = LIME }
            when {
                playing -> c.drawPath(Path().apply { moveTo(5f, 9f); lineTo(12f, 13.5f); lineTo(5f, 18f); close() }, glyph)
                title != null -> { c.drawRect(5f, 9f, 7.5f, 18f, glyph); c.drawRect(9.5f, 9f, 12f, 18f, glyph) }
                else -> c.drawRect(5f, 9.5f, 12f, 16.5f, glyph)
            }
            // Badges, top right: device · format
            val badge = paint { typeface = mono; textSize = 7f; color = LIME; letterSpacing = 0.05f }
            val box = paint { style = Paint.Style.STROKE; strokeWidth = 0.8f; color = GREEN }
            var bx = w - 6f
            for (t in listOf(p.getString("device", "PHONE") ?: "PHONE", p.getString("format", "") ?: "").filter { it.isNotEmpty() }) {
                val tw = badge.measureText(t) + 7f
                bx -= tw
                c.drawRoundRect(RectF(bx, 6f, bx + tw, 16f), 2.5f, 2.5f, box)
                c.drawText(t, bx + 3.5f, 13.6f, badge)
                bx -= 4f
            }
            // Spectrum under the badges: dot columns (a still frame — widgets can't animate)
            val cols = 14
            val sx = w * 0.56f
            val cw = (w - 8f - sx) / cols
            val rnd = Random((title ?: "").hashCode())
            val dot = paint {}
            for (i in 0 until cols) {
                val level = if (title == null) 0f else ((if (playing) 0.35f else 0.15f) + rnd.nextFloat() * (if (playing) 0.65f else 0.3f)) * (1f - i * 0.03f)
                for (row in 0 until 7) {
                    dot.color = if (row < (level * 7).roundToInt()) (if (row >= 5) KHAKI else LIME) else Color.argb(26, 140, 255, 110)
                    c.drawRoundRect(RectF(sx + i * cw + 0.6f, 40f - row * 3.6f, sx + (i + 1) * cw - 0.6f, 42.6f - row * 3.6f), 0.8f, 0.8f, dot)
                }
            }
            c.drawText(p.getString("track", null)?.takeIf { it.isNotEmpty() }?.let { "TRK $it" } ?: "TRK ---/---", 6f, 44f, paint { typeface = mono; textSize = 8f; color = GREEN; letterSpacing = 0.06f })
            c.drawLine(6f, 52f, w - 6f, 52f, Paint().apply { color = Color.argb(70, 120, 255, 100); strokeWidth = 0.6f })
            // Title (dot matrix) + artist
            val tp = paint { typeface = doto ?: mono; textSize = 15f; color = LIME; isFakeBoldText = doto != null; setShadowLayer(4f, 0f, 0f, GREEN) }
            c.drawText(fit((title ?: "wreckbox").uppercase(), tp, w - 12f), 6f, 70f, tp)
            val ap = paint { typeface = Typeface.create(urbanist ?: Typeface.SANS_SERIF, Typeface.BOLD); textSize = 10.5f; color = Color.argb(200, 160, 240, 120) }
            c.drawText(fit(p.getString("artist", null) ?: "nothing playing — tap play", ap, w - 12f), 6f, 86f, ap)
            c.restore()
            return b
        }

        /// Winamp's EQ: ten slider tracks with a knob at each band's gain, on the green screen.
        private fun eqScreen(context: Context, w: Float, h: Float, csv: String, on: Boolean): Bitmap {
            fonts(context)
            val gains = csv.split(",").mapNotNull { it.toFloatOrNull() }.let { if (it.size == 10) it else List(10) { 0f } }
            val (b, c) = canvas(w, h)
            val r = RectF(0f, 0f, w, h)
            c.drawRoundRect(r, 10f, 10f, paint { shader = LinearGradient(0f, 0f, 0f, h, Color.parseColor("#FF0A3316"), Color.parseColor("#FF031208"), Shader.TileMode.CLAMP) })
            c.drawRoundRect(r, 10f, 10f, paint { style = Paint.Style.STROKE; strokeWidth = 2f; color = Color.parseColor("#FF050607") })
            val scale = label(6.5f, Paint.Align.LEFT, Color.argb(170, 140, 230, 100), screen = true)
            val top = 12f
            val bottom = h - 16f
            val mid = (top + bottom) / 2
            c.drawText("+12", 5f, top + 3f, scale)
            c.drawText(" 0", 5f, mid + 2.5f, scale)
            c.drawText("-12", 5f, bottom + 2f, scale)
            val left = 22f
            val step = (w - left - 8f) / 10
            c.drawLine(left - 2, mid, w - 6f, mid, Paint().apply { color = Color.argb(70, 120, 255, 100); strokeWidth = 0.6f; pathEffect = DashPathEffect(floatArrayOf(2f, 2f), 0f) })
            val names = listOf("32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K")
            val bands = label(6.5f, Paint.Align.CENTER, Color.argb(170, 140, 230, 100), screen = true)
            for (i in 0 until 10) {
                val x = left + step * (i + 0.5f)
                c.drawRoundRect(RectF(x - 1.5f, top, x + 1.5f, bottom), 1.5f, 1.5f, paint { color = Color.parseColor("#FF020804") })
                val ky = mid - gains[i].coerceIn(-12f, 12f) / 12f * (mid - top)
                c.drawRect(RectF(x - 1.5f, min(ky, mid), x + 1.5f, max(ky, mid)), Paint().apply { color = if (on) GREEN else Color.argb(90, 160, 160, 160) })
                val half = min(6f, step * 0.38f)
                val knob = RectF(x - half, ky - 3f, x + half, ky + 3f)
                c.drawRoundRect(knob, 2f, 2f, paint {
                    shader = LinearGradient(0f, knob.top, 0f, knob.bottom, if (on) Color.parseColor("#FFE8FFB0") else Color.parseColor("#FFBBBBBB"), if (on) Color.parseColor("#FF4FB33A") else Color.parseColor("#FF555555"), Shader.TileMode.CLAMP)
                })
                c.drawText(names[i], x, h - 6f, bands)
            }
            if (!on) c.drawText("EQ OFF", w / 2, mid - 6f, label(10f, Paint.Align.CENTER, screen = true))
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
