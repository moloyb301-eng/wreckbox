package local.wreckbox.player

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.util.UnstableApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Home: a greeting, four quick-play tiles, then recommendations (HomeFeed: your mixes, because you played…, your
 * YouTube Music home, new releases from your artists, rediscover, charts, moods), then your own music (liked songs,
 * playlists, recently played, the phone's songs).
 */
@UnstableApi
@Composable
fun HomePage(player: HybridPlayer, openSettings: () -> Unit, openPlaylist: (String) -> Unit) {
    val c = LocalContext.current
    val lib = Library.get(c)
    val data by lib.data.collectAsState()
    val ui by player.ui.collectAsState()
    val parts by HomeFeed.parts.collectAsState()
    val loading by HomeFeed.loading.collectAsState()
    var local by remember { mutableStateOf<List<Track>>(emptyList()) }
    val updateVersion by Updates.available.collectAsState()
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { Updates.check(c) }
    // Cookies may not be readable on the very first frame, so check again shortly.
    var signedIn by remember { mutableStateOf(true) }
    LaunchedEffect(Unit) {
        repeat(3) { signedIn = LoginActivity.signedIn(Service.YOUTUBE) && LoginActivity.signedIn(Service.SPOTIFY); delay(700) }
    }
    // Recommendations: last ones at once (saved), then fresh ones — after reading the services' history (twice a day).
    LaunchedEffect(Unit) {
        HomeFeed.load(c)
        launch { HomeFeed.refresh(c) }
        // New history from the services (a minute at most): rebuild the recommendations with it.
        if (Import.auto(c) > 0) { while (HomeFeed.loading.value) delay(1000); HomeFeed.refresh(c, force = true) }
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
    val mixes = parts["mixes"].orEmpty().flatMap { it.items }.filterIsInstance<Item.Mix>()
    val everything = remember(data.likes, local) { (data.likes + local).distinctBy { Radio.name(it) } }
    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Row(Modifier.fillMaxWidth().padding(20.dp, 14.dp, 14.dp, 0.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { Wordmark() }
                RoundButton(Icons.Filled.Tune, "Accounts & settings", onClick = openSettings)
            }
            // In the wordmark's lettering: Doto, black weight, the app's gradient.
            Text(greeting().uppercase(), Modifier.padding(20.dp, 16.dp, 20.dp, 0.dp), style = W.dot(26.sp, FontWeight.Black).copy(brush = W.smart), letterSpacing = 1.5.sp)
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
                    Text("Sign in to YouTube Music and Spotify to play and search them here — and to bring your listening history in.", style = W.ui(13.sp), color = W.text2)
                }
                Icon(Icons.AutoMirrored.Filled.ArrowForward, null, Modifier.size(20.dp), tint = W.text)
            }
        }
        // Quick play: four big tiles
        item {
            val all = everything
            val tiles = buildList {
                if (data.likes.isNotEmpty()) add(Quick("Liked songs", songs(data.likes.size), Icons.Filled.Favorite, data.likes.firstOrNull()?.art) { player.playList(data.likes, shuffled = true) })
                if (all.isNotEmpty()) add(Quick("Shuffle all", songs(all.size), Icons.Filled.Shuffle, null) { player.playList(all, shuffled = true) })
                ui.current?.let { t -> add(Quick(if (ui.playing) "Now playing" else "Continue", t.title, if (ui.playing) Icons.Filled.Pause else Icons.Filled.PlayArrow, t.art) { player.toggle() }) }
                mixes.firstOrNull()?.let { m -> add(Quick(m.title, "Your mix", Icons.Filled.AutoAwesome, m.art) { Nav.open(Detail.Mix(m)) }) }
                data.playlists.maxByOrNull { it.updatedAt }?.let { p -> add(Quick(p.name, songs(p.tracks.size), Icons.Filled.QueueMusic, p.tracks.firstOrNull()?.art) { openPlaylist(p.id) }) }
                if (local.isNotEmpty()) add(Quick("On this phone", songs(local.size), Icons.Filled.PhoneAndroid, null) { player.playList(local, shuffled = true) })
            }.take(4)
            if (tiles.isNotEmpty()) Column(Modifier.padding(16.dp, 14.dp, 16.dp, 0.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                tiles.chunked(2).forEach { row ->
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        row.forEach { q -> QuickTile(q, Modifier.weight(1f)) }
                        if (row.size == 1) Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
        if (loading && parts.isEmpty()) item {
            LinearProgressIndicator(Modifier.padding(horizontal = 32.dp, vertical = 20.dp).fillMaxWidth().height(2.dp).clip(RoundedCornerShape(1.dp)), color = W.lilac, trackColor = W.hairline)
        }
        // Recommendations, in this order
        val order = listOf("mixes", "because", "feed", "fresh", "rediscover", "charts")
        order.forEach { k ->
            parts[k].orEmpty().forEachIndexed { i, shelf ->
                item(key = "$k$i") {
                    if (k == "mixes" && i == 0) ShelfRow(player, shelf, if (loading) "Updating…" else "Refresh") { scope.launch { HomeFeed.refresh(c, force = true) } }
                    else ShelfRow(player, shelf)
                }
            }
        }
        if (data.likes.isNotEmpty()) {
            item { Section("Liked songs · ${data.likes.size}") }
            item { PlayShuffle({ player.playList(data.likes) }, { player.playList(data.likes, shuffled = true) }) }
            glassList(data.likes.take(5), "like") { i, t -> TrackRow(player, t, ui.current?.key == t.key, { player.playList(data.likes, i) }) }
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
            item {
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(data.recent.take(15), key = { it.key }) { t -> ItemTile(Item.Song(t, t.artist), 120.dp) { player.playList(listOf(t)) } }
                }
            }
        }
        parts["moods"].orEmpty().forEachIndexed { i, shelf -> item(key = "moods$i") { ShelfRow(player, shelf) } }
        if (local.isNotEmpty()) {
            item { Section("On this phone · ${local.size}", "Rescan") { rescanTick++ } }
            item { PlayShuffle({ player.playList(local) }, { player.playList(local, shuffled = true) }) }
            glassList(local.take(10), "local") { i, t -> TrackRow(player, t, ui.current?.key == t.key, { player.playList(local, i) }) }
        }
        item { BottomSpace() }
    }
}

private fun greeting() = when (java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)) {
    in 5..11 -> "Good morning"; in 12..16 -> "Good afternoon"; in 17..21 -> "Good evening"; else -> "Up late?"
}

private class Quick(val title: String, val subtitle: String, val icon: ImageVector, val art: String?, val onClick: () -> Unit)

@Composable
private fun QuickTile(q: Quick, modifier: Modifier) {
    Row(modifier.height(58.dp).clip(RoundedCornerShape(14.dp)).glass(RoundedCornerShape(14.dp)).clickable(onClick = q.onClick), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(58.dp), contentAlignment = Alignment.Center) {
            if (q.art != null) Cover(q.art, Modifier.matchParentSize(), RoundedCornerShape(0.dp), q.title)
            else Box(Modifier.matchParentSize().background(androidx.compose.ui.graphics.Brush.linearGradient(listOf(W.lilac.copy(alpha = 0.5f), W.blue.copy(alpha = 0.25f)))))
            Box(Modifier.size(26.dp).background(Color.Black.copy(alpha = 0.45f), RoundedCornerShape(13.dp)), contentAlignment = Alignment.Center) {
                Icon(q.icon, null, Modifier.size(15.dp), tint = Color.White)
            }
        }
        Column(Modifier.padding(horizontal = 10.dp)) {
            Text(q.title, style = W.ui(13.5.sp, FontWeight.Bold), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(q.subtitle, style = W.ui(11.5.sp), color = W.text2, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
