package local.wreckbox.player

import android.content.Context
import android.media.audiofx.Equalizer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlin.math.ln

/**
 * The EQ: the same 10 bands and presets as the WreckBox apps. Phone files go through Android's equaliser on the
 * player's audio session (its bands, usually 5, each take the curve's value at their centre); YouTube Music through
 * filters inside its page (Web Audio). Spotify's audio is DRM-protected, which Web Audio can't touch, so it plays flat.
 */
object Eq {
    val frequencies = listOf(32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0)
    val labels = listOf("32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K")
    val presets = linkedMapOf(
        "Flat" to listOf(0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
        "Bass boost" to listOf(6f, 5f, 4f, 2f, 0f, 0f, 0f, 0f, 0f, 0f),
        "Club" to listOf(4f, 3f, 2f, 0f, -1f, -1f, 0f, 2f, 3f, 3f),
        "Hip-hop" to listOf(5f, 4f, 1f, 2f, -1f, -1f, 1f, 0f, 2f, 3f),
        "Electronic" to listOf(4f, 3f, 1f, 0f, -2f, 1f, 0f, 1f, 3f, 4f),
        "Vocal" to listOf(-2f, -2f, -1f, 1f, 3f, 4f, 3f, 1f, 0f, -1f),
        "Treble" to listOf(0f, 0f, 0f, 0f, 0f, 1f, 2f, 4f, 5f, 6f),
        "Loudness" to listOf(5f, 3f, 0f, 0f, -1f, 0f, -1f, 0f, 3f, 4f),
    )

    data class State(val on: Boolean = true, val preset: String = "Flat", val gains: List<Float> = presets["Flat"]!!) {
        /** The gains actually applied: flat when off. */
        val effective get() = if (on) gains else List(10) { 0f }
    }

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state
    private var prefs: android.content.SharedPreferences? = null
    private var equalizer: Equalizer? = null
    private var session = 0
    /** Called with the gains whenever they change (the player passes them to the web pages). */
    var onChange: ((List<Float>) -> Unit)? = null

    fun load(c: Context) {
        if (prefs != null) return
        val p = c.getSharedPreferences("settings", Context.MODE_PRIVATE)
        prefs = p
        val gains = p.getString("eqGains", null)?.split(',')?.mapNotNull { it.toFloatOrNull() }?.takeIf { it.size == 10 } ?: presets["Flat"]!!
        _state.value = State(p.getBoolean("eqOn", true), p.getString("eqPreset", "Flat") ?: "Flat", gains)
    }

    fun setOn(on: Boolean) = set(_state.value.copy(on = on))
    fun choose(name: String) = presets[name]?.let { set(State(true, name, it)) }
    fun setBand(i: Int, db: Float, save: Boolean = true) {
        val g = _state.value.gains.toMutableList().also { it[i] = db.coerceIn(-12f, 12f) }
        set(_state.value.copy(on = true, preset = "Custom", gains = g), save)
    }

    private fun set(s: State, save: Boolean = true) {
        _state.value = s
        if (save) prefs?.edit()?.putBoolean("eqOn", s.on)?.putString("eqPreset", s.preset)?.putString("eqGains", s.gains.joinToString(","))?.apply()
        apply()
        onChange?.invoke(s.effective)
        PlayerWidget.render()
    }

    /** Attaches to the local player's audio session (once it has one). */
    fun attach(audioSession: Int) {
        if (audioSession == 0 || audioSession == session) return
        runCatching { equalizer?.release() }
        equalizer = runCatching { Equalizer(0, audioSession) }.getOrNull()
        session = audioSession
        apply()
    }

    private fun apply() {
        val e = equalizer ?: return
        runCatching {
            val s = _state.value
            // Only switched on when it changes the sound: an active effect (even a flat one) takes the phone's audio off its
            // lightest path, and over Bluetooth that can stutter.
            e.enabled = s.on && s.gains.any { it != 0f }
            val (min, max) = e.bandLevelRange.let { it[0] to it[1] }
            for (b in 0 until e.numberOfBands) {
                val hz = e.getCenterFreq(b.toShort()) / 1000.0
                val mb = (curveAt(s.gains, hz) * 100).toInt().coerceIn(min.toInt(), max.toInt())
                e.setBandLevel(b.toShort(), mb.toShort())
            }
        }
    }

    /** The 10-band curve at `hz` (linear between bands on a log-frequency axis). */
    fun curveAt(g: List<Float>, hz: Double): Float {
        val x = ln(hz.coerceIn(frequencies.first(), frequencies.last()))
        for (i in 0 until frequencies.size - 1) {
            val a = ln(frequencies[i])
            val b = ln(frequencies[i + 1])
            if (x <= b) return (g[i] + (g[i + 1] - g[i]) * ((x - a) / (b - a))).toFloat()
        }
        return g.last()
    }
}
