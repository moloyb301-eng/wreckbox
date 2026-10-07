package local.wreckbox.wreckbox

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

// Home-screen player: chrome body with a jog disc, a dot-matrix LCD (cover, title, a running clock) and two
// drawers under it — controls, and the EQ. The app pushes what's playing (update(), from Dart through
// MainActivity); buttons go back to the app's Dart side on the audio service's engine ("wreckbox/widget").
class PlayerWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = render(context)

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val action = intent.getStringExtra(EXTRA) ?: return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        when (action) {
            // Drawers open / close inside the widget; only one at a time.
            "drawer:controls", "drawer:eq" -> {
                val want = action.removePrefix("drawer:")
                prefs.edit().putString("drawer", if (prefs.getString("drawer", "") == want) "" else want).apply()
                render(context)
            }
            "open" -> context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            else -> toApp(context, action)
        }
    }

    companion object {
        const val PREFS = "wreckbox_widget"
        private const val EXTRA = "wb_action"
        private const val ENGINE = "audio_service_engine"
        val presets = listOf("Flat", "Bass boost", "Club", "Hip-hop", "Electronic", "Vocal", "Treble", "Loudness")

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
            val ids = manager.getAppWidgetIds(ComponentName(context, PlayerWidget::class.java))
            if (ids.isEmpty()) return
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val v = RemoteViews(context.packageName, R.layout.wb_widget)
            val playing = p.getBoolean("playing", false)
            val title = p.getString("title", null)

            // LCD
            v.setTextViewText(R.id.wb_title, (title ?: "WRECKBOX").uppercase())
            v.setTextViewText(R.id.wb_artist, p.getString("artist", null) ?: "Nothing playing")
            val pos = p.getLong("positionMs", 0)
            val since = if (playing) System.currentTimeMillis() - p.getLong("wallMs", System.currentTimeMillis()) else 0
            v.setChronometer(R.id.wb_time, SystemClock.elapsedRealtime() - pos - since, null, playing)
            v.setTextViewText(R.id.wb_status, "${if (playing) "PLAY" else if (title == null) "STOP" else "PAUSE"}\n${p.getString("device", "PHONE")}")
            val art = p.getString("art", null)?.let { path -> runCatching { decodeSmall(path) }.getOrNull() }
            if (art != null) v.setImageViewBitmap(R.id.wb_art, art) else v.setImageViewResource(R.id.wb_art, R.mipmap.ic_launcher)
            v.setImageViewResource(R.id.wb_play, if (playing) R.drawable.wb_ic_pause else R.drawable.wb_ic_play)
            v.setImageViewBitmap(R.id.wb_ring, ring(p.getFloat("volume", 1f)))
            val dur = p.getLong("durationMs", 0)
            v.setProgressBar(R.id.wb_progress, 1000, if (dur > 0) ((pos + since) * 1000 / dur).toInt() else 0, false)

            // Drawers
            val drawer = p.getString("drawer", "") ?: ""
            v.setViewVisibility(R.id.wb_drawer_controls, if (drawer == "controls") View.VISIBLE else View.GONE)
            v.setViewVisibility(R.id.wb_drawer_eq, if (drawer == "eq") View.VISIBLE else View.GONE)
            v.setImageViewResource(R.id.wb_tab_controls, if (drawer == "controls") R.drawable.wb_ic_list_lit else R.drawable.wb_ic_list)
            v.setImageViewResource(R.id.wb_tab_eq, if (drawer == "eq") R.drawable.wb_ic_eq_lit else R.drawable.wb_ic_eq)
            val eqOn = p.getBoolean("eqOn", true)
            v.setTextViewText(R.id.wb_eq_on, if (eqOn) "EQ ON" else "EQ OFF")
            v.setImageViewBitmap(R.id.wb_eq_curve, curve(p.getString("gains", "") ?: "", eqOn))
            val preset = p.getString("eqPreset", "Flat")
            val presetIds = listOf(R.id.wb_p0, R.id.wb_p1, R.id.wb_p2, R.id.wb_p3, R.id.wb_p4, R.id.wb_p5, R.id.wb_p6, R.id.wb_p7)
            presetIds.forEachIndexed { i, id ->
                v.setInt(id, "setBackgroundResource", if (presets[i] == preset) R.drawable.wb_pill_lit else R.drawable.wb_pill)
                v.setTextColor(id, if (presets[i] == preset) Color.parseColor("#FFBB96DA") else Color.parseColor("#FF2B2D33"))
            }
            v.setTextViewText(R.id.wb_handoff, if (p.getString("device", "PHONE") == "PHONE") "PLAY ON MAC" else "PLAY HERE")

            // Buttons
            val clicks = mapOf(
                R.id.wb_play to "toggle", R.id.wb_prev to "previous", R.id.wb_next to "next", R.id.wb_stop to "stop",
                R.id.wb_tab_controls to "drawer:controls", R.id.wb_tab_eq to "drawer:eq",
                R.id.wb_back10 to "back10", R.id.wb_fwd10 to "fwd10", R.id.wb_voldown to "voldown", R.id.wb_volup to "volup",
                R.id.wb_handoff to "handoff", R.id.wb_open to "open", R.id.wb_lcd to "open", R.id.wb_eq_on to "eqtoggle",
            ) + presetIds.mapIndexed { i, id -> id to "preset:${presets[i]}" }
            clicks.entries.forEachIndexed { n, (id, action) -> v.setOnClickPendingIntent(id, intent(context, action, n)) }

            manager.updateAppWidget(ids, v)
        }

        private fun decodeSmall(path: String): Bitmap? {
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, o)
            var s = 1
            while (o.outWidth / (s * 2) >= 160) s *= 2
            return BitmapFactory.decodeFile(path, BitmapFactory.Options().apply { inSampleSize = s })
        }

        /// Twelve volume dots on a 270° arc around the play button.
        private fun ring(volume: Float): Bitmap {
            val size = 200
            val b = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val r = size * 0.36f
            for (i in 0 until 12) {
                val a = i / 12.0 * 2 * Math.PI * 0.75 + Math.PI * 0.75
                val on = (i + 1) / 12f <= volume + 0.001f
                paint.color = if (on) dot(i / 11f) else Color.argb(90, 0, 0, 0)
                val x = size / 2f + (cos(a) * r).toFloat()
                val y = size / 2f + (sin(a) * r).toFloat()
                c.drawRoundRect(RectF(x - 5, y - 5, x + 5, y + 5), 2.5f, 2.5f, paint)
            }
            return b
        }

        /// The EQ as dot columns (10 bands, -12…+12 dB).
        private fun curve(csv: String, on: Boolean): Bitmap {
            val gains = csv.split(",").mapNotNull { it.toFloatOrNull() }.let { if (it.size == 10) it else List(10) { 0f } }
            val w = 400
            val h = 88
            val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val c = Canvas(b)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            val rows = 11
            val mid = rows / 2
            val cw = w / 10f
            val ch = h / rows.toFloat()
            for (i in 0 until 10) {
                val level = Math.round(gains[i] / 12f * mid)
                for (r in 0 until rows) {
                    val k = mid - r
                    val lit = (level > 0 && k in 1..level) || (level < 0 && k < 0 && k >= level)
                    paint.color = when {
                        k == 0 -> Color.argb(110, 255, 255, 255)
                        lit && on -> dot(r / (rows - 1f))
                        lit -> Color.argb(120, 200, 200, 200)
                        else -> Color.argb(18, 255, 255, 255)
                    }
                    val x = i * cw + cw * 0.3f
                    val y = r * ch + ch * 0.15f
                    c.drawRoundRect(RectF(x, y, x + cw * 0.4f, y + ch * 0.7f), 2f, 2f, paint)
                }
            }
            return b
        }

        /// lilac → light blue → peach.
        private fun dot(h: Float): Int {
            val a = intArrayOf(0xBB, 0x96, 0xDA)
            val m = intArrayOf(0xA9, 0xC8, 0xF0)
            val z = intArrayOf(0xEF, 0xAF, 0x86)
            val (p, q, t) = if (h < 0.5f) Triple(a, m, h * 2) else Triple(m, z, (h - 0.5f) * 2)
            return Color.rgb(
                (p[0] + (q[0] - p[0]) * t).toInt(), (p[1] + (q[1] - p[1]) * t).toInt(), (p[2] + (q[2] - p[2]) * t).toInt(),
            )
        }
    }
}
