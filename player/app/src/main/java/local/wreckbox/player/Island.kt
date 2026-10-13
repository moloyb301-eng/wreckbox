package local.wreckbox.player

import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Build
import android.provider.Settings
import android.view.Display
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.FrameLayout
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationVector1D
import androidx.compose.animation.core.spring
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.lerp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.setViewTreeLifecycleOwner
import androidx.media3.common.util.UnstableApi
import androidx.savedstate.SavedStateRegistry
import androidx.savedstate.SavedStateRegistryController
import androidx.savedstate.SavedStateRegistryOwner
import androidx.savedstate.setViewTreeSavedStateRegistryOwner
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * The island: for phones with a hole-punch camera, a small pill floating round the camera while music plays and the
 * app isn't on screen — the bar's design (the widget's casing under curved glass, the bezel): the song's name scrolling
 * on an LED screen left of the camera, the WreckBox record (the logo, its shine turning while it plays) right of it.
 * Tap it and it grows into a widget-style player (cover, the LCD with title, artist, the peach clock and the progress
 * pixels; previous / play / next / like / open); a tap outside or 8 s untouched folds it back.
 *
 * Drawn as an accessibility overlay (IslandService — the only kind of window that sits above the status bar, so it can
 * be tapped and covers the icons under it), placed on the camera cutout; Settings → Playback turns it on/off.
 */
@UnstableApi
object Island {
    /** The app's own screen is showing (MainActivity started): no island then. */
    val appVisible = MutableStateFlow(false)
    val enabled = MutableStateFlow(true)
    /** The accessibility service, while it's on (Settings → Accessibility → WreckBox island): it hosts the window. */
    val host = MutableStateFlow<android.accessibilityservice.AccessibilityService?>(null)
    /** Landscape: full-screen video and games — the island steps aside (IslandService reports rotations). */
    val landscape = MutableStateFlow(false)
    /** Closed with the ✕ on the opened island: it stays away until music starts again after a pause. */
    private val closed = MutableStateFlow(false)
    /** No music for 55 s (paused or stopped): the island steps aside until something plays again. */
    private val idle = MutableStateFlow(false)
    /**
     * The island is in use (switched on, its service running, not closed, not idle): the player's notification is then
     * a silent, minimised one — no media card in the panel, no status-bar icon (PlayerService's notification provider).
     * Closed or idle, the normal media notification comes back, so the controls are never out of reach.
     */
    val active = combine(enabled, host, closed, idle) { on, h, shut, quiet -> on && h != null && !shut && !quiet }
    /** [active] right now — read when the notification is built, so it can't be one change behind. */
    fun isActive() = enabled.value && host.value != null && !closed.value && !idle.value

    // Two windows that never change size or position (Android doesn't move and resize a window in the same frame as
    // its new content, so a resizing island jumped sideways for a frame or two): the pill on top, and under it the
    // player-sized card window, see-through and untouchable until the card grows out from under the pill.
    private var root: FrameLayout? = null
    private var cardRoot: FrameLayout? = null
    private var cardLp: WindowManager.LayoutParams? = null
    private var scope = MainScope()
    private val expanded = mutableStateOf(false)

    /** The card window takes taps (and shows) only while the card is out; folded, taps go to the app under it. */
    private fun setCardActive(on: Boolean) {
        val frame = cardRoot ?: return
        val lp = cardLp ?: return
        val flags = if (on) lp.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
            else lp.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        val alpha = if (on) 1f else 0f // a fully transparent window isn't composited at all
        if (flags == lp.flags && alpha == lp.alpha) return
        lp.flags = flags
        lp.alpha = alpha
        runCatching { rootWm?.updateViewLayout(frame, lp) }
    }

    /** The accessibility service is switched on for this app. */
    fun allowed(c: Context): Boolean {
        val list = Settings.Secure.getString(c.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        return list.split(':').any { it.startsWith(c.packageName + "/") }
    }

    fun setEnabled(c: Context, on: Boolean) {
        c.getSharedPreferences("settings", Context.MODE_PRIVATE).edit().putBoolean("island", on).apply()
        enabled.value = on
    }

    /** The ✕: folds the card back, then the island goes until music starts again after a pause. */
    private fun close() {
        expanded.value = false
        scope.launch { delay(400); closed.value = true; Debug.log("island: closed") }
    }

    fun start(service: PlayerService, player: HybridPlayer) {
        enabled.value = service.getSharedPreferences("settings", Context.MODE_PRIVATE).getBoolean("island", true)
        scope.launch {
            // A real pause is 3 s without music (not the gap between two songs); 55 s without it hides the island.
            var paused = false
            player.ui.map { it.playing || it.buffering }.distinctUntilChanged().collectLatest { playing ->
                if (playing) {
                    if (paused && closed.value) Debug.log("island: back (music again)")
                    if (paused) closed.value = false
                    paused = false
                    idle.value = false
                } else {
                    delay(3_000)
                    paused = true
                    delay(52_000)
                    idle.value = true
                    Debug.log("island: idle (no music for 55 s)")
                }
            }
        }
        scope.launch {
            combine(combine(player.ui, appVisible, Screen.on) { ui, app, screen -> ui.current != null && !app && screen },
                active, host, landscape) { want, on, h, wide -> if (want && on && !wide) h else null }
                .distinctUntilChanged()
                .collect { h ->
                    Debug.log("island: host=${h != null}")
                    hide()
                    if (h != null) show(h, player)
                }
        }
    }

    fun stop() { hide(); scope.cancel(); scope = MainScope() }

    /** The camera hole at the top of the screen, if the phone has one. */
    private fun cutout(c: Context): Rect? {
        val d = c.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY) ?: return null
        val rects = d.cutout?.boundingRects ?: return null
        return rects.filter { it.top < 300 && it.width() < d.mode.physicalWidth / 3 }.minByOrNull { it.top }
    }

    private fun show(c: Context, player: HybridPlayer) {
        if (root != null) return
        val cut = cutout(c) ?: return Debug.log("island: no camera cutout found")
        val wm = c.getSystemService(WindowManager::class.java)
        val dm = c.resources.displayMetrics
        val d = dm.density
        // Samsung reports the cutout as the whole status-bar height; the hole itself is round, as wide as the cutout,
        // centred on it.
        val camW = cut.width() / d
        val headerH = (camW + 12f).coerceAtLeast(30f)
        val screenW = (dm.widthPixels / d).dp
        // 0 = the pill, 1 = the player; shared by both windows.
        val progress = Animatable(0f)
        // Explicit widths: a wrap-content window is first measured at Android's "preferred dialog width" (~300 dp),
        // which squeezed the expanded player. Pill: just the pill; card: nearly the screen's width — an even number of
        // pixels wider, so both centre on exactly the same pixel and the card lines up under the pill.
        val compactPx = ((60f * 2 + camW + 18f + 8f) * d).toInt()
        val bigPx = (dm.widthPixels - (12 * d).toInt()).let { if ((it - compactPx) % 2 == 0) it else it - 1 }
        // Heights too (a growing wrap-content window was measured short, squashing the buttons): the header, and the
        // header + the player (4 + 84 + 12 + 58 + 14 dp) + the Column's padding.
        val compactH = ((headerH + 4f) * d).toInt()
        val bigH = ((headerH + 172f + 4f + 6f) * d).toInt()
        fun params(w: Int, h: Int, flags: Int, name: String) = WindowManager.LayoutParams(
            w, h,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY, // above the status bar (an app overlay sits under it)
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or flags,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            // Centred on the camera, the camera in the middle of the header row.
            x = cut.centerX() - dm.widthPixels / 2
            y = (cut.centerY() - headerH / 2 * d - 2 * d).toInt() // (−2 dp: the Column's own top padding)
            if (Build.VERSION.SDK_INT >= 30) layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
            title = name
        }
        fun window(content: @Composable () -> Unit, onOutside: (() -> Unit)? = null): FrameLayout {
            val owner = OverlayOwner()
            val compose = ComposeView(c).apply {
                setViewTreeLifecycleOwner(owner)
                setViewTreeSavedStateRegistryOwner(owner)
                setContent { WreckBoxTheme { content() } }
            }
            val frame = object : FrameLayout(c) {
                override fun dispatchTouchEvent(e: MotionEvent): Boolean {
                    if (e.actionMasked == MotionEvent.ACTION_OUTSIDE) { onOutside?.invoke(); return false }
                    return super.dispatchTouchEvent(e)
                }
            }
            // Compose looks for these on the window's root view.
            frame.setViewTreeLifecycleOwner(owner)
            frame.setViewTreeSavedStateRegistryOwner(owner)
            frame.addView(compose, FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER_HORIZONTAL))
            return frame
        }
        // The card first, so the pill (added second) sits above it. A tap anywhere outside the card folds it back.
        val card = window({ CardUi(c, player, camW.dp, headerH.dp, screenW, expanded, progress, ::setCardActive, ::close) }) { expanded.value = false }
        val lp = params(bigPx, bigH, WindowManager.LayoutParams.FLAG_WATCH_OUTSIDE_TOUCH or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE, "WreckBox island card")
            .apply { alpha = 0f }
        val pill = window({ PillUi(player, camW.dp, headerH.dp, expanded, progress) })
        runCatching {
            wm.addView(card, lp); cardRoot = card; cardLp = lp; rootWm = wm
            wm.addView(pill, params(compactPx, compactH, 0, "WreckBox island")); root = pill
            Debug.log("island: shown at $cut")
        }.onFailure { Debug.log("island: couldn't add the window: $it"); hide(); return }
    }

    private var rootWm: WindowManager? = null

    private fun hide() {
        val r = root
        val cr = cardRoot
        root = null
        cardRoot = null
        cardLp = null
        expanded.value = false
        if (r != null) runCatching { rootWm?.removeView(r) }
        if (cr != null) runCatching { rootWm?.removeView(cr) }
    }

    /** What a Compose view outside an activity needs: a lifecycle and a saved-state registry of its own. */
    private class OverlayOwner : LifecycleOwner, SavedStateRegistryOwner {
        private val registry = LifecycleRegistry(this)
        private val saved = SavedStateRegistryController.create(this)
        override val lifecycle: Lifecycle get() = registry
        override val savedStateRegistry: SavedStateRegistry get() = saved.savedStateRegistry
        init {
            saved.performRestore(null)
            registry.currentState = Lifecycle.State.RESUMED
        }
    }
}

@UnstableApi
@Composable
private fun PillUi(player: HybridPlayer, camW: Dp, headerH: Dp, expandedState: MutableState<Boolean>, progress: Animatable<Float, AnimationVector1D>) {
    // The pill (top window): LED screen | camera | the record. It never moves; while the card is out it fades away and
    // leaves just the room round the camera (still tappable: a tap there folds the card back).
    val ui by player.ui.collectAsState()
    val t = ui.current ?: return
    var expanded by expandedState
    Row(Modifier.padding(horizontal = 4.dp, vertical = 2.dp)
        .graphicsLayer { alpha = (1f - progress.value / 0.25f).coerceIn(0f, 1f) }
        .width(pillWidth(camW)).height(headerH).casing(RoundedCornerShape(headerH / 2))
        .clickable { expanded = !expanded }.padding(horizontal = 4.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.weight(1f).fillMaxHeight().lcdFace(RoundedCornerShape(headerH / 2)).padding(horizontal = 8.dp), contentAlignment = Alignment.CenterStart) {
            LedText("${t.title.uppercase()}  ·  ${t.artist.uppercase()}", 8)
        }
        Spacer(Modifier.width(camW + 8.dp))
        Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.CenterEnd) {
            PixelDisc(Modifier.fillMaxHeight().aspectRatio(1f), ui.playing, ui.buffering)
        }
    }
}

private fun pillWidth(camW: Dp) = 60.dp * 2 + camW + 18.dp

@UnstableApi
@Composable
private fun CardUi(c: Context, player: HybridPlayer, camW: Dp, headerH: Dp, screenW: Dp, expandedState: MutableState<Boolean>,
                   progress: Animatable<Float, AnimationVector1D>, setActive: (Boolean) -> Unit, close: () -> Unit) {
    // The card (bottom window): grows out from under the pill into the widget-style player and folds back under it.
    // One progress value drives the shape, the reveal and both fades; the casing is opaque, so nothing behind it shows
    // through. The pill's contents are gone in the first quarter, the player fades in once the card is a third open.
    val ui by player.ui.collectAsState()
    val t = ui.current ?: return
    var expanded by expandedState
    var touched by remember { mutableIntStateOf(0) }
    // Folds back by itself after 8 s without a touch.
    LaunchedEffect(expanded, touched) { if (expanded) { delay(8000); expanded = false } }
    LaunchedEffect(expanded) {
        val spec = spring<Float>(dampingRatio = 0.86f, stiffness = 400f)
        if (expanded) { setActive(true); progress.animateTo(1f, spec) }
        else { progress.animateTo(0f, spec); setActive(false) }
    }
    val p = progress.value.coerceIn(0f, 1f)
    if (p == 0f) return
    // (the window is 12 dp narrower than the screen; the Column's 4 dp side padding brings this to 20)
    val fullW = screenW - 20.dp
    fun open() {
        c.startActivity(Intent(c, MainActivity::class.java).putExtra("page", "now").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
        expanded = false
    }
    Column(Modifier.padding(horizontal = 4.dp, vertical = 2.dp).width(lerp(pillWidth(camW), fullW, p))
        .casing(RoundedCornerShape(lerp(headerH / 2, 30.dp, p)))) {
        // The room round the camera, under the pill; at its right end the ✕ that puts the island away (until music
        // starts again after a pause).
        Box(Modifier.fillMaxWidth().height(headerH).padding(end = 10.dp)
            .graphicsLayer { alpha = ((progress.value - 0.35f) / 0.65f).coerceIn(0f, 1f) }, contentAlignment = Alignment.CenterEnd) {
            RoundButton(Icons.Filled.Close, "Close the island", 28.dp, W.text2) { close() }
        }
        // The player, laid out at its full size the whole time and revealed from the top, so it never reflows (buttons
        // squeezed into a strip) while the card grows.
        Box(Modifier.reveal({ progress.value }, fullW).graphicsLayer { alpha = ((progress.value - 0.35f) / 0.65f).coerceIn(0f, 1f) }) {
            IslandPlayer(player, ui, t, onTouch = { touched++ }, open = ::open)
        }
    }
}

/** Measures the content at [fullWidth] (whatever the card's width right now) and shows its top [fraction], centred. */
private fun Modifier.reveal(fraction: () -> Float, fullWidth: Dp) = clipToBounds().layout { m, c ->
    val fw = fullWidth.roundToPx()
    val placeable = m.measure(Constraints.fixedWidth(fw))
    val w = c.maxWidth.coerceAtMost(fw)
    layout(w, (placeable.height * fraction().coerceIn(0f, 1f)).roundToInt()) { placeable.place((w - fw) / 2, 0) }
}

@UnstableApi
@Composable
private fun IslandPlayer(player: HybridPlayer, ui: HybridPlayer.Ui, t: Track, onTouch: () -> Unit, open: () -> Unit) {
    val c = androidx.compose.ui.platform.LocalContext.current
    val lib = Library.get(c)
    val liked by lib.data.collectAsState().let { d -> derivedStateOf { d.value.likes.any { it.key == t.key } } }
    val progress by songProgress(player, t.key)
    val pos by produceState(0L, t.key) { while (true) { if (Screen.on.value) value = player.positionMs(); delay(500) } }
    Column(Modifier.padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Cover(t.art, Modifier.size(84.dp).vcrGlass(RoundedCornerShape(16.dp), 0.18f, bezel = true), RoundedCornerShape(16.dp), t.title)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f).height(84.dp).lcdFace(RoundedCornerShape(16.dp)).clickable { open() }.padding(horizontal = 11.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.SpaceBetween) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    DotLabel(when (t.source) { Source.LOCAL -> "Phone"; Source.YOUTUBE -> "YTM"; Source.SPOTIFY -> "Spot" }, color = W.lilac, size = 8.5.sp)
                    shortQuality(ui.quality)?.let { DotLabel("  ·  $it", color = W.lilac.copy(alpha = 0.7f), size = 8.5.sp) }
                }
                Text(t.title, style = W.ui(14.sp, FontWeight.Bold), maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(time(pos), style = W.dot(17.sp, FontWeight.Black).copy(shadow = androidx.compose.ui.graphics.Shadow(W.peach.copy(alpha = 0.6f), blurRadius = 8f)), color = W.peach)
                    Text(" / ${time(player.durationMs())}", style = W.dot(10.sp), color = W.text3, modifier = Modifier.padding(bottom = 2.dp))
                    Spacer(Modifier.weight(1f))
                    Text(t.artist, style = W.ui(11.sp), color = W.text2, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(start = 8.dp, bottom = 1.dp))
                }
                ProgressPixels(progress, ui.playing, Modifier.fillMaxWidth().height(9.dp), cols = 30)
            }
        }
        Row(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
            RoundButton(if (liked) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, if (liked) "Unlike" else "Like", 40.dp, if (liked) W.peach else W.text) { lib.toggleLike(t); onTouch() }
            RoundButton(Icons.Filled.SkipPrevious, "Previous", 44.dp) { player.seekToPrevious(); onTouch() }
            RecordButton(58.dp, ui.playing, ui.buffering) { player.toggle(); onTouch() }
            RoundButton(Icons.Filled.SkipNext, "Next", 44.dp) { player.seekToNext(); onTouch() }
            RoundButton(Icons.AutoMirrored.Filled.OpenInNew, "Open WreckBox Player", 40.dp) { open() }
        }
    }
}
