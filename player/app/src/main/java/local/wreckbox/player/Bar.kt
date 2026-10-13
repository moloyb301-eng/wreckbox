package local.wreckbox.player

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.spring
import androidx.compose.animation.expandHorizontally
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkHorizontally
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.QueueMusic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.util.UnstableApi
import kotlinx.coroutines.delay
import kotlin.random.Random

/**
 * The bottom bar: one floating pill in the widget's casing (violet graphite with granite flecks) under a VCR
 * display's curved glass (vcrGlass) — no outline. Left, the pages — Home / Search / Playlists; only the current
 * one shows its name, on a glossy candy capsule. Right, the player, condensed: a small LCD (the widget's violet glass
 * with ripple rings) with the song's name scrolling in peach dots over a row of pixels that fill up as it plays — tap
 * it for Now playing — and the play/pause button: the WreckBox record (RecordButton).
 * On pages opened from a tab (artist, album, mix) the pages step aside and only the player stays; on Now playing,
 * only the pages.
 */

/**
 * The widget's casing under curved glass, as a modifier (drawn once per size): a deep violet-graphite body lit from
 * above (light top, near-black bottom), a soft glow from inside in the app's colours (peach low left, blue low right,
 * lilac in the middle), granite flecks, the fine brushed grain, a lit top edge and a shaded bottom edge for volume —
 * then the glass over everything.
 */
fun Modifier.casing(shape: Shape) = this
    .shadow(18.dp, shape, ambientColor = Color.Black, spotColor = Color.Black)
    .vcrGlass(shape, grain = 0f, bezel = true, glareMax = 34.dp)
    .drawWithCache {
        val w = size.width
        val h = size.height
        val body = Brush.verticalGradient(0f to Color(0xFF433B55), 0.45f to Color(0xFF231F2E), 1f to Color(0xFF0B0A10))
        val glowPeach = Brush.radialGradient(listOf(W.peach.copy(alpha = 0.22f), Color.Transparent), Offset(w * 0.12f, h * 1.15f), w * 0.32f)
        val glowBlue = Brush.radialGradient(listOf(W.blue.copy(alpha = 0.20f), Color.Transparent), Offset(w * 0.9f, h * 1.15f), w * 0.32f)
        val glowLilac = Brush.radialGradient(listOf(W.lilac.copy(alpha = 0.16f), Color.Transparent), Offset(w * 0.5f, h * 1.3f), w * 0.45f)
        val rnd = Random(7)
        val flecks = List((w * h / 70).toInt().coerceAtMost(2200)) {
            Triple(Offset(rnd.nextFloat() * w, rnd.nextFloat() * h), rnd.nextFloat() * 1.2f + 0.3f,
                if (rnd.nextBoolean()) Color.White.copy(alpha = rnd.nextInt(14, 40) / 255f) else Color.Black.copy(alpha = rnd.nextInt(40, 90) / 255f))
        }
        // Volume: the top edge catches the light, the bottom edge falls into shadow (inside the shape, not an outline).
        val topLit = Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.16f), Color.Transparent), endY = h * 0.18f)
        val bottomShade = Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.55f)), startY = h * 0.72f, endY = h)
        onDrawWithContent {
            drawRect(body)
            drawRect(glowLilac); drawRect(glowPeach); drawRect(glowBlue)
            flecks.forEach { (o, r, col) -> drawCircle(col, r, o) }
            drawRect(Textures.grainBrush, alpha = 0.55f)
            drawRect(topLit); drawRect(bottomShade)
            drawContent()
        }
    }

private val pages = listOf(Page.HOME, Page.SEARCH, Page.PLAYLISTS)

private val Page.outline: ImageVector get() = when (this) {
    Page.HOME -> Icons.Outlined.Home
    Page.SEARCH -> Icons.Outlined.Search
    else -> Icons.AutoMirrored.Outlined.QueueMusic
}

@UnstableApi
@Composable
fun FloatingBar(player: HybridPlayer, ui: HybridPlayer.Ui, page: Page, showPages: Boolean, go: (Page) -> Unit) {
    val showPlayer = ui.current != null && page != Page.NOW
    Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp).padding(top = 10.dp, bottom = 12.dp), contentAlignment = Alignment.CenterEnd) {
        Row(
            Modifier.height(64.dp).then(if (showPages) Modifier.fillMaxWidth() else Modifier).casing(CircleShape).padding(8.dp).animateContentSize(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // On Now playing (no current page in the pill, no player part) the three pages spread across the pill.
            val spread = !showPlayer && page !in pages
            AnimatedVisibility(showPages, if (spread) Modifier.weight(1f) else Modifier, enter = fadeIn() + expandHorizontally(), exit = fadeOut() + shrinkHorizontally()) {
                Row(if (spread) Modifier.fillMaxWidth() else Modifier, verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = if (spread) Arrangement.SpaceEvenly else Arrangement.Start) {
                    // With a song loaded there's no room for names: the current page is its icon on the candy capsule.
                    pages.forEach { p -> Destination(p, p == page, label = !showPlayer) { go(p) } }
                }
            }
            if (showPages && !showPlayer && !spread) Spacer(Modifier.weight(1f))
            if (showPlayer) {
                if (showPages) Spacer(Modifier.width(6.dp))
                // The LCD sits in a well: shadow along its top, a light lip along its bottom.
                Box(
                    (if (showPages) Modifier.weight(1f) else Modifier.width(200.dp))
                        .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.7f), Color.Black.copy(alpha = 0.25f), Color.White.copy(alpha = 0.16f))), RoundedCornerShape(16.dp))
                        .padding(top = 2.dp, bottom = 1.5.dp, start = 1.5.dp, end = 1.5.dp),
                ) { Lcd(player, ui, Modifier.fillMaxWidth()) { go(Page.NOW) } }
                Spacer(Modifier.width(7.dp))
                RecordButton(48.dp, ui.playing, ui.buffering) { player.toggle() }
            }
        }
    }
}

/** One page in the pill: an outline icon, or (current page) icon + name on the candy capsule. */
@Composable
private fun Destination(p: Page, on: Boolean, label: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.height(48.dp)
            .then(if (on) Modifier.shadow(8.dp, CircleShape, ambientColor = Color.Black, spotColor = Color.Black) else Modifier)
            .clip(CircleShape)
            .then(if (on) Modifier.candy() else Modifier)
            .clickable(role = Role.Tab, onClick = onClick)
            .semantics { contentDescription = p.label; selected = on }
            .animateContentSize(spring(dampingRatio = 0.8f, stiffness = 500f))
            .padding(horizontal = 13.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.Center,
    ) {
        Icon(p.outline, null, Modifier.size(22.dp), tint = if (on) Color(0xFF0A0A0C) else W.text2)
        if (on && label) {
            Spacer(Modifier.width(7.dp))
            Text(p.label.uppercase(), style = W.dot(11.sp, FontWeight.Black), color = Color(0xFF0A0A0C), letterSpacing = 1.2.sp, maxLines = 1)
        }
    }
}

/** The candy capsule: the app's gradient with a white gloss on its top half and a thin light rim (the widget's keys). */
private fun Modifier.candy() = this
    .background(Brush.linearGradient(W.smartColors), CircleShape)
    .drawWithContent {
        drawContent()
        drawRoundRect(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.55f), Color.Transparent), endY = size.height * 0.5f),
            topLeft = Offset(size.height * 0.22f, size.height * 0.06f), size = Size(size.width - size.height * 0.44f, size.height * 0.4f),
            cornerRadius = CornerRadius(size.height * 0.2f))
    }
    .bezel(CircleShape, 0.9f)

/**
 * The player's LCD: the widget's violet glass (ripple rings, scanlines), the song's name scrolling in peach Doto, and
 * under it a row of pixels (green → yellow → red along the row) filling up left to right as the song plays — the next one blinks while it plays; paused,
 * the lit ones dim.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@UnstableApi
@Composable
private fun Lcd(player: HybridPlayer, ui: HybridPlayer.Ui, modifier: Modifier, onClick: () -> Unit) {
    val t = ui.current ?: return
    val progress by songProgress(player, t.key)
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier.height(46.dp).lcdFace(shape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "Now playing: ${t.title}"; stateDescription = "${(progress * 100).toInt()}% played" }
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        LedText("${t.title.uppercase()}  ·  ${t.artist.uppercase()}", 11)
        ProgressPixels(progress, ui.playing, Modifier.fillMaxWidth().height(12.dp))
    }
}

/** How far into the song (0..1), read twice a second while the screen is on. */
@UnstableApi
@Composable
fun songProgress(player: HybridPlayer, key: String?): State<Float> = produceState(0f, key) {
    while (true) {
        if (Screen.on.value) value = player.durationMs().let { d -> if (d > 0) (player.positionMs().toFloat() / d).coerceIn(0f, 1f) else 0f }
        delay(500)
    }
}

/** The widget's LCD face under glass: deep violet with lilac ripple rings and scanlines. */
fun Modifier.lcdFace(shape: Shape) = vcrGlass(shape, grain = 0.25f)
    .drawWithCache {
        val glass = Brush.radialGradient(listOf(Color(0xFF2A1F3D), Color(0xFF07060B)), Offset(size.width * 0.88f, size.height * 1.1f), size.width)
        onDrawBehind {
            drawRect(glass)
            for (i in 1..18) drawCircle(W.lilac.copy(alpha = (46 - i * 2).coerceAtLeast(6) / 255f), i * 7.dp.toPx(), Offset(size.width * 0.88f, size.height * 1.1f), style = Stroke(1.6f))
            var y = 0f
            while (y < size.height) { drawRect(Color.Black.copy(alpha = 0.10f), Offset(0f, y), Size(size.width, 1f)); y += 3f }
        }
    }

/** LED lettering: peach Doto with a glow, scrolling when it doesn't fit. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun LedText(text: String, sp: Int, modifier: Modifier = Modifier.fillMaxWidth()) = Text(
    text, modifier.basicMarquee(iterations = Int.MAX_VALUE, initialDelayMillis = 1500),
    style = W.dot(sp.sp, FontWeight.Black).copy(shadow = androidx.compose.ui.graphics.Shadow(W.peach.copy(alpha = 0.6f), blurRadius = 8f)),
    color = W.peach, maxLines = 1, letterSpacing = 0.8.sp,
)

/**
 * The progress pixels: a grid filling column by column, left to right, green at the start through yellow to red at
 * the end (how much is done, how much is left); the next one blinks while it plays; paused, the lit ones dim.
 */
@Composable
fun ProgressPixels(progress: Float, playing: Boolean, modifier: Modifier, cols: Int = 22, rows: Int = 2) {
    var blink by remember { mutableStateOf(true) }
    LaunchedEffect(playing) { while (playing) { delay(450); blink = !blink }; blink = true }
    Canvas(modifier) {
        val cell = size.width / cols
        val dot = minOf(cell, size.height / rows) * 0.72f
        val lit = (progress * cols * rows).toInt()
        for (col in 0 until cols) for (row in 0 until rows) {
            val i = col * rows + row
            val h = Color.hsv(120f * (1f - col / (cols - 1f)), 0.75f, 1f)
            val color = when {
                i < lit -> h.copy(alpha = if (playing) 1f else 0.55f)
                i == lit && playing && blink -> h
                else -> Color.White.copy(alpha = 0.08f)
            }
            drawRect(color, Offset(col * cell + (cell - dot) / 2, row * (size.height / rows) + (size.height / rows - dot) / 2), Size(dot, dot))
        }
    }
}
