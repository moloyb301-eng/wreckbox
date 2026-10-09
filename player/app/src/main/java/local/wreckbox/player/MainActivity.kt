package local.wreckbox.player

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.hazeSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Four pages — Home, Search, Playlists, Now playing — under a glass bar with the mini player. */
@UnstableApi
class MainActivity : ComponentActivity() {
    private var player by mutableStateOf<HybridPlayer?>(null)
    private var page by mutableStateOf(Page.HOME)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS, Manifest.permission.READ_MEDIA_AUDIO), 1)
        PlayerService.connect(this) { s -> player = s.player; intent?.let { test(it); widget(it) } }
        if (intent?.getStringExtra("page") == "now") page = Page.NOW
        setContent {
            WreckBoxTheme {
                player?.let { App(it, page) { p -> page = p } } ?: Box(Modifier.fillMaxSize().background(W.bg))
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getStringExtra("page") == "now") page = Page.NOW
        test(intent)
        widget(intent)
    }

    /** A widget key pressed while the player wasn't running: it opened the app; do it now. */
    private fun widget(i: Intent) {
        val action = i.getStringExtra("widget") ?: return
        i.removeExtra("widget")
        player?.let { PlayerWidget.run(it, action, this) }
    }

    /**
     * Testing over USB (debug only):
     *   adb shell am start -n local.wreckbox.player/.MainActivity --es cmd play|queue|seek|next|page --es source YOUTUBE|SPOTIFY --es id <id> --es title <t> --el ms <pos> --es to HOME|SEARCH|PLAYLISTS|NOW
     */
    private fun test(i: Intent) {
        if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE == 0 && !BuildConfig.TEST_COMMANDS) return
        val p = player ?: return
        val cmd = i.getStringExtra("cmd") ?: return
        val t = i.getStringExtra("id")?.let { Track(Source.valueOf(i.getStringExtra("source") ?: "YOUTUBE"), it, i.getStringExtra("title") ?: it, i.getStringExtra("artist") ?: "") }
        when (cmd) {
            "play" -> t?.let { p.playList(listOf(it)) }
            "queue" -> t?.let { p.addToQueue(it) }
            "seek" -> p.seekMs(i.getLongExtra("ms", 0))
            "next" -> p.seekToNext()
            "page" -> page = Page.valueOf(i.getStringExtra("to") ?: "HOME")
        }
    }
}

/** The Search page's last query and results, so they survive switching tabs. */
object SearchMemory {
    val query = mutableStateOf("")
    val results = mutableStateOf<List<Track>>(emptyList())
    val searched = mutableStateOf("")
    val failed = mutableStateOf<List<String>>(emptyList())
    val filter = mutableStateOf<Source?>(null)
}

enum class Page(val label: String, val icon: ImageVector) {
    HOME("Home", Icons.Filled.Home), SEARCH("Search", Icons.Filled.Search),
    PLAYLISTS("Playlists", Icons.AutoMirrored.Filled.QueueMusic), NOW("Playing", Icons.Filled.GraphicEq),
}

/** Room the glass bar takes at the bottom, so lists can scroll under it and still end above it. */
val LocalBarHeight = compositionLocalOf { 0.dp }

@UnstableApi
@Composable
fun App(player: HybridPlayer, page: Page, go: (Page) -> Unit) {
    val ui by player.ui.collectAsState()
    var openPlaylist by remember { mutableStateOf<String?>(null) }
    var settings by remember { mutableStateOf(false) }
    val haze = remember { HazeState() }
    var barHeight by remember { mutableStateOf(0.dp) }
    val density = LocalDensity.current
    BackHandler(page != Page.HOME || openPlaylist != null) {
        if (openPlaylist != null) openPlaylist = null else go(Page.HOME)
    }
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().hazeSource(haze)) {
            AmbientBackground(ui.current?.art)
            CompositionLocalProvider(LocalBarHeight provides barHeight) {
                AnimatedContent(page to openPlaylist, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "page") { (pg, pl) ->
                    Box(Modifier.fillMaxSize().statusBarsPadding()) {
                        when (pg) {
                            Page.HOME -> HomePage(player, { settings = true }) { openPlaylist = it; go(Page.PLAYLISTS) }
                            Page.SEARCH -> SearchPage(player)
                            Page.PLAYLISTS -> if (pl != null) PlaylistPage(player, pl) { openPlaylist = null } else PlaylistsPage { openPlaylist = it }
                            Page.NOW -> NowPlayingPage(player, ui)
                        }
                    }
                }
            }
        }
        // The glass bar: mini player + tabs, blurring what scrolls under it.
        Column(
            Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                .onSizeChanged { barHeight = with(density) { it.height.toDp() } }
                .hazeEffect(haze, HazeStyle(backgroundColor = W.bg, tint = HazeTint(W.bg.copy(alpha = 0.55f)), blurRadius = 28.dp, noiseFactor = 0.05f))
                .border(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.10f), Color.Transparent)), RoundedCornerShape(0.dp))
                .navigationBarsPadding(),
        ) {
            if (page != Page.NOW && ui.current != null) MiniPlayer(player, ui) { go(Page.NOW) }
            NavBar(page) { p -> go(p); if (p != Page.PLAYLISTS) openPlaylist = null }
        }
        // Messages clear themselves after a few seconds (OK clears them at once).
        LaunchedEffect(ui.message) { if (ui.message != null) { delay(3000); player.clearMessage() } }
        ui.message?.let { m ->
            Row(
                Modifier.align(Alignment.BottomCenter).padding(bottom = barHeight + 10.dp, start = 16.dp, end = 16.dp).fillMaxWidth()
                    .hazeEffect(haze, HazeStyle(backgroundColor = W.bg, tint = HazeTint(Color(0xCC1B1922)), blurRadius = 24.dp)).glass(RoundedCornerShape(16.dp))
                    .padding(start = 16.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(m, Modifier.weight(1f), style = W.ui(14.sp, FontWeight.Medium), color = W.text)
                TextButton({ player.clearMessage() }) { Text("OK", color = W.lilac) }
            }
        }
    }
    if (settings) SettingsSheet { settings = false }
}

@Composable
fun NavBar(page: Page, go: (Page) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp)) {
        Page.entries.forEach { p ->
            val on = page == p
            Column(
                Modifier.weight(1f).clip(RoundedCornerShape(14.dp)).clickable { go(p) }.padding(vertical = 6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(p.icon, p.label, tint = if (on) W.text else W.text3, modifier = Modifier.size(24.dp))
                Text(p.label, style = W.ui(11.sp, if (on) FontWeight.Bold else FontWeight.Medium), color = if (on) W.text else W.text3)
                // The selected tab's mark: a short iridescent bar
                Box(Modifier.padding(top = 3.dp).size(if (on) 16.dp else 0.dp, 2.5.dp).background(W.smart, CircleShape))
            }
        }
    }
}

// MARK: - Shared pieces

fun songs(n: Int) = if (n == 1) "1 song" else "$n songs"

fun time(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

val Source.tint get() = when (this) { Source.LOCAL -> W.lilac; Source.YOUTUBE -> W.peach; Source.SPOTIFY -> W.blue }

@Composable
fun SourceTag(s: Source) = Text(s.label.uppercase(), color = s.tint.copy(alpha = 0.9f), style = W.dot(9.5.sp), letterSpacing = 1.2.sp)

/** "FLAC 24/96" / "MP3 320" for a row; the full label is on Now playing. */
fun shortQuality(q: String?) = q?.split(" · ")?.let { p ->
    when {
        p.size >= 3 -> "${p[0]} ${p[1]}"
        p.size == 2 -> "${p[0]} ${p[1].removePrefix("~").removeSuffix(" kbps").replace(",", "")}"
        else -> p[0]
    }
}

/** A list in a glass card (the Mac app's grouped lists). */
fun LazyListScope.glassList(tracks: List<Track>, key: String, row: @Composable (Int, Track) -> Unit) {
    itemsIndexed(tracks, key = { i, t -> "$key$i${t.key}" }) { i, t ->
        val first = i == 0
        val last = i == tracks.lastIndex
        val shape = RoundedCornerShape(if (first) 20.dp else 0.dp, if (first) 20.dp else 0.dp, if (last) 20.dp else 0.dp, if (last) 20.dp else 0.dp)
        Box(Modifier.padding(horizontal = 12.dp).clip(shape).background(W.glassFill).padding(top = if (first) 6.dp else 0.dp, bottom = if (last) 6.dp else 0.dp)) { row(i, t) }
    }
}

/** A song in any list: tap to play (with the rest of the list after it), ⋮ for queue / like / playlist. */
@UnstableApi
@Composable
fun TrackRow(player: HybridPlayer, t: Track, playing: Boolean = false, onPlay: () -> Unit, onRemove: (() -> Unit)? = null,
             extra: (@Composable ColumnScope.(close: () -> Unit) -> Unit)? = null) {
    // Swipe: in a list, right = add to queue, left = play next; in the queue (onRemove), either way = remove.
    val haptic = androidx.compose.ui.platform.LocalHapticFeedback.current
    val swipe = rememberSwipeToDismissBoxState(
        confirmValueChange = { v ->
            if (v != SwipeToDismissBoxValue.Settled) {
                haptic.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                when {
                    onRemove != null -> onRemove()
                    v == SwipeToDismissBoxValue.StartToEnd -> player.addToQueue(t)
                    else -> player.playNext(t)
                }
            }
            false // always spring back: the list itself changes when a song is removed
        },
        positionalThreshold = { it * 0.3f },
    )
    SwipeToDismissBox(swipe, backgroundContent = { SwipeBackground(swipe.dismissDirection, onRemove != null) }) {
        // While it moves, the row is solid so it slides over the action rather than through it.
        Box(if (swipe.dismissDirection != SwipeToDismissBoxValue.Settled) Modifier.background(Color(0xFF17151D)) else Modifier) {
            TrackRowContent(player, t, playing, onPlay, extra)
        }
    }
}

/** What a swipe will do, revealed under the row. */
@Composable
fun SwipeBackground(direction: SwipeToDismissBoxValue, remove: Boolean) {
    if (direction == SwipeToDismissBoxValue.Settled) return
    val right = direction == SwipeToDismissBoxValue.StartToEnd
    val (icon, label) = when {
        remove -> Icons.Filled.RemoveCircleOutline to "Remove"
        right -> Icons.AutoMirrored.Filled.QueueMusic to "Add to queue"
        else -> Icons.Filled.SkipNext to "Play next"
    }
    val tint = if (remove) W.peach else if (right) W.lilac else W.blue
    Row(
        Modifier.fillMaxSize().background(Brush.horizontalGradient(if (right) listOf(tint.copy(alpha = 0.32f), Color.Transparent) else listOf(Color.Transparent, tint.copy(alpha = 0.32f))))
            .padding(horizontal = 22.dp),
        horizontalArrangement = if (right) Arrangement.Start else Arrangement.End, verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        DotLabel(label, color = tint)
    }
}

@UnstableApi
@Composable
private fun TrackRowContent(player: HybridPlayer, t: Track, playing: Boolean, onPlay: () -> Unit, extra: (@Composable ColumnScope.(close: () -> Unit) -> Unit)?) {
    val c = LocalContext.current
    val lib = Library.get(c)
    // Only what this row shows: whether it's liked, and (only for the playing row) whether music is playing — so a
    // change to the player or the library doesn't redraw every row.
    val liked by remember(t.key) {
        lib.data.map { d -> d.likes.any { it.key == t.key } }.distinctUntilChanged()
    }.collectAsState(lib.isLiked(t))
    val live = if (playing) player.ui.collectAsState().value.playing else false
    var menu by remember { mutableStateOf(false) }
    var pick by remember { mutableStateOf(false) }
    var quality by remember(t.key) { mutableStateOf(Quality.cached(t)) }
    if (t.source == Source.LOCAL && quality == null) LaunchedEffect(t.key) { quality = withContext(Dispatchers.IO) { Quality.of(c, t) } }
    Row(Modifier.fillMaxWidth().clickable(onClick = onPlay).padding(start = 10.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Box {
            Cover(t.art, Modifier.size(46.dp), RoundedCornerShape(W.Radius.art))
            if (playing) Box(Modifier.size(46.dp).background(Color.Black.copy(alpha = 0.45f), RoundedCornerShape(W.Radius.art)), contentAlignment = Alignment.Center) {
                DotSpectrum(live)
            }
        }
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text(t.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = W.ui(15.sp, FontWeight.SemiBold), color = if (playing) W.lilac else W.text)
            Row(verticalAlignment = Alignment.CenterVertically) {
                SourceTag(t.source)
                Text("  ${t.artist}${t.album?.let { " · $it" } ?: ""}", maxLines = 1, overflow = TextOverflow.Ellipsis, style = W.ui(12.5.sp), color = W.text2)
            }
        }
        Column(horizontalAlignment = Alignment.End) {
            if (t.durationMs > 0) Text(time(t.durationMs), style = W.dot(12.sp), color = W.text2)
            shortQuality(quality)?.let { Text(it, style = W.dot(9.5.sp), color = W.lilac.copy(alpha = 0.8f), maxLines = 1) }
        }
        if (liked) Icon(Icons.Filled.Favorite, "Liked", tint = W.peach, modifier = Modifier.padding(start = 6.dp).size(14.dp))
        Box {
            IconButton({ menu = true }) { Icon(Icons.Filled.MoreVert, "More", tint = W.text3) }
            DropdownMenu(menu, { menu = false }, shape = RoundedCornerShape(16.dp), containerColor = Color(0xF21B1922)) {
                DropdownMenuItem({ Text("Play next") }, { player.playNext(t); menu = false }, leadingIcon = { Icon(Icons.Filled.SkipNext, null) })
                DropdownMenuItem({ Text("Add to queue") }, { player.addToQueue(t); menu = false }, leadingIcon = { Icon(Icons.AutoMirrored.Filled.QueueMusic, null) })
                DropdownMenuItem({ Text(if (lib.isLiked(t)) "Unlike" else "Like") }, { lib.toggleLike(t); menu = false },
                    leadingIcon = { Icon(if (lib.isLiked(t)) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null) })
                DropdownMenuItem({ Text("Add to playlist…") }, { pick = true; menu = false }, leadingIcon = { Icon(Icons.AutoMirrored.Filled.PlaylistAdd, null) })
                extra?.invoke(this) { menu = false }
            }
        }
    }
    if (pick) AddToPlaylistDialog(t) { pick = false }
}

@Composable
fun AddToPlaylistDialog(t: Track, close: () -> Unit) {
    val lib = Library.get(LocalContext.current)
    val data by lib.data.collectAsState()
    var name by remember { mutableStateOf("") }
    AlertDialog(
        modifier = Modifier.padding(horizontal = 28.dp), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        onDismissRequest = close, containerColor = Color(0xF2141219), shape = RoundedCornerShape(W.Radius.card),
        title = { Text("Add to playlist", style = W.ui(20.sp, FontWeight.Bold)) },
        text = {
            Column {
                data.playlists.forEach { p ->
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable { lib.addToPlaylist(p.id, t); close() }.padding(vertical = 8.dp, horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Cover(p.tracks.firstOrNull()?.art, Modifier.size(36.dp), RoundedCornerShape(6.dp))
                        Text(p.name, Modifier.padding(start = 12.dp), style = W.ui(15.sp, FontWeight.SemiBold))
                    }
                }
                Spacer(Modifier.height(8.dp))
                GlassField(name, { name = it }, "New playlist")
            }
        },
        confirmButton = { TextButton({ if (name.isNotBlank()) { lib.createPlaylist(name, listOf(t)); close() } }) { Text("Create", color = W.lilac) } },
        dismissButton = { TextButton(close) { Text("Cancel", color = W.text2) } },
    )
}

/** A text field in a glass capsule. */
@Composable
fun GlassField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier, leading: ImageVector? = null,
               trailing: (@Composable () -> Unit)? = null, onDone: (() -> Unit)? = null) {
    Row(modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(horizontal = 14.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        if (leading != null) { Icon(leading, null, tint = W.text3, modifier = Modifier.size(20.dp)); Spacer(Modifier.width(10.dp)) }
        Box(Modifier.weight(1f).padding(vertical = 10.dp)) {
            if (value.isEmpty()) Text(placeholder, style = W.ui(15.sp), color = W.text3, maxLines = 1)
            BasicTextField(value, onChange, singleLine = true, textStyle = W.ui(15.sp, FontWeight.Medium).copy(color = W.text), cursorBrush = SolidColor(W.lilac),
                keyboardOptions = KeyboardOptions(imeAction = if (onDone != null) ImeAction.Search else ImeAction.Done),
                keyboardActions = KeyboardActions(onSearch = { onDone?.invoke() }, onDone = { onDone?.invoke() }), modifier = Modifier.fillMaxWidth())
        }
        trailing?.invoke()
    }
}

@UnstableApi
@Composable
fun MiniPlayer(player: HybridPlayer, ui: HybridPlayer.Ui, open: () -> Unit) {
    val t = ui.current ?: return
    val progress by produceState(0f, t.key) { while (true) { if (Screen.on.value) value = player.durationMs().let { d -> if (d > 0) player.positionMs().toFloat() / d else 0f }; delay(1000) } }
    Column(Modifier.padding(start = 10.dp, end = 10.dp, top = 8.dp).glass(RoundedCornerShape(18.dp)).clickable(onClick = open)) {
        Row(Modifier.padding(start = 8.dp, end = 4.dp, top = 8.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Cover(t.art, Modifier.size(40.dp), RoundedCornerShape(8.dp))
            Column(Modifier.weight(1f).padding(horizontal = 10.dp)) {
                Text(t.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = W.ui(14.sp, FontWeight.SemiBold))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SourceTag(t.source)
                    Text("  ${t.artist}", maxLines = 1, overflow = TextOverflow.Ellipsis, style = W.ui(12.sp), color = W.text2)
                }
            }
            if (ui.buffering) CircularProgressIndicator(Modifier.padding(end = 8.dp).size(20.dp), strokeWidth = 2.dp, color = W.lilac)
            IconButton({ player.toggle() }) { Icon(if (ui.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Play/pause", tint = W.text) }
            IconButton({ player.seekToNext() }) { Icon(Icons.Filled.SkipNext, "Next", tint = W.text) }
        }
        // Progress: a hairline in the gradient
        Box(Modifier.fillMaxWidth().padding(horizontal = 14.dp).height(2.dp).background(W.hairline, CircleShape)) {
            Box(Modifier.fillMaxWidth(progress.coerceIn(0f, 1f)).fillMaxHeight().background(W.smart, CircleShape))
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
fun BottomSpace() = Spacer(Modifier.height(LocalBarHeight.current + 16.dp))

// MARK: - Home

@UnstableApi
@Composable
fun HomePage(player: HybridPlayer, openSettings: () -> Unit, openPlaylist: (String) -> Unit) {
    val c = LocalContext.current
    val lib = Library.get(c)
    val data by lib.data.collectAsState()
    val ui by player.ui.collectAsState()
    var local by remember { mutableStateOf<List<Track>>(emptyList()) }
    val updateVersion by Updates.available.collectAsState()
    LaunchedEffect(Unit) { Updates.check(c) }
    // Cookies may not be readable on the very first frame, so check again shortly.
    var signedIn by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        repeat(3) { signedIn = LoginActivity.signedIn(Service.YOUTUBE) && LoginActivity.signedIn(Service.SPOTIFY); delay(700) }
    }
    // The phone's songs: from memory after the first read; folders re-indexed at most twice a day (or "Rescan").
    var rescanTick by remember { mutableIntStateOf(0) }
    LaunchedEffect(rescanTick) {
        local = withContext(Dispatchers.IO) { runCatching { Local.cached(c) }.getOrDefault(emptyList()) }
        if (rescanTick == 0 && !Local.scanDue(c)) return@LaunchedEffect
        val scanned = kotlinx.coroutines.CompletableDeferred<Unit>()
        Local.rescan(c) { scanned.complete(Unit) }
        kotlinx.coroutines.withTimeoutOrNull(60_000) { scanned.await() }
        local = withContext(Dispatchers.IO) { runCatching { Local.refresh(c) }.getOrDefault(emptyList()) }
    }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Row(Modifier.fillMaxWidth().padding(20.dp, 14.dp, 14.dp, 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { Wordmark() }
                RoundButton(Icons.Filled.Tune, "Accounts & settings", onClick = openSettings)
            }
        }
        updateVersion?.let { v ->
            item {
                Row(Modifier.padding(16.dp, 12.dp, 16.dp, 0.dp).fillMaxWidth().smartGlass().clickable {
                    c.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(Updates.PAGE)))
                }.padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("WreckBox Player $v is out", style = W.ui(17.sp, FontWeight.Bold))
                        Text("You have ${BuildConfig.VERSION_NAME}. Tap to download the update.", style = W.ui(13.sp), color = W.text2)
                    }
                    Icon(Icons.Filled.SystemUpdate, null, Modifier.size(22.dp), tint = W.text)
                }
            }
        }
        if (!signedIn) item {
            Row(Modifier.padding(16.dp, 12.dp).fillMaxWidth().smartGlass().clickable(onClick = openSettings).padding(18.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Bring your music in", style = W.ui(17.sp, FontWeight.Bold))
                    Text("Sign in to YouTube Music and Spotify to play and search them here.", style = W.ui(13.sp), color = W.text2)
                }
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(20.dp), tint = W.text)
            }
        }
        // Pick up where you left off
        ui.current?.let { t ->
            item {
                Row(Modifier.padding(16.dp, 12.dp, 16.dp, 0.dp).fillMaxWidth().glass().padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                    Cover(t.art, Modifier.size(64.dp).iridescentRim(RoundedCornerShape(12.dp)), RoundedCornerShape(12.dp))
                    Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
                        DotLabel(if (ui.playing) "Now playing" else "Paused", color = W.lilac, size = 10.sp)
                        Text(t.title, style = W.ui(16.sp, FontWeight.Bold), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(t.artist, style = W.ui(13.sp), color = W.text2, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    CandyButton(48.dp, { player.toggle() }) {
                        Icon(if (ui.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Play/pause", tint = Color(0xFF0A0A0C), modifier = Modifier.size(26.dp))
                    }
                }
            }
        }
        if (data.likes.isNotEmpty()) {
            item { Section("Liked songs · ${data.likes.size}") }
            item { PlayShuffle({ player.playList(data.likes) }, { player.playList(data.likes, shuffled = true) }) }
            glassList(data.likes.take(10), "like") { i, t -> TrackRow(player, t, ui.current?.key == t.key, { player.playList(data.likes, i) }) }
        }
        if (data.playlists.isNotEmpty()) {
            item { Section("Your playlists") }
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(data.playlists, key = { it.id }) { p -> PlaylistTile(p, 138.dp) { openPlaylist(p.id) } }
                }
            }
        }
        if (data.recent.isNotEmpty()) {
            item { Section("Recently played", "Clear") { lib.clearRecent() } }
            glassList(data.recent.take(12), "recent") { _, t -> TrackRow(player, t, ui.current?.key == t.key, { player.playList(listOf(t)) }) }
        }
        if (local.isNotEmpty()) {
            item { Section("On this phone · ${local.size}", "Rescan") { rescanTick++ } }
            item { PlayShuffle({ player.playList(local) }, { player.playList(local, shuffled = true) }) }
            glassList(local.take(30), "local") { i, t -> TrackRow(player, t, ui.current?.key == t.key, { player.playList(local, i) }) }
        }
        item { BottomSpace() }
    }
}

@Composable
fun PlayShuffle(play: () -> Unit, shuffle: () -> Unit, enabled: Boolean = true) {
    Row(Modifier.padding(start = 16.dp, end = 16.dp, bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Pill("Play", Icons.Filled.PlayArrow, PillStyle.PRIMARY, enabled, play)
        Pill("Shuffle", Icons.Filled.Shuffle, PillStyle.GLASS, enabled, shuffle)
    }
}

@Composable
fun PlaylistTile(p: Playlist, size: Dp, open: () -> Unit) {
    Column(Modifier.width(size).clickable(onClick = open)) {
        Cover(p.tracks.firstOrNull()?.art, Modifier.size(size), RoundedCornerShape(W.Radius.tile))
        Text(p.name, maxLines = 1, overflow = TextOverflow.Ellipsis, style = W.ui(14.sp, FontWeight.SemiBold), modifier = Modifier.padding(top = 8.dp, start = 2.dp))
        Text(songs(p.tracks.size), style = W.ui(12.sp), color = W.text2, modifier = Modifier.padding(start = 2.dp))
    }
}

/** Accounts, background play, ads: a glass sheet. */
@OptIn(ExperimentalMaterial3Api::class)
@SuppressLint("BatteryLife")
@Composable
fun SettingsSheet(close: () -> Unit) {
    val c = LocalContext.current
    var tick by remember { mutableIntStateOf(0) }
    val login = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { tick++ }
    val prefs = c.getSharedPreferences("settings", Context.MODE_PRIVATE)
    var adblock by remember { mutableStateOf(prefs.getBoolean("adblock", true)) }
    var autoplay by remember { mutableStateOf(prefs.getBoolean("autoplay", true)) }
    ModalBottomSheet(close, containerColor = Color(0xF2121117), shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)) {
        key(tick) {
            Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
                DotLabel("Accounts", Modifier.padding(bottom = 10.dp))
                Service.entries.forEach { s ->
                    val on = LoginActivity.signedIn(s)
                    Row(Modifier.fillMaxWidth().padding(vertical = 5.dp).glass(RoundedCornerShape(18.dp)).padding(14.dp, 10.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(10.dp).background(if (on) s.source.tint else W.text3, CircleShape))
                        Column(Modifier.weight(1f).padding(start = 12.dp)) {
                            Text(if (s == Service.YOUTUBE) "YouTube Music" else "Spotify", style = W.ui(15.sp, FontWeight.SemiBold))
                            Text(if (on) "Signed in" else "Not signed in", style = W.ui(12.sp), color = W.text2)
                        }
                        if (on) TextButton({ LoginActivity.signOut(s); tick++ }) { Text("Sign out", color = W.text2) }
                        else Pill("Sign in", style = PillStyle.SMART) { login.launch(Intent(c, LoginActivity::class.java).putExtra("service", s.name)) }
                    }
                }
                DotLabel("WreckBox", Modifier.padding(top = 18.dp, bottom = 10.dp))
                WreckBoxLink()
                DotLabel("Playback", Modifier.padding(top = 18.dp, bottom = 10.dp))
                val pm = c.getSystemService(PowerManager::class.java)
                Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(14.dp, 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Keep playing with the screen off", style = W.ui(15.sp, FontWeight.SemiBold))
                        Text("Lets the phone run the player in the background", style = W.ui(12.sp), color = W.text2)
                    }
                    if (pm.isIgnoringBatteryOptimizations(c.packageName)) DotLabel("On", color = W.lilac)
                    else Pill("Allow") { c.startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${c.packageName}"))) }
                }
                Spacer(Modifier.height(10.dp))
                Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(14.dp, 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Autoplay similar songs", style = W.ui(15.sp, FontWeight.SemiBold))
                        Text("When the queue ends, keep going with music like it", style = W.ui(12.sp), color = W.text2)
                    }
                    Switch(autoplay, { autoplay = it; prefs.edit().putBoolean("autoplay", it).apply(); PlayerService.instance?.player?.autoplay = it },
                        colors = SwitchDefaults.colors(checkedTrackColor = W.lilac, checkedThumbColor = Color.White))
                }
                Spacer(Modifier.height(10.dp))
                Row(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(14.dp, 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Block ads", style = W.ui(15.sp, FontWeight.SemiBold))
                        Text("Skips YouTube ads and blocks ad servers", style = W.ui(12.sp), color = W.text2)
                    }
                    Switch(adblock, { adblock = it; AdBlock.enabled = it; prefs.edit().putBoolean("adblock", it).apply() },
                        colors = SwitchDefaults.colors(checkedTrackColor = W.lilac, checkedThumbColor = Color.White))
                }
            }
        }
    }
}

/** Settings → WreckBox: link with a code, then playlists sync by themselves. */
@Composable
fun WreckBoxLink() {
    val s by Sync.state.collectAsState()
    Column(Modifier.fillMaxWidth().glass(RoundedCornerShape(18.dp)).padding(14.dp)) {
        when {
            s.linked -> {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(10.dp).background(W.lilac, CircleShape))
                    Column(Modifier.weight(1f).padding(start = 12.dp)) {
                        Text("Linked to WreckBox", style = W.ui(15.sp, FontWeight.SemiBold))
                        Text(s.email + (if (s.lastSync > 0) " · synced ${android.text.format.DateUtils.getRelativeTimeSpanString(s.lastSync)}" else ""),
                            style = W.ui(12.sp), color = W.text2)
                    }
                }
                Text("Your playlists and likes go to WreckBox, which downloads their songs in FLAC on your computer.",
                    Modifier.padding(top = 8.dp), style = W.ui(12.sp), color = W.text3)
                Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Pill("Sync now", Icons.Filled.Sync, PillStyle.SMART) { Sync.push() }
                    Pill("Unlink") { Sync.unlink() }
                }
            }
            s.code != null -> {
                Text("Enter this code in WreckBox", style = W.ui(15.sp, FontWeight.SemiBold))
                Lcd(Modifier.fillMaxWidth().padding(vertical = 10.dp)) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { LcdText(s.code!!, size = 30.sp) }
                }
                Text("On your Mac: WreckBox → Add playlist → WreckBox Player → type the code. Waiting…",
                    style = W.ui(12.sp), color = W.text2)
                Row(Modifier.padding(top = 10.dp)) { Pill("Cancel") { Sync.cancelLinking() } }
            }
            else -> {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Link to WreckBox", style = W.ui(15.sp, FontWeight.SemiBold))
                        Text("Download your playlists in FLAC with the WreckBox app", style = W.ui(12.sp), color = W.text2)
                    }
                    Pill("Link", style = PillStyle.SMART) { Sync.startLinking() }
                }
            }
        }
        s.error?.let { Text(it, Modifier.padding(top = 8.dp), style = W.ui(12.sp), color = W.peach) }
    }
}

// MARK: - Search

@UnstableApi
@Composable
fun SearchPage(player: HybridPlayer) {
    val c = LocalContext.current
    val ui by player.ui.collectAsState()
    // Kept outside the page so switching tabs doesn't wipe the search.
    var q by SearchMemory.query
    var results by SearchMemory.results
    var busy by remember { mutableStateOf(false) }
    var searched by SearchMemory.searched
    var filter by SearchMemory.filter
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    val scope = rememberCoroutineScope()
    fun run() {
        val query = q.trim()
        if (query.isEmpty()) return
        busy = true
        searched = query
        keyboard?.hide()
        focus.clearFocus()
        scope.launch {
            val found = Search.all(c, query)
            results = found.tracks
            SearchMemory.failed.value = found.failed
            busy = false
            keyboard?.hide() // also after a hardware Enter, where the first hide can come too early
        }
    }
    val shown = results.filter { filter == null || it.source == filter }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Text("Search", style = W.ui(30.sp, FontWeight.Bold), modifier = Modifier.padding(20.dp, 14.dp, 20.dp, 12.dp))
            GlassField(q, { q = it }, "Song, artist or a line from the lyrics", Modifier.padding(horizontal = 16.dp), Icons.Filled.Search,
                trailing = { if (q.isNotEmpty()) IconButton({ q = ""; results = emptyList(); searched = ""; SearchMemory.failed.value = emptyList() }) { Icon(Icons.Filled.Close, "Clear", tint = W.text3) } },
                onDone = ::run)
            if (busy) LinearProgressIndicator(Modifier.padding(horizontal = 32.dp, vertical = 8.dp).fillMaxWidth().height(2.dp).clip(CircleShape), color = W.lilac, trackColor = W.hairline)
            if (results.isNotEmpty()) Row(Modifier.padding(16.dp, 12.dp, 16.dp, 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip("All", filter == null, results.size) { filter = null }
                Source.entries.forEach { s -> results.count { it.source == s }.takeIf { it > 0 }?.let { n -> Chip(s.label, filter == s, n) { filter = s } } }
            }
            if (!busy && searched.isNotEmpty() && SearchMemory.failed.value.isNotEmpty())
                Text("Couldn't reach ${SearchMemory.failed.value.joinToString(" or ")} — check your connection or sign-in.", Modifier.padding(20.dp, 6.dp), color = W.text2, style = W.ui(12.sp))
            if (!busy && searched.isNotEmpty() && results.isEmpty()) Text("Nothing found for “$searched”.", Modifier.padding(20.dp), color = W.text2, style = W.ui(14.sp))
            if (searched.isEmpty()) Column(Modifier.fillMaxWidth().padding(top = 60.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                DotSpectrum(false, cols = 7, rows = 5, dot = 6.dp, gap = 3.dp)
                Text("Phone, YouTube Music and Spotify — all at once", Modifier.padding(top = 16.dp), style = W.ui(13.sp), color = W.text3)
            }
            Spacer(Modifier.height(6.dp))
        }
        glassList(shown, "r") { _, t -> TrackRow(player, t, ui.current?.key == t.key, { player.playList(listOf(t)) }) }
        item { BottomSpace() }
    }
}

// MARK: - Playlists

@Composable
fun PlaylistsPage(open: (String) -> Unit) {
    val lib = Library.get(LocalContext.current)
    val data by lib.data.collectAsState()
    var create by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Row(Modifier.fillMaxWidth().padding(20.dp, 14.dp, 16.dp, 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Playlists", style = W.ui(30.sp, FontWeight.Bold), modifier = Modifier.weight(1f))
                Pill("New", Icons.Filled.Add, PillStyle.PRIMARY) { create = true }
            }
            Row(Modifier.padding(16.dp, 4.dp, 16.dp, 8.dp).fillMaxWidth().smartGlass(RoundedCornerShape(18.dp)).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Sync, null, tint = W.text, modifier = Modifier.size(20.dp))
                val sync by Sync.state.collectAsState()
                Text(if (sync.linked) "Saved on this phone and synced to WreckBox (${sync.email}) — your computer downloads them in FLAC."
                    else "Saved on this phone. Link WreckBox in ⚙ to download them in FLAC on your computer.",
                    Modifier.padding(start = 12.dp), style = W.ui(12.5.sp), color = W.text2)
            }
        }
        if (data.playlists.isEmpty()) item { Text("No playlists yet. Make one, or add songs from Search with ⋮.", Modifier.padding(20.dp), color = W.text2, style = W.ui(14.sp)) }
        // Two tiles a row
        items(data.playlists.chunked(2), key = { it.first().id }) { pair ->
            Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                BoxWithConstraints(Modifier.weight(1f)) { PlaylistTile(pair[0], maxWidth) { open(pair[0].id) } }
                BoxWithConstraints(Modifier.weight(1f)) { pair.getOrNull(1)?.let { p -> PlaylistTile(p, maxWidth) { open(p.id) } } }
            }
        }
        item { BottomSpace() }
    }
    if (create) AlertDialog(
        modifier = Modifier.padding(horizontal = 28.dp), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        onDismissRequest = { create = false }, containerColor = Color(0xF2141219), shape = RoundedCornerShape(W.Radius.card),
        title = { Text("New playlist", style = W.ui(20.sp, FontWeight.Bold)) },
        text = { GlassField(name, { name = it }, "Name") },
        confirmButton = { TextButton({ val p = lib.createPlaylist(name); name = ""; create = false; open(p.id) }) { Text("Create", color = W.lilac) } },
        dismissButton = { TextButton({ create = false }) { Text("Cancel", color = W.text2) } },
    )
}

@UnstableApi
@Composable
fun PlaylistPage(player: HybridPlayer, id: String, back: () -> Unit) {
    val lib = Library.get(LocalContext.current)
    val data by lib.data.collectAsState()
    val ui by player.ui.collectAsState()
    val p = data.playlists.firstOrNull { it.id == id } ?: return back()
    var rename by remember { mutableStateOf(false) }
    var delete by remember { mutableStateOf(false) }
    var name by remember(p.id) { mutableStateOf(p.name) }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Row(Modifier.padding(12.dp, 8.dp), verticalAlignment = Alignment.CenterVertically) {
                RoundButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", onClick = back)
                Spacer(Modifier.weight(1f))
                RoundButton(Icons.Filled.Edit, "Rename") { rename = true }
                Spacer(Modifier.width(8.dp))
                RoundButton(Icons.Filled.Delete, "Delete") { delete = true }
            }
            Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Cover(p.tracks.firstOrNull()?.art, Modifier.size(190.dp).shadow(24.dp, RoundedCornerShape(W.Radius.card)).iridescentRim(RoundedCornerShape(W.Radius.card)), RoundedCornerShape(W.Radius.card))
                Text(p.name, style = W.ui(26.sp, FontWeight.Bold), modifier = Modifier.padding(top = 16.dp, start = 20.dp, end = 20.dp), maxLines = 2)
                DotLabel(songs(p.tracks.size), Modifier.padding(top = 4.dp, bottom = 14.dp))
            }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                PlayShuffle({ player.playList(p.tracks) }, { player.playList(p.tracks, shuffled = true) }, p.tracks.isNotEmpty())
            }
        }
        if (p.tracks.isEmpty()) item { Text("Empty. Add songs from Search or Home with ⋮ → Add to playlist.", Modifier.padding(20.dp, 8.dp), color = W.text2, style = W.ui(14.sp)) }
        glassList(p.tracks, "pl") { i, t ->
            TrackRow(player, t, ui.current?.key == t.key, { player.playList(p.tracks, i) }) { close ->
                DropdownMenuItem({ Text("Move up") }, { lib.moveInPlaylist(p.id, i, i - 1); close() })
                DropdownMenuItem({ Text("Move down") }, { lib.moveInPlaylist(p.id, i, i + 1); close() })
                DropdownMenuItem({ Text("Remove from playlist") }, { lib.removeFromPlaylist(p.id, i); close() })
            }
        }
        item { BottomSpace() }
    }
    if (rename) AlertDialog(
        modifier = Modifier.padding(horizontal = 28.dp), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        onDismissRequest = { rename = false }, containerColor = Color(0xF2141219), shape = RoundedCornerShape(W.Radius.card),
        title = { Text("Rename", style = W.ui(20.sp, FontWeight.Bold)) },
        text = { GlassField(name, { name = it }, "Name") },
        confirmButton = { TextButton({ lib.renamePlaylist(p.id, name); rename = false }) { Text("Save", color = W.lilac) } },
        dismissButton = { TextButton({ rename = false; name = p.name }) { Text("Cancel", color = W.text2) } },
    )
    if (delete) AlertDialog(
        modifier = Modifier.padding(horizontal = 28.dp), properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
        onDismissRequest = { delete = false }, containerColor = Color(0xF2141219), shape = RoundedCornerShape(W.Radius.card),
        title = { Text("Delete “${p.name}”?", style = W.ui(20.sp, FontWeight.Bold)) },
        confirmButton = { TextButton({ delete = false; lib.deletePlaylist(p.id); back() }) { Text("Delete", color = W.peach) } },
        dismissButton = { TextButton({ delete = false }) { Text("Cancel", color = W.text2) } },
    )
}

// MARK: - Now playing

@UnstableApi
@Composable
fun NowPlayingPage(player: HybridPlayer, ui: HybridPlayer.Ui) {
    val lib = Library.get(LocalContext.current)
    val data by lib.data.collectAsState()
    val t = ui.current
    if (t == null) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            PixelRecord(Modifier.size(72.dp))
            Text("Nothing playing", style = W.ui(18.sp, FontWeight.Bold), modifier = Modifier.padding(top = 16.dp))
            Text("Find something in Search.", style = W.ui(14.sp), color = W.text2)
        }
        return
    }
    var pos by remember { mutableLongStateOf(0L) }
    var dur by remember { mutableLongStateOf(0L) }
    var dragging by remember { mutableStateOf<Float?>(null) }
    var pick by remember { mutableStateOf(false) }
    var eq by remember { mutableStateOf(false) }
    // Twice a second is enough for a clock in seconds and the seek bar (each update redraws the page).
    LaunchedEffect(t.key) { while (true) { if (Screen.on.value) { pos = player.positionMs(); dur = player.durationMs() }; delay(500) } }
    val liked = data.likes.any { it.key == t.key }
    val eqState by Eq.state.collectAsState()
    // A phone file resumed after a restart hasn't been read yet: read its format here.
    val c = LocalContext.current
    var fileQuality by remember(t.key) { mutableStateOf(Quality.cached(t)) }
    if (t.source == Source.LOCAL && fileQuality == null) LaunchedEffect(t.key) { fileQuality = withContext(Dispatchers.IO) { Quality.of(c, t) } }
    LazyColumn(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        item {
            val landscape = androidx.compose.ui.platform.LocalConfiguration.current.orientation == android.content.res.Configuration.ORIENTATION_LANDSCAPE
            val shape = RoundedCornerShape(W.Radius.card)
            // Sideways the screen is short: a small cover keeps the controls in reach.
            Cover(t.art, (if (landscape) Modifier.padding(top = 12.dp).size(150.dp) else Modifier.padding(top = 20.dp).widthIn(max = 400.dp).fillMaxWidth(0.84f).aspectRatio(1f))
                .shadow(32.dp, shape, ambientColor = W.lilac, spotColor = W.lilac).iridescentRim(shape), shape)
            Column(Modifier.fillMaxWidth().padding(22.dp, 22.dp, 22.dp, 0.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(t.title, style = W.ui(24.sp, FontWeight.Bold), maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(t.artist, style = W.ui(16.sp), color = W.text2, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    IconButton({ lib.toggleLike(t) }) {
                        Icon(if (liked) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, "Like", tint = if (liked) W.peach else W.text)
                    }
                    IconButton({ pick = true }) { Icon(Icons.AutoMirrored.Filled.PlaylistAdd, "Add to playlist", tint = W.text) }
                }
                // The LCD: clock, track counter, source and format
                Lcd(Modifier.fillMaxWidth().padding(top = 16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        LcdText(lcdTime(dragging?.let { (it * dur).toLong() } ?: pos), ghost = "88:88")
                        Text("  / ${lcdTime(dur)}", style = W.dot(13.sp), color = W.peach.copy(alpha = 0.5f))
                        Spacer(Modifier.weight(1f))
                        DotSpectrum(ui.playing, cols = 8, rows = 5, dot = 3.5.dp, gap = 1.5.dp)
                    }
                    Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("TRK %03d/%03d".format(ui.index + 1, ui.queue.size), style = W.dot(10.sp), color = W.lilac, letterSpacing = 1.sp)
                        Spacer(Modifier.weight(1f))
                        LcdBadge(when (t.source) { Source.LOCAL -> "PHONE"; Source.YOUTUBE -> "YT MUSIC"; Source.SPOTIFY -> "SPOTIFY" })
                        if (ui.shuffle) LcdBadge("SHUF")
                        if (ui.repeat != Player.REPEAT_MODE_OFF) LcdBadge(if (ui.repeat == Player.REPEAT_MODE_ONE) "RPT 1" else "RPT")
                    }
                    Text(ui.quality ?: fileQuality ?: if (t.source == Source.SPOTIFY) "Spotify stream" else "—", Modifier.padding(top = 6.dp),
                        style = W.dot(11.sp), color = W.blue.copy(alpha = 0.9f), letterSpacing = 0.8.sp, maxLines = 1)
                }
                SeekBar(dragging ?: if (dur > 0) (pos.toFloat() / dur).coerceIn(0f, 1f) else 0f, { dragging = it }) {
                    dragging?.let { player.seekMs((it * dur).toLong()) }; dragging = null
                }
                Row(Modifier.fillMaxWidth().padding(top = 6.dp), horizontalArrangement = Arrangement.SpaceEvenly, verticalAlignment = Alignment.CenterVertically) {
                    IconButton({ player.setShuffle(!ui.shuffle) }) { Icon(Icons.Filled.Shuffle, "Shuffle", tint = if (ui.shuffle) W.lilac else W.text3) }
                    IconButton({ player.seekToPrevious() }, Modifier.size(58.dp)) { Icon(Icons.Filled.SkipPrevious, "Previous", Modifier.size(38.dp), tint = W.text) }
                    CandyButton(76.dp, { player.toggle() }) {
                        if (ui.buffering) CircularProgressIndicator(Modifier.size(28.dp), strokeWidth = 3.dp, color = Color(0xFF0A0A0C))
                        else Icon(if (ui.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, "Play/pause", Modifier.size(40.dp), tint = Color(0xFF0A0A0C))
                    }
                    IconButton({ player.seekToNext() }, Modifier.size(58.dp)) { Icon(Icons.Filled.SkipNext, "Next", Modifier.size(38.dp), tint = W.text) }
                    IconButton({ player.cycleRepeat() }) {
                        Icon(if (ui.repeat == Player.REPEAT_MODE_ONE) Icons.Filled.RepeatOne else Icons.Filled.Repeat, "Repeat",
                            tint = if (ui.repeat == Player.REPEAT_MODE_OFF) W.text3 else W.lilac)
                    }
                }
                Row(Modifier.fillMaxWidth().padding(top = 10.dp), horizontalArrangement = Arrangement.Center) {
                    val shaped = eqState.on && eqState.preset != "Flat"
                    Pill(if (shaped) "EQ · ${eqState.preset}" else "Equaliser", Icons.Filled.Equalizer, if (shaped) PillStyle.SMART else PillStyle.GLASS) { eq = true }
                }
            }
        }
        // Up next: what you queued, then what autoplay added (similar songs), each in its own card.
        val upcoming = ui.queue.withIndex().filter { it.index > ui.index }
        val (auto, mine) = upcoming.partition { it.value.key in ui.radio }
        item { Section("Up next") }
        if (upcoming.isEmpty() && !ui.radioLoading) item {
            Text(if (player.autoplay) "Nothing after this song." else "Nothing after this song — Autoplay is off (Settings).",
                Modifier.padding(horizontal = 20.dp), style = W.ui(13.sp), color = W.text3)
        }
        queueCard(player, mine, "q")
        if (auto.isNotEmpty() || ui.radioLoading) {
            item { Section("Autoplay · similar to ${ui.radioFrom ?: ui.current?.title ?: ""}", if (auto.isNotEmpty()) "Clear" else null) { player.clearAutoplay() } }
            if (ui.radioLoading && auto.isEmpty()) item {
                Row(Modifier.padding(horizontal = 20.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = W.lilac)
                    Text("Finding similar songs…", Modifier.padding(start = 10.dp), style = W.ui(13.sp), color = W.text2)
                }
            }
            queueCard(player, auto, "a")
        }
        item { BottomSpace() }
    }
    if (pick) AddToPlaylistDialog(t) { pick = false }
    if (eq) EqSheet(t.source) { eq = false }
}

/** Songs of the queue in a glass card: tap to jump, swipe to remove, ⋮ to move. */
@UnstableApi
fun LazyListScope.queueCard(player: HybridPlayer, list: List<IndexedValue<Track>>, key: String) = glassList(list.map { it.value }, key) { n, q ->
    val i = list[n].index
    TrackRow(player, q, false, { player.jumpTo(i) }, onRemove = { player.removeAt(i) }) { close ->
        DropdownMenuItem({ Text("Move up") }, { player.move(i, i - 1); close() })
        DropdownMenuItem({ Text("Move down") }, { player.move(i, i + 1); close() })
        DropdownMenuItem({ Text("Remove from queue") }, { player.removeAt(i); close() })
    }
}

fun lcdTime(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    return "%02d:%02d".format(s / 60 % 100, s % 60)
}

/** The seek bar: a hairline track, the gradient for what's played, a white knob. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SeekBar(value: Float, onChange: (Float) -> Unit, onDone: () -> Unit) {
    Slider(
        value, onChange, Modifier.padding(top = 6.dp), onValueChangeFinished = onDone,
        thumb = { Box(Modifier.size(16.dp).shadow(6.dp, CircleShape).background(Color.White, CircleShape)) },
        track = { st ->
            Box(Modifier.fillMaxWidth().height(4.dp).background(W.hairline, CircleShape)) {
                Box(Modifier.fillMaxWidth(st.value.coerceIn(0f, 1f)).fillMaxHeight().background(W.smart, CircleShape))
            }
        },
    )
}

/** The EQ: the dot curve (drag to shape it), on/off, presets. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun EqSheet(source: Source, close: () -> Unit) {
    val s by Eq.state.collectAsState()
    ModalBottomSheet(close, containerColor = Color(0xF2121117), shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 28.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Equaliser", style = W.ui(22.sp, FontWeight.Bold), modifier = Modifier.weight(1f))
                Switch(s.on, { Eq.setOn(it) }, colors = SwitchDefaults.colors(checkedTrackColor = W.lilac, checkedThumbColor = Color.White))
            }
            Lcd(Modifier.fillMaxWidth().padding(top = 12.dp)) {
                Row {
                    DotLabel("10-band", color = W.text3)
                    Spacer(Modifier.weight(1f))
                    Text(if (s.on) s.preset else "Off", style = W.ui(12.sp, FontWeight.SemiBold), color = if (s.on) W.lilac else W.text3)
                }
                EqDots(s.gains, s.on, Modifier.fillMaxWidth().height(150.dp).padding(vertical = 10.dp)) { band, db -> Eq.setBand(band, db) }
                Row { Eq.labels.forEach { Text(it, Modifier.weight(1f), style = W.dot(9.sp), color = W.text3, textAlign = TextAlign.Center) } }
            }
            DotLabel("Presets", Modifier.padding(top = 16.dp, bottom = 8.dp))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Eq.presets.keys.forEach { name -> Chip(name, s.on && s.preset == name) { Eq.choose(name) } }
            }
            Text(
                if (source == Source.SPOTIFY) "Spotify's audio is protected, so the EQ can't reach it — it applies to phone files and YouTube Music."
                else "Applies to phone files and YouTube Music. Spotify's protected audio plays as it is.",
                Modifier.padding(top = 14.dp), style = W.ui(12.sp), color = W.text3,
            )
        }
    }
}
