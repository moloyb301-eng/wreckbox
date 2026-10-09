package local.wreckbox.player

import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.LruCache
import android.util.Size
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/** Covers: from the web (YouTube / Spotify) or from a phone file's album art. Small memory cache, no library needed. */
object Images {
    private val cache = object : LruCache<String, ImageBitmap>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ImageBitmap) = value.width * value.height * 4
    }

    /**
     * A cover decoded at about [px] pixels (rounded up to 128 / 256 / 512 / 768): a 46 dp list row doesn't need a
     * 544-pixel picture in memory. Each size is cached on its own.
     */
    suspend fun load(c: Context, url: String, px: Int = 512): ImageBitmap? {
        val size = listOf(128, 256, 512, 768).firstOrNull { it >= px } ?: 768
        val key = "$size|$url"
        cache.get(key)?.let { return it }
        val img = withContext(Dispatchers.IO) {
            runCatching {
                if (url.startsWith("content://")) {
                    c.contentResolver.loadThumbnail(Uri.parse(url.removeSuffix("/albumart")), Size(size, size), null).asImageBitmap()
                } else {
                    val conn = URL(sized(url, size)).openConnection() as HttpURLConnection
                    conn.connectTimeout = 8000
                    conn.readTimeout = 10000
                    val bytes = conn.inputStream.use { it.readBytes() }
                    val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, o)
                    var sample = 1
                    while (o.outWidth / (sample * 2) >= size) sample *= 2
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
                }
            }.getOrNull()
        }
        img?.let { cache.put(key, it) }
        return img
    }

    /** Asks the service for a smaller picture where its URLs allow it (YouTube's =wN-hN, Spotify's sizes). */
    private fun sized(url: String, size: Int): String = when {
        Regex("=w\\d+-h\\d+").containsMatchIn(url) -> url.replace(Regex("=w\\d+-h\\d+"), "=w$size-h$size")
        size <= 128 && url.contains("ab67616d00001e02") -> url.replace("ab67616d00001e02", "ab67616d00004851") // Spotify 64 px
        size >= 512 && url.contains("ab67616d00001e02") -> url.replace("ab67616d00001e02", "ab67616d0000b273") // Spotify 640 px
        else -> url
    }
}

@Composable
fun Cover(url: String?, modifier: Modifier, shape: Shape) {
    val c = LocalContext.current
    var img by remember(url) { mutableStateOf<ImageBitmap?>(null) }
    var px by remember { mutableIntStateOf(0) }
    LaunchedEffect(url, px) { if (px > 0) img = url?.let { Images.load(c, it, px) } }
    Box(modifier.onSizeChanged { px = maxOf(it.width, it.height) }.clip(shape).background(Color(0xFF26222E))) {
        img?.let { Image(it, null, Modifier.matchParentSize(), contentScale = ContentScale.Crop) }
    }
}
