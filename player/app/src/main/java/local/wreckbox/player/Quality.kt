package local.wreckbox.player

import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import java.util.concurrent.ConcurrentHashMap

/**
 * What a song actually is: "FLAC · 24/96 · 2,612 kbps", "MP3 · 320 kbps". Phone files from what Android knows about
 * the file (format, bitrate, and on Android 14+ sample rate and bit depth); a YouTube Music stream from the format
 * its player picked (reported by the page, see WebEngine). Spotify's web player doesn't say.
 */
object Quality {
    private val cache = ConcurrentHashMap<String, String>()

    /** Known already (no disk access): for lists. */
    fun cached(t: Track): String? = cache[t.key]

    fun put(t: Track, label: String?) { if (label != null) cache[t.key] = label }

    /** For a phone file: reads it from MediaStore once. Call off the main thread. */
    fun of(c: Context, t: Track): String? {
        if (t.source != Source.LOCAL) return cached(t)
        cache[t.key]?.let { return it }
        val cols = mutableListOf(MediaStore.Audio.Media.MIME_TYPE, MediaStore.Audio.Media.DISPLAY_NAME, MediaStore.Audio.Media.SIZE, MediaStore.Audio.Media.DURATION)
        if (android.os.Build.VERSION.SDK_INT >= 30) cols += MediaStore.Audio.Media.BITRATE
        if (android.os.Build.VERSION.SDK_INT >= 34) { cols += MediaStore.Audio.Media.SAMPLERATE; cols += MediaStore.Audio.Media.BITS_PER_SAMPLE }
        val label = runCatching {
            c.contentResolver.query(Uri.parse(t.id), cols.toTypedArray(), null, null, null)?.use { cur ->
                if (!cur.moveToFirst()) return@use null
                fun col(n: String) = cur.getColumnIndex(n).takeIf { it >= 0 }
                label(
                    cur.getString(0), cur.getString(1), cur.getLong(2), cur.getLong(3),
                    col(MediaStore.Audio.Media.BITRATE)?.let { cur.getLong(it) } ?: 0,
                    col(MediaStore.Audio.Media.SAMPLERATE)?.let { cur.getInt(it) } ?: 0,
                    col(MediaStore.Audio.Media.BITS_PER_SAMPLE)?.let { cur.getInt(it) } ?: 0,
                )
            }
        }.getOrNull()
        put(t, label)
        return label
    }

    /** "FLAC · 24/96 · 2,612 kbps" from a file's MediaStore columns. */
    fun label(mime: String?, name: String?, size: Long, durationMs: Long, bitrate: Long, sampleRate: Int, bits: Int): String? {
        val ext = name?.substringAfterLast('.', "")?.lowercase().orEmpty()
        val format = when {
            ext == "flac" || mime == "audio/flac" -> "FLAC"
            ext == "mp3" || mime == "audio/mpeg" -> "MP3"
            ext == "wav" || mime?.contains("wav") == true -> "WAV"
            ext in setOf("aif", "aiff") -> "AIFF"
            ext == "opus" -> "OPUS"
            ext == "ogg" -> "OGG"
            ext == "alac" -> "ALAC"
            ext in setOf("m4a", "aac", "mp4") -> "M4A"
            ext.isNotEmpty() -> ext.uppercase()
            else -> mime?.substringAfter('/')?.uppercase() ?: return null
        }
        // MediaStore's bitrate when it has one; otherwise the file's average (size over length).
        val kbps = (if (bitrate > 0) bitrate / 1000 else if (durationMs > 0) size * 8 / durationMs else 0).toInt()
        val lossless = format in setOf("FLAC", "WAV", "AIFF", "ALAC")
        val res = if (lossless && sampleRate > 0) "${if (bits > 0) "$bits/" else ""}${fmtRate(sampleRate)}" else null
        return listOfNotNull(format, res, kbps.takeIf { it > 0 }?.let { "%,d kbps".format(it) }).joinToString(" · ")
    }

    private fun fmtRate(hz: Int) = (hz / 1000.0).let { if (it % 1.0 == 0.0) it.toInt().toString() else "%.1f".format(it) }

    /** YouTube's audio formats (itag → what it is). */
    fun youtube(itag: Int?): String? = when (itag) {
        251 -> "OPUS · ~160 kbps"
        250 -> "OPUS · ~70 kbps"
        249 -> "OPUS · ~50 kbps"
        774 -> "OPUS · ~256 kbps"
        141 -> "AAC · 256 kbps"
        140 -> "AAC · 128 kbps"
        139 -> "AAC · 48 kbps"
        null -> null
        else -> "itag $itag"
    }
}
