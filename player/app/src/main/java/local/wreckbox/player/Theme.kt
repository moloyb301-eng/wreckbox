package local.wreckbox.player

import android.os.Build
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.addOutline
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlin.math.atan2
import kotlin.math.sqrt

/**
 * The WreckBox design, as on the Mac: frosted glass over a dark base and the playing song's blurred cover, Urbanist
 * for text, Doto (dot-matrix) for labels and readouts, and the light-blue → peach → lilac gradient for what matters.
 * The Y2K side is a small, fixed set of pieces used the same way everywhere — the LCD readout, the candy play button,
 * the iridescent rim, the dot spectrum and the pixel record — never decoration for its own sake.
 */
object W {
    val bg = Color(0xFF08080A)
    val bgRaised = Color(0xFF111115)
    val text = Color.White.copy(alpha = 0.94f)
    val text2 = Color.White.copy(alpha = 0.66f)
    val text3 = Color.White.copy(alpha = 0.46f)
    val hairline = Color.White.copy(alpha = 0.08f)
    val glassFill = Color.White.copy(alpha = 0.045f)
    val peach = Color(0xFFEFAF86)
    val lilac = Color(0xFFBB96DA)
    val blue = Color(0xFFA9C8F0)
    val lcd = Color(0xFF0C0A12)
    val smartColors = listOf(blue, peach, lilac)
    val smart = Brush.linearGradient(smartColors)
    val iridescent = Brush.sweepGradient(listOf(blue, peach, lilac, blue))

    object Radius { val card = 24.dp; val tile = 20.dp; val row = 12.dp; val art = 8.dp }

    private fun variable(res: Int, vararg weights: Int) = FontFamily(weights.map { w ->
        if (Build.VERSION.SDK_INT >= 26) Font(res, FontWeight(w), variationSettings = FontVariation.Settings(FontVariation.weight(w)))
        else Font(res, FontWeight(w))
    })

    val urbanist = variable(R.font.urbanist, 400, 500, 600, 700, 800)
    val doto = variable(R.font.doto, 700, 900)

    fun ui(size: TextUnit, weight: FontWeight = FontWeight.Normal) = TextStyle(fontFamily = urbanist, fontSize = size, fontWeight = weight, color = text)
    fun dot(size: TextUnit, weight: FontWeight = FontWeight.Bold) = TextStyle(fontFamily = doto, fontSize = size, fontWeight = weight, color = text)

    val colors = darkColorScheme(
        primary = lilac, onPrimary = Color.Black, secondary = peach, tertiary = blue,
        background = bg, surface = Color(0xFF141219), surfaceContainer = Color(0xFF16141C), surfaceContainerHigh = Color(0xFF1B1922),
        surfaceContainerHighest = Color(0xFF211E29), onSurface = text, onSurfaceVariant = text2, outline = Color.White.copy(alpha = 0.16f),
        outlineVariant = hairline,
    )

    val typography = Typography().let { t ->
        fun TextStyle.u() = copy(fontFamily = urbanist)
        Typography(
            displayLarge = t.displayLarge.u(), displayMedium = t.displayMedium.u(), displaySmall = t.displaySmall.u(),
            headlineLarge = t.headlineLarge.u(), headlineMedium = t.headlineMedium.u(), headlineSmall = t.headlineSmall.u(),
            titleLarge = t.titleLarge.u().copy(fontWeight = FontWeight.Bold), titleMedium = t.titleMedium.u(), titleSmall = t.titleSmall.u(),
            bodyLarge = t.bodyLarge.u(), bodyMedium = t.bodyMedium.u(), bodySmall = t.bodySmall.u(),
            labelLarge = t.labelLarge.u().copy(fontWeight = FontWeight.SemiBold), labelMedium = t.labelMedium.u(), labelSmall = t.labelSmall.u(),
        )
    }
}

@Composable
fun WreckBoxTheme(content: @Composable () -> Unit) =
    MaterialTheme(colorScheme = W.colors, typography = W.typography, shapes = Shapes(
        extraSmall = RoundedCornerShape(8.dp), small = RoundedCornerShape(12.dp), medium = RoundedCornerShape(16.dp),
        large = RoundedCornerShape(24.dp), extraLarge = RoundedCornerShape(28.dp),
    )) { CompositionLocalProvider(LocalContentColor provides W.text, content = content) }

// MARK: - Surfaces

/** Frosted glass: a faint white fill and a top-lit hairline (the blur itself comes from what's behind — see Haze). */
fun Modifier.glass(shape: Shape = RoundedCornerShape(W.Radius.card), tint: Color? = null): Modifier = this
    .clip(shape)
    .background(W.glassFill, shape)
    .then(if (tint != null) Modifier.background(tint.copy(alpha = 0.10f), shape) else Modifier)
    .bezel(shape, 0.8f)

/** For smart things (sync, recognised quality): the gradient, faint. */
fun Modifier.smartGlass(shape: Shape = RoundedCornerShape(W.Radius.card)): Modifier = this
    .clip(shape)
    .background(Brush.linearGradient(W.smartColors.map { it.copy(alpha = 0.16f) }), shape)
    .bezel(shape)

/** The iridescent rim: a thin blue → peach → lilac ring, like the widget's shell. */
/**
 * The phone-frame bezel inside [shape]: a light chamfer (bright on top where the light falls, dim down the sides, a
 * reflection along the bottom) and a dark line just inside it where the frame meets the face.
 */
fun androidx.compose.ui.graphics.drawscope.DrawScope.drawBezel(shape: Shape, strength: Float = 1f) {
    val w = size.width
    val h = size.height
    fun outline(sz: Size, at: Offset) = androidx.compose.ui.graphics.Path().apply {
        addOutline(shape.createOutline(sz, layoutDirection, this@drawBezel))
        translate(at)
    }
    val inset = 1.4.dp.toPx()
    drawPath(outline(Size(w - 2 * inset, h - 2 * inset), Offset(inset, inset)),
        Brush.verticalGradient(0f to Color.White.copy(alpha = 0.42f * strength), 0.3f to Color.White.copy(alpha = 0.16f * strength),
            0.7f to Color.White.copy(alpha = 0.07f * strength), 1f to Color.White.copy(alpha = 0.22f * strength)),
        style = Stroke(1.4.dp.toPx()))
    val inner = inset + 2.dp.toPx()
    drawPath(outline(Size(w - 2 * inner, h - 2 * inner), Offset(inner, inner)),
        Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.55f * strength), Color.Black.copy(alpha = 0.30f * strength), Color.Black.copy(alpha = 0.50f * strength))),
        style = Stroke(1.dp.toPx()))
}

/** For buttons and cards: just the bezel and a soft glare across the top (no smoke or vignette, so labels stay crisp). */
fun Modifier.bezel(shape: Shape, strength: Float = 1f) = clip(shape).drawWithContent {
    drawContent()
    val w = size.width
    val h = size.height
    val gx = minOf(w, h) * 0.1f
    val glare = androidx.compose.ui.graphics.Path().apply {
        addOutline(shape.createOutline(Size(w - 2 * gx, h * 0.46f), layoutDirection, this@drawWithContent))
        translate(Offset(gx, h * 0.05f))
    }
    drawPath(glare, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.12f * strength), Color.Transparent), startY = h * 0.05f, endY = h * 0.5f))
    drawBezel(shape, strength)
}

/**
 * A VCR display window's curved glass laid over whatever it covers (a cover, the bar): faintly smoked, darker toward
 * the edges as the glass bends away, an arched glare across the top and a thin reflection along the bottom, faint
 * scanlines. No outline.
 */
/**
 * Textures drawn once and tiled: [grain] = fine film grain with brushed-metal streaks and granite sparkle (256 px,
 * seamless top to bottom), for depth under the glass.
 */
object Textures {
    val grain: androidx.compose.ui.graphics.ImageBitmap by lazy {
        val n = 256
        val rnd = java.util.Random(11)
        val px = IntArray(n * n)
        // Brushed streaks: each row a little lighter or darker, varying smoothly
        val rows = FloatArray(n)
        var drift = 0f
        for (y in 0 until n) { drift = drift * 0.82f + (rnd.nextFloat() - 0.5f) * 0.18f; rows[y] = drift }
        for (y in 0 until n) for (x in 0 until n) {
            val noise = (rnd.nextFloat() + rnd.nextFloat() + rnd.nextFloat()) / 3f - 0.5f
            val l = noise * 0.9f + rows[y]
            val a = (kotlin.math.abs(l) * 2f * 46f).toInt().coerceIn(0, 60)
            px[y * n + x] = if (rnd.nextFloat() < 0.004f) android.graphics.Color.argb(90, 255, 255, 255) // sparkle
                else if (l > 0) android.graphics.Color.argb(a, 255, 255, 255) else android.graphics.Color.argb(a, 0, 0, 0)
        }
        android.graphics.Bitmap.createBitmap(px, n, n, android.graphics.Bitmap.Config.ARGB_8888).asImageBitmap()
    }

    val grainBrush by lazy { androidx.compose.ui.graphics.ShaderBrush(androidx.compose.ui.graphics.ImageShader(grain, androidx.compose.ui.graphics.TileMode.Repeated, androidx.compose.ui.graphics.TileMode.Repeated)) }
}

/** [bezel]: the lit edge runs all the way round, like a phone's chamfered frame (the bar); otherwise only along the top. */
fun Modifier.vcrGlass(shape: Shape, grain: Float = 0.35f, bezel: Boolean = false, glareMax: Dp = Dp.Infinity) = clip(shape).drawWithContent {
    drawContent()
    val w = size.width
    val h = size.height
    // Fine grain under the glass (a cover gets less than the bar)
    if (grain > 0f) drawRect(Textures.grainBrush, alpha = grain)
    drawRect(Color(0xFF0B0A10).copy(alpha = 0.10f))
    // The bend: edges darker, top and bottom more than the sides
    drawRect(Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.34f), 0.22f to Color.Transparent, 0.78f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.42f)))
    drawRect(Brush.horizontalGradient(0f to Color.Black.copy(alpha = 0.26f), 0.12f to Color.Transparent, 0.88f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.26f)))
    // The glare and the hard highlight follow the element's own outline (a pill gets a pill-shaped glare, a cover a
    // rounded one): glare = the shape again, smaller, across the top half; highlight = the shape's top edge, inset.
    fun outline(sz: Size, at: Offset) = androidx.compose.ui.graphics.Path().apply {
        addOutline(shape.createOutline(sz, layoutDirection, this@drawWithContent))
        translate(at)
    }
    val gx = minOf(w, h) * 0.12f
    // (a tall panel keeps a shallow glare along its top, not a pale block over its contents)
    val gh = minOf(h * 0.48f, if (glareMax == Dp.Infinity) Float.MAX_VALUE else glareMax.toPx())
    drawPath(outline(Size(w - 2 * gx, gh), Offset(gx, h * 0.05f)),
        Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.17f), Color.White.copy(alpha = 0.01f)), startY = h * 0.05f, endY = h * 0.05f + gh * 1.1f))
    val inset = 1.6.dp.toPx()
    if (bezel) drawBezel(shape)
    else clipRect(0f, 0f, w, h * 0.34f) {
        drawPath(outline(Size(w - 2 * inset, h - 2 * inset), Offset(inset, inset)),
            Brush.horizontalGradient(listOf(Color.Transparent, Color.White.copy(alpha = 0.30f), Color.White.copy(alpha = 0.12f), Color.Transparent)),
            style = Stroke(1.2.dp.toPx()))
    }
    // Bottom reflection
    drawRect(Brush.horizontalGradient(listOf(Color.Transparent, Color.White.copy(alpha = 0.10f), Color.Transparent)), Offset(w * 0.15f, h - 3.dp.toPx()), Size(w * 0.7f, 1.dp.toPx()))
    var y = 0f
    val line = Color.Black.copy(alpha = 0.06f)
    while (y < h) { drawRect(line, Offset(0f, y), Size(w, 1f)); y += 3f }
}

fun Modifier.iridescentRim(shape: Shape, width: Dp = 1.5.dp) = border(width, W.iridescent, shape)

/**
 * The playing song's cover, huge and blurred, behind the whole app (as on the Mac); soft gradients with nothing playing.
 * The blur is made once per song — the cover shrunk to 24 px, box-blurred, then drawn stretched (smooth filtering does
 * the rest) — instead of a live blur effect, which the GPU would redo on every frame the screen changes.
 */
@Composable
fun AmbientBackground(art: String?) {
    val c = LocalContext.current
    var img by remember { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(art) {
        img = art?.let { Images.load(c, it, 128) }?.let { full ->
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) { tinyBlur(full.asAndroidBitmap()).asImageBitmap() }
        }
    }
    Box(Modifier.fillMaxSize().background(W.bg)) {
        val i = img
        if (i != null) {
            androidx.compose.foundation.Image(i, null, Modifier.fillMaxSize().graphicsLayer { alpha = 0.42f }, contentScale = ContentScale.Crop,
                filterQuality = androidx.compose.ui.graphics.FilterQuality.High)
        } else {
            Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(W.lilac.copy(alpha = 0.16f), Color.Transparent), center = Offset(1200f, 0f), radius = 1500f)))
            Box(Modifier.fillMaxSize().background(Brush.radialGradient(listOf(W.peach.copy(alpha = 0.08f), Color.Transparent), center = Offset(0f, 2400f), radius = 1300f)))
        }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(W.bg.copy(alpha = 0.2f), W.bg.copy(alpha = 0.85f)))))
    }
}

/** A cover shrunk to 24 × 24 and box-blurred three times: stretched over the screen it reads as a deep blur. */
private fun tinyBlur(src: android.graphics.Bitmap): android.graphics.Bitmap {
    val n = 24
    val small = android.graphics.Bitmap.createScaledBitmap(src.copy(android.graphics.Bitmap.Config.ARGB_8888, false), n, n, true)
    val px = IntArray(n * n)
    small.getPixels(px, 0, n, 0, 0, n, n)
    repeat(3) {
        val out = IntArray(n * n)
        for (y in 0 until n) for (x in 0 until n) {
            var r = 0; var g = 0; var b = 0; var k = 0
            for (dy in -2..2) for (dx in -2..2) {
                val xx = (x + dx).coerceIn(0, n - 1)
                val yy = (y + dy).coerceIn(0, n - 1)
                val p = px[yy * n + xx]
                r += (p shr 16) and 255; g += (p shr 8) and 255; b += p and 255; k++
            }
            out[y * n + x] = (0xFF shl 24) or ((r / k) shl 16) or ((g / k) shl 8) or (b / k)
        }
        out.copyInto(px)
    }
    return android.graphics.Bitmap.createBitmap(px, n, n, android.graphics.Bitmap.Config.ARGB_8888)
}

// MARK: - Type pieces

/** Small uppercase dot-matrix label (sections, readouts). */
@Composable
fun DotLabel(text: String, modifier: Modifier = Modifier, color: Color = W.text2, size: TextUnit = 11.sp) =
    Text(text.uppercase(), modifier, color = color, style = W.dot(size), letterSpacing = 1.6.sp, maxLines = 1)

/** A section header: dot label, optional action on the right. */
@Composable
fun Section(title: String, action: String? = null, onAction: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(20.dp, 22.dp, 12.dp, 8.dp), verticalAlignment = Alignment.CenterVertically) {
        DotLabel(title, Modifier.weight(1f), size = 12.sp)
        if (action != null && onAction != null) Text(action, Modifier.clip(CircleShape).clickable(onClick = onAction).padding(10.dp, 4.dp), color = W.text2, style = W.ui(13.sp, FontWeight.SemiBold))
    }
}

/** The wordmark: the pixel record and WRECKBOX in Doto with the gradient. */
@Composable
fun Wordmark(size: Dp = 26.dp) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        PixelRecord(Modifier.size(size))
        Spacer(Modifier.width(10.dp))
        Text("WRECKBOX", style = W.dot((size.value * 0.72f).sp, FontWeight.Black).copy(brush = W.smart), letterSpacing = 2.sp)
    }
}

/** The app icon's pixel-art record on its beige tile (the Mac app's PixelRecord). */
@Composable
fun PixelRecord(modifier: Modifier) = Canvas(modifier) {
    val s = size.minDimension
    drawRoundRect(Brush.verticalGradient(listOf(Color(0xFFF1ECE4), Color(0xFFDCD5CA))), cornerRadius = CornerRadius(s * 0.225f))
    val inner = s * 0.78f
    val o = (s - inner) / 2
    val px = inner / 32
    for (gy in 0 until 32) for (gx in 0 until 32) {
        val dx = gx - 15.5
        val dy = gy - 15.5
        val r = sqrt(dx * dx + dy * dy)
        val angle = atan2(dy, dx) * 180 / Math.PI
        val color = when {
            r < 1.6 -> continue
            r < 3.6 -> W.lilac
            r < 5.6 -> W.peach
            r < 6.3 -> Color(0xFF050506)
            r < 14.6 -> {
                val glint = (angle > -150 && angle < -118) || (angle > 30 && angle < 62)
                val band = ((r - 6.3) / 1.7).toInt() % 2 == 0
                Color(if (glint) (if (band) 0xFF4A4A56 else 0xFF5C5C6A) else (if (band) 0xFF15151A else 0xFF202027))
            }
            r < 15.6 -> Color(0xFF34343E)
            else -> continue
        }
        drawRect(color, Offset(o + gx * px, o + gy * px), Size(px + 0.3f, px + 0.3f))
    }
}

// MARK: - Controls

/** Capsule chip: white with a lilac dot when selected, glass otherwise. */
@Composable
fun Chip(label: String, selected: Boolean = false, count: Int? = null, onClick: () -> Unit) {
    val shape = CircleShape
    Row(
        Modifier.clip(shape)
            .then(if (selected) Modifier.background(Color.White, shape).bezel(shape, 0.7f) else Modifier.glass(shape))
            .clickable(onClick = onClick).padding(horizontal = 13.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (selected) { Box(Modifier.size(6.dp).background(W.lilac, CircleShape)); Spacer(Modifier.width(6.dp)) }
        Text(label, color = if (selected) Color.Black else W.text2, style = W.ui(13.sp, FontWeight.SemiBold), maxLines = 1)
        if (count != null) { Spacer(Modifier.width(6.dp)); Text("$count", color = if (selected) Color.Black.copy(alpha = 0.6f) else W.text3, style = W.dot(11.sp)) }
    }
}

enum class PillStyle { GLASS, PRIMARY, SMART }

/** Pill button: glass, white primary, or the gradient for smart actions. */
@Composable
fun Pill(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector? = null, style: PillStyle = PillStyle.GLASS, enabled: Boolean = true, onClick: () -> Unit) {
    val shape = CircleShape
    Row(
        Modifier.graphicsLayer { alpha = if (enabled) 1f else 0.4f }.clip(shape)
            .then(when (style) {
                PillStyle.PRIMARY -> Modifier.background(Color.White, shape).bezel(shape, 0.7f)
                PillStyle.SMART -> Modifier.smartGlass(shape)
                PillStyle.GLASS -> Modifier.glass(shape)
            })
            .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 16.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val fg = if (style == PillStyle.PRIMARY) Color.Black else W.text
        if (icon != null) { Icon(icon, null, tint = fg, modifier = Modifier.size(16.dp)); Spacer(Modifier.width(7.dp)) }
        Text(label, color = fg, style = W.ui(14.sp, FontWeight.SemiBold))
    }
}

/** Round glass icon button. */
@Composable
fun RoundButton(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, size: Dp = 38.dp, tint: Color = W.text, onClick: () -> Unit) {
    Box(Modifier.size(size).glass(CircleShape).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(icon, description, tint = tint, modifier = Modifier.size(size * 0.48f))
    }
}

/** The candy play button: the gradient with a gloss on its top half and a dark well around it (the widget's). */
@Composable
fun CandyButton(size: Dp, onClick: () -> Unit, content: @Composable BoxScope.() -> Unit) {
    Box(
        Modifier.size(size).background(Color(0xFF07060A), CircleShape).padding(2.dp).clip(CircleShape)
            .background(Brush.linearGradient(W.smartColors), CircleShape)
            .bezel(CircleShape, 0.9f)
            .drawWithContent {
                drawContent()
                drawOval(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.6f), Color.White.copy(alpha = 0.02f)), endY = size.toPx() * 0.5f),
                    topLeft = Offset(this.size.width * 0.16f, this.size.height * 0.05f), size = Size(this.size.width * 0.68f, this.size.height * 0.42f))
            }
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center, content = content,
    )
}

// MARK: - Y2K readouts

/**
 * The LCD: deep violet glass with faint ghost dots, scanlines and a soft glare — where the player's numbers live
 * (clock, track counter, format), in Doto, glowing peach / lilac. Same as the widget's display.
 */
@Composable
fun Lcd(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier.clip(shape)
            .background(Brush.radialGradient(listOf(Color(0xFF2A1F3D), Color(0xFF07060B)), center = Offset(900f, 400f), radius = 1100f), shape)
            .drawWithContent {
                // Ghost dots and scanlines under the readouts, glare over everything
                val step = 3.4.dp.toPx()
                var y = step / 2
                while (y < size.height) {
                    var x = step / 2
                    while (x < size.width) { drawCircle(Color.White.copy(alpha = 0.035f), 0.5.dp.toPx(), Offset(x, y)); x += step }
                    y += step
                }
                y = 0f
                while (y < size.height) { drawRect(Color.Black.copy(alpha = 0.10f), Offset(0f, y), Size(size.width, 0.7.dp.toPx())); y += 2.dp.toPx() }
                drawContent()
                val p = androidx.compose.ui.graphics.Path().apply {
                    moveTo(size.width * 0.52f, 0f); lineTo(size.width * 0.76f, 0f); lineTo(size.width * 0.46f, size.height); lineTo(size.width * 0.22f, size.height); close()
                }
                drawPath(p, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.06f), Color.White.copy(alpha = 0.01f))))
            }
            .border(1.dp, W.lilac.copy(alpha = 0.25f), shape)
            .padding(horizontal = 14.dp, vertical = 10.dp),
        content = content,
    )
}

/** A glowing LCD readout (peach digits over faint "88:88" segments). */
@Composable
fun LcdText(text: String, ghost: String? = null, size: TextUnit = 22.sp, color: Color = W.peach) {
    Box {
        if (ghost != null) Text(ghost, color = color.copy(alpha = 0.12f), style = W.dot(size, FontWeight.Black))
        Text(text, color = color, style = W.dot(size, FontWeight.Black).copy(shadow = androidx.compose.ui.graphics.Shadow(color.copy(alpha = 0.6f), blurRadius = 14f)))
    }
}

/** A small outlined LCD badge: "FLAC 24/96", "SHUF". */
@Composable
fun LcdBadge(text: String, color: Color = W.lilac) =
    Text(text, Modifier.border(0.8.dp, color.copy(alpha = 0.55f), RoundedCornerShape(3.dp)).padding(horizontal = 5.dp, vertical = 1.dp),
        color = color, style = W.dot(10.sp), letterSpacing = 1.sp, maxLines = 1)

/**
 * The dot spectrum: columns of dots lit by the music's REAL spectrum (Levels: phone files and YouTube Music), lilac →
 * blue → peach by height. [live] = this display listens (e.g. the playing song's row); it only costs anything while
 * on screen. With nothing measurable (paused, Spotify's protected audio) it stays still — nothing is faked.
 */
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
fun DotSpectrum(live: Boolean, modifier: Modifier = Modifier, cols: Int = 4, rows: Int = 4, dot: Dp = 3.dp, gap: Dp = 1.5.dp) {
    // Listens only while the app is actually visible (not just composed: with the screen off it stays composed).
    if (live) {
        val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
        DisposableEffect(lifecycle) {
            var on = false
            fun set(v: Boolean) { if (v != on) { on = v; if (v) Levels.want() else Levels.unwant() } }
            fun update() = set(lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED) && Screen.on.value)
            val obs = androidx.lifecycle.LifecycleEventObserver { _, _ -> update() }
            lifecycle.addObserver(obs)
            val job = kotlinx.coroutines.MainScope().launch { Screen.on.collect { update() } }
            onDispose { lifecycle.removeObserver(obs); job.cancel(); set(false) }
        }
    }
    val bands by (if (live) Levels.bands else remember { kotlinx.coroutines.flow.MutableStateFlow<FloatArray?>(null) }).collectAsState()
    Canvas(modifier.size(dot * cols + gap * (cols - 1), dot * rows + gap * (rows - 1))) {
        val d = dot.toPx()
        val g = gap.toPx()
        val b = bands
        for (i in 0 until cols) {
            // Each column = the loudest of its share of the 8 bands.
            val level = if (b == null) 0f else {
                val from = i * Levels.BANDS / cols
                val to = maxOf(from + 1, (i + 1) * Levels.BANDS / cols)
                (from until to).maxOf { b[it] }
            }
            val lit = if (b == null) 1 else (level * rows + 0.35f).toInt().coerceIn(0, rows)
            for (r in 0 until rows) {
                val on = r < lit
                val c = if (!on) Color.White.copy(alpha = 0.08f) else if (b == null) W.text3 else dotColor(r / (rows - 1f).coerceAtLeast(1f))
                drawRoundRect(c, Offset(i * (d + g), size.height - (r + 1) * d - r * g), Size(d, d), CornerRadius(d * 0.3f))
            }
        }
    }
}

fun dotColor(h: Float): Color {
    fun mix(a: Color, b: Color, t: Float) = Color(a.red + (b.red - a.red) * t, a.green + (b.green - a.green) * t, a.blue + (b.blue - a.blue) * t)
    return if (h < 0.5f) mix(W.lilac, W.blue, h * 2) else mix(W.blue, W.peach, (h - 0.5f) * 2)
}

/** The EQ as the apps draw it: ten dot columns from −12 to +12 dB, lit from the 0 line. Drag a column to set it. */
@Composable
fun EqDots(gains: List<Float>, on: Boolean, modifier: Modifier = Modifier, onBand: ((Int, Float) -> Unit)? = null) {
    val dots = 13
    val half = dots / 2
    var width by remember { mutableFloatStateOf(1f) }
    var height by remember { mutableFloatStateOf(1f) }
    fun at(x: Float, y: Float) {
        val band = (x / width * 10).toInt().coerceIn(0, 9)
        val db = ((0.5f - y / height) * 2 * 12f).coerceIn(-12f, 12f)
        onBand?.invoke(band, kotlin.math.round(db * 2) / 2)
    }
    Canvas(
        modifier.then(if (onBand == null) Modifier else Modifier.pointerInput(Unit) {
            detectDragGestures(
                onDragStart = { at(it.x, it.y) },
                onDragEnd = { },
                onDrag = { ch, _ -> at(ch.position.x, ch.position.y) },
            )
        }.pointerInput(Unit) { detectTapGestures { at(it.x, it.y) } }),
    ) {
        width = size.width
        height = size.height
        val colW = size.width / 10
        val step = size.height / (dots - 1)
        for (i in 0 until 10) {
            val x = colW * (i + 0.5f)
            val level = kotlin.math.round(gains.getOrElse(i) { 0f } / 12f * half).toInt()
            for (row in 0 until dots) {
                val k = half - row
                val lit = (level > 0 && k in 1..level) || (level < 0 && k < 0 && k >= level)
                val c = when {
                    k == 0 -> W.text3
                    lit && on -> dotColor(row / (dots - 1f))
                    lit -> Color.White.copy(alpha = 0.35f)
                    else -> Color.White.copy(alpha = 0.07f)
                }
                val w = colW * 0.5f
                drawRoundRect(c, Offset(x - w / 2, row * step - 1.5.dp.toPx()), Size(w, 3.dp.toPx()), CornerRadius(1.dp.toPx()))
            }
        }
    }
}

// MARK: - The record button

/**
 * The WreckBox logo as a live record: the app icon's 32-pixel disc (lilac and peach label, dark grooves, rim). While
 * [playing], the light's reflection travels round the grooves like a turning record; [buffering] pulses the label.
 */
@Composable
fun PixelDisc(modifier: Modifier, playing: Boolean, buffering: Boolean = false) {
    val spin = remember { androidx.compose.animation.core.Animatable(0f) }
    LaunchedEffect(playing) {
        while (playing) spin.animateTo(spin.value + 360f, androidx.compose.animation.core.tween(2400, easing = androidx.compose.animation.core.LinearEasing))
    }
    val pulse by androidx.compose.animation.core.rememberInfiniteTransition(label = "pulse").animateFloat(0.55f, 1f,
        androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(500), androidx.compose.animation.core.RepeatMode.Reverse), label = "p")
    Canvas(modifier) {
        val n = 32
        val px = this.size.width / n
        val glintAt = spin.value % 360f
        fun inGlint(a: Double, center: Float) = ((a - center + 540) % 360 - 180).let { it > -16 && it < 16 }
        for (gy in 0 until n) for (gx in 0 until n) {
            val dx = gx - 15.5
            val dy = gy - 15.5
            val r = kotlin.math.sqrt(dx * dx + dy * dy)
            val angle = Math.toDegrees(kotlin.math.atan2(dy, dx))
            val color = when {
                r < 1.6 -> Color(0xFF050506) // spindle hole
                r < 3.6 -> W.lilac.copy(alpha = if (buffering) pulse else 1f)
                r < 5.6 -> W.peach.copy(alpha = if (buffering) pulse else 1f)
                r < 6.3 -> Color(0xFF050506)
                r < 14.6 -> {
                    // Two opposite reflections, where the light hits the grooves; they travel while it plays.
                    val glint = inGlint(angle, -134f + glintAt) || inGlint(angle, 46f + glintAt)
                    val band = ((r - 6.3) / 1.7).toInt() % 2 == 0
                    Color(if (glint) (if (band) 0xFF4A4A56 else 0xFF5C5C6A) else (if (band) 0xFF15151A else 0xFF202027))
                }
                r < 15.6 -> Color(0xFF34343E)
                else -> continue
            }
            drawRect(color, Offset(gx * px, gy * px), Size(px + 0.3f, px + 0.3f))
        }
    }
}

/**
 * The play button as the WreckBox logo: the pixel record ([PixelDisc]) in a dark well, under the curved glass and the
 * bezel, with a normal white play / pause icon over it.
 */
@Composable
fun RecordButton(size: Dp, playing: Boolean, buffering: Boolean = false, onClick: () -> Unit) {
    Box(
        Modifier.size(size)
            .shadow(10.dp, CircleShape, ambientColor = Color.Black, spotColor = Color.Black)
            .background(Color(0xFF07060A), CircleShape)
            .vcrGlass(CircleShape, grain = 0.12f, bezel = true)
            .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onClick)
            .semantics { contentDescription = if (playing) "Pause" else "Play" },
    ) {
        PixelDisc(Modifier.fillMaxSize(), playing, buffering)
        // The play / pause symbol: a normal (smooth) white icon over the pixel disc, with a soft dark shadow.
        if (!buffering) {
            val icon = if (playing) androidx.compose.material.icons.Icons.Filled.Pause else androidx.compose.material.icons.Icons.Filled.PlayArrow
            Icon(icon, null, Modifier.align(Alignment.Center).offset(1.dp, 1.5.dp).size(size * 0.42f), tint = Color.Black.copy(alpha = 0.6f))
            Icon(icon, null, Modifier.align(Alignment.Center).size(size * 0.42f), tint = Color.White)
        }
    }
}
