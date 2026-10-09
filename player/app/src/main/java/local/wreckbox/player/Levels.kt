package local.wreckbox.player

import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.TeeAudioProcessor
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.sin

/**
 * The music's real spectrum, for the dot displays: 8 bands (≈60 Hz … 16 kHz), each 0..1.
 *
 *  - Phone files: the PCM ExoPlayer plays is copied into a ring (TeeAudioProcessor, no permission needed); the bands are
 *    taken from the samples at the position actually heard (ExoPlayer's position already includes output and
 *    Bluetooth latency), so the dots move with the sound.
 *  - YouTube Music: an AnalyserNode in its page reports bands (WebEngine).
 *  - Spotify: its audio is DRM-protected and can't be analysed → no bands (displays stay still, nothing is faked).
 *
 * Nothing is computed unless a display wants it ([want]/[unwant]): no work with the screen off or the app closed.
 */
/** Whether the display is on (not dozing / off). Screens stop animating and measuring when it isn't. */
object Screen {
    val on = MutableStateFlow(true)
}

@UnstableApi
object Levels {
    const val BANDS = 8
    private val _bands = MutableStateFlow<FloatArray?>(null)
    /** Latest bands, or null when there's nothing real to show (paused, Spotify, nothing playing). */
    val bands: StateFlow<FloatArray?> = _bands

    @Volatile private var watchers = 0
    val wanted get() = watchers > 0
    var onWantedChanged: ((Boolean) -> Unit)? = null

    fun want() { watchers++; if (watchers == 1) onWantedChanged?.invoke(true) }
    fun unwant() { watchers = (watchers - 1).coerceAtLeast(0); if (watchers == 0) { onWantedChanged?.invoke(false); _bands.value = null } }

    fun clear() { _bands.value = null }

    /** From the YouTube page (already 0..1). */
    fun fromWeb(b: FloatArray) { if (wanted) _bands.value = b }

    // MARK: phone files — PCM ring, filled on the playback thread

    private const val RING = 1 shl 16
    private val ring = FloatArray(RING)
    @Volatile private var written = 0L       // mono samples written since the last flush
    @Volatile private var rate = 44100
    @Volatile private var flushes = 0

    val sink = object : TeeAudioProcessor.AudioBufferSink {
        private var channels = 2
        private var encoding = C.ENCODING_PCM_16BIT
        override fun flush(sampleRateHz: Int, channelCount: Int, encoding: Int) {
            rate = sampleRateHz; channels = channelCount; this.encoding = encoding
            written = 0; flushes++
        }

        override fun handleBuffer(buffer: ByteBuffer) {
            if (!wanted) { written += buffer.remaining() / frameBytes(); return }
            val b = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
            val fb = frameBytes()
            var w = written
            while (b.remaining() >= fb) {
                var sum = 0f
                for (ch in 0 until channels) sum += if (encoding == C.ENCODING_PCM_FLOAT) b.float else b.short / 32768f
                ring[(w and (RING - 1).toLong()).toInt()] = sum / channels
                w++
            }
            written = w
        }

        private fun frameBytes() = channels * if (encoding == C.ENCODING_PCM_FLOAT) 4 else 2
    }

    private var refFlush = -1
    private var refPosMs = 0L

    /**
     * Bands for a phone file at the playback position heard now ([positionMs] = ExoPlayer's). Called ~15 times a second
     * while wanted; cheap (one 1024-point FFT).
     */
    fun tickLocal(positionMs: Long, playing: Boolean) {
        if (!wanted) return
        if (!playing) { _bands.value = null; return }
        if (flushes != refFlush) { refFlush = flushes; refPosMs = positionMs }
        val heard = ((positionMs - refPosMs) * rate / 1000).coerceAtLeast(0)
        val end = minOf(heard, written)
        if (end < N) { _bands.value = null; return }
        for (i in 0 until N) {
            re[i] = ring[((end - N + i) and (RING - 1).toLong()).toInt()] * window[i]
            im[i] = 0f
        }
        fft()
        val out = FloatArray(BANDS)
        val binHz = rate.toFloat() / N
        for (band in 0 until BANDS) {
            val lo = (edges[band] / binHz).toInt().coerceAtLeast(1)
            val hi = (edges[band + 1] / binHz).toInt().coerceIn(lo + 1, N / 2)
            var p = 0f
            for (k in lo until hi) p = maxOf(p, re[k] * re[k] + im[k] * im[k])
            // dB of the band's peak, mapped like an analyser display (−70 dB … −10 dB → 0 … 1)
            val db = 10 * log10(p / (N * N / 4f) + 1e-12f)
            out[band] = ((db + 70f) / 60f).coerceIn(0f, 1f)
        }
        _bands.value = out
    }

    // MARK: FFT

    private const val N = 1024
    private val re = FloatArray(N)
    private val im = FloatArray(N)
    private val window = FloatArray(N) { (0.5 - 0.5 * cos(2 * Math.PI * it / (N - 1))).toFloat() }
    /** Band edges in Hz, log-spaced 60 Hz … 16 kHz. */
    private val edges = FloatArray(BANDS + 1) { (60.0 * Math.exp(ln(16000.0 / 60.0) * it / BANDS)).toFloat() }

    private fun fft() {
        var j = 0
        for (i in 1 until N) {
            var bit = N shr 1
            while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }
            j = j xor bit
            if (i < j) { val t = re[i]; re[i] = re[j]; re[j] = t }
        }
        var len = 2
        while (len <= N) {
            val ang = -2 * Math.PI / len
            val wr = cos(ang).toFloat()
            val wi = sin(ang).toFloat()
            var i = 0
            while (i < N) {
                var cr = 1f
                var ci = 0f
                for (k in 0 until len / 2) {
                    val a = i + k
                    val b = a + len / 2
                    val tr = re[b] * cr - im[b] * ci
                    val ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    val ncr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr
                    cr = ncr
                }
                i += len
            }
            len = len shl 1
        }
    }
}
