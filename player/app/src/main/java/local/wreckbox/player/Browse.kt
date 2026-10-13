package local.wreckbox.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Radio
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.util.UnstableApi
import kotlinx.coroutines.launch

/** Pages opened from Home or Search (an artist, an album or playlist, a mix, a mood), stacked over the tab; Back pops. */
sealed class Detail {
    data class Artist(val id: String, val name: String) : Detail()
    data class Collection(val id: String, val title: String) : Detail()
    data class Mix(val mix: Item.Mix) : Detail()
    data class Browse(val id: String, val params: String, val title: String) : Detail()
}

object Nav {
    val stack = mutableStateListOf<Detail>()
    fun open(d: Detail) { stack += d }
    fun back() { if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex) }
    fun clear() = stack.clear()

    /** What tapping an item does: songs play (with the rest of their row after them), pages open. */
    @UnstableApi
    fun tap(player: HybridPlayer, item: Item, row: List<Item>) {
        when (item) {
            is Item.Song -> {
                val songs = row.filterIsInstance<Item.Song>().map { it.track }
                player.playList(songs, songs.indexOfFirst { it.key == item.track.key }.coerceAtLeast(0))
            }
            is Item.Album -> open(Detail.Collection(item.id, item.title))
            is Item.Playlist -> open(Detail.Collection(item.id, item.title))
            is Item.Artist -> open(Detail.Artist(item.id, item.title))
            is Item.Mix -> open(Detail.Mix(item))
            is Item.Mood -> open(Detail.Browse(item.id, item.params, item.title))
        }
    }
}

@UnstableApi
@Composable
fun DetailPage(player: HybridPlayer, d: Detail) {
    when (d) {
        is Detail.Artist -> ArtistScreen(player, d.id, d.name)
        is Detail.Collection -> CollectionScreen(player, d.id, d.title)
        is Detail.Mix -> TrackListScreen(player, d.mix.title, d.mix.subtitle, d.mix.arts.firstOrNull(), d.mix.tracks, mosaic = d.mix.arts)
        is Detail.Browse -> BrowseScreen(player, d.id, d.params, d.title)
    }
}

// MARK: tiles and rows

/** A row of tiles under a section header. */
@UnstableApi
@Composable
fun ShelfRow(player: HybridPlayer, shelf: Shelf, action: String? = null, onAction: (() -> Unit)? = null) {
    if (shelf.items.isEmpty()) return
    Section(shelf.title, action, onAction)
    if (shelf.subtitle.isNotEmpty()) Text(shelf.subtitle, Modifier.padding(start = 20.dp, bottom = 8.dp).offset(y = (-4).dp), style = W.ui(12.sp), color = W.text3)
    if (shelf.items.all { it is Item.Mood }) {
        MoodGrid(player, shelf.items.filterIsInstance<Item.Mood>())
        return
    }
    LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        itemsIndexed(shelf.items, key = { i, it -> "$i${it.title}${(it as? Item.Song)?.track?.key ?: ""}" }) { _, item ->
            ItemTile(item, if (item is Item.Mix) 156.dp else 136.dp) { Nav.tap(player, item, shelf.items) }
        }
    }
}

@Composable
fun ItemTile(item: Item, size: Dp, onClick: () -> Unit) {
    Column(Modifier.width(size).clip(RoundedCornerShape(W.Radius.row)).clickable(onClick = onClick)) {
        when (item) {
            is Item.Artist -> Cover(item.art, Modifier.size(size).vcrGlass(CircleShape, 0.18f, bezel = true), CircleShape, item.title)
            is Item.Mix -> Mosaic(item.arts, item.title, size)
            is Item.Playlist -> PlaylistCover(item.art, item.title, size)
            else -> Cover(item.art, Modifier.size(size).vcrGlass(RoundedCornerShape(W.Radius.tile), 0.18f, bezel = true), RoundedCornerShape(W.Radius.tile), item.title)
        }
        Text(item.title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = W.ui(14.sp, FontWeight.SemiBold),
            modifier = Modifier.padding(top = 8.dp, start = 2.dp).then(if (item is Item.Artist) Modifier.fillMaxWidth() else Modifier),
            textAlign = if (item is Item.Artist) androidx.compose.ui.text.style.TextAlign.Center else null)
        val sub = when (item) {
            is Item.Song -> item.track.artist
            is Item.Artist -> "Artist"
            is Item.Mix -> item.subtitle
            else -> item.subtitle
        }
        if (sub.isNotEmpty()) Text(sub, maxLines = if (item is Item.Mix) 2 else 1, overflow = TextOverflow.Ellipsis, style = W.ui(12.sp), color = W.text2,
            modifier = Modifier.padding(start = 2.dp).then(if (item is Item.Artist) Modifier.fillMaxWidth() else Modifier),
            textAlign = if (item is Item.Artist) androidx.compose.ui.text.style.TextAlign.Center else null)
    }
}

/** A mix's tile: four covers in a square, with the mix's name over a gradient. */
@Composable
fun Mosaic(arts: List<String>, title: String, size: Dp) {
    Box(Modifier.size(size).vcrGlass(RoundedCornerShape(W.Radius.tile), 0.2f, bezel = true)) {
        if (arts.size >= 4) Column {
            Row { Cover(arts[0], Modifier.size(size / 2), RoundedCornerShape(0.dp)); Cover(arts[1], Modifier.size(size / 2), RoundedCornerShape(0.dp)) }
            Row { Cover(arts[2], Modifier.size(size / 2), RoundedCornerShape(0.dp)); Cover(arts[3], Modifier.size(size / 2), RoundedCornerShape(0.dp)) }
        } else Cover(arts.firstOrNull(), Modifier.size(size), RoundedCornerShape(0.dp), title)
        Box(Modifier.matchParentSize().background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f)))))
        Text(title.removeSuffix(" Mix").removeSuffix(" mix").uppercase(), Modifier.align(Alignment.BottomStart).padding(10.dp),
            style = W.dot((size.value * 0.105f).sp, FontWeight.Black).copy(shadow = androidx.compose.ui.graphics.Shadow(W.peach.copy(alpha = 0.55f), blurRadius = 10f)),
            color = Color.White, letterSpacing = 1.sp, lineHeight = (size.value * 0.12f).sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
        DotLabel("Mix", Modifier.align(Alignment.TopStart).padding(10.dp).background(Color.Black.copy(alpha = 0.45f), CircleShape).padding(horizontal = 7.dp, vertical = 2.dp),
            color = W.lilac, size = 9.sp)
    }
}

/**
 * A playlist's cover, ours rather than the service's: its picture zoomed, blurred and washed to near-greyscale under the app's colours
 * (picked by the name), scanlines and the glass, and the name set in the WreckBox lettering (Doto) — the way YouTube
 * Music titles its own playlist covers. Small sizes leave the name off.
 */
@Composable
fun PlaylistCover(art: String?, name: String, size: Dp, shape: androidx.compose.ui.graphics.Shape = RoundedCornerShape(W.Radius.tile), showName: Boolean = size >= 90.dp) {
    val h = name.hashCode()
    val a = W.smartColors[Math.floorMod(h, 3)]
    val b = W.smartColors[Math.floorMod(h / 7, 3)].let { if (it == a) W.smartColors[(W.smartColors.indexOf(a) + 1) % 3] else it }
    Box(Modifier.size(size).vcrGlass(shape, 0.3f, bezel = size >= 60.dp)) {
        // Zoomed in and blurred: only its colours and shapes come through (a chart's own lettering stays unreadable).
        Cover(art, Modifier.matchParentSize().graphicsLayer { scaleX = 1.45f; scaleY = 1.45f }.blur(if (size >= 90.dp) 7.dp else 3.dp),
            RoundedCornerShape(0.dp), name, desaturate = true)
        Box(Modifier.matchParentSize().background(Brush.linearGradient(listOf(a.copy(alpha = 0.62f), b.copy(alpha = 0.30f), Color(0xFF0B0A10).copy(alpha = 0.78f)),
            start = androidx.compose.ui.geometry.Offset.Zero, end = androidx.compose.ui.geometry.Offset.Infinite)))
        if (showName) {
            DotLabel("Playlist", Modifier.align(Alignment.TopStart).padding(10.dp), color = Color.White.copy(alpha = 0.8f), size = (size.value * 0.06f).coerceAtLeast(8f).sp)
            Text(name.uppercase(), Modifier.align(Alignment.BottomStart).padding(start = 10.dp, end = 10.dp, bottom = 12.dp),
                style = W.dot((size.value * 0.115f).sp, FontWeight.Black).copy(shadow = androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = 0.7f), blurRadius = 8f)),
                color = Color.White, letterSpacing = 1.sp, lineHeight = (size.value * 0.13f).sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@UnstableApi
@Composable
fun MoodGrid(player: HybridPlayer, moods: List<Item.Mood>) {
    FlowRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        moods.forEach { m ->
            Row(Modifier.clip(RoundedCornerShape(12.dp)).glass(RoundedCornerShape(12.dp)).clickable { Nav.tap(player, m, moods) }, verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(4.dp).height(34.dp).background(Color(m.color.toInt()).copy(alpha = 1f)))
                Text(m.title, Modifier.padding(horizontal = 12.dp), style = W.ui(13.sp, FontWeight.SemiBold), color = W.text)
            }
        }
    }
}

@Composable
private fun BackRow(title: String = "") {
    Row(Modifier.fillMaxWidth().padding(8.dp, 8.dp, 16.dp, 0.dp), verticalAlignment = Alignment.CenterVertically) {
        RoundButton(Icons.AutoMirrored.Filled.ArrowBack, "Back") { Nav.back() }
        if (title.isNotEmpty()) Text(title, Modifier.padding(start = 12.dp), style = W.ui(16.sp, FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun Loading(error: String?) {
    Box(Modifier.fillMaxWidth().padding(top = 80.dp), contentAlignment = Alignment.Center) {
        if (error != null) Text(error, style = W.ui(14.sp), color = W.text2) else CircularProgressIndicator(color = W.lilac, strokeWidth = 2.dp)
    }
}

// MARK: pages

@UnstableApi
@Composable
fun ArtistScreen(player: HybridPlayer, id: String, name: String) {
    val c = LocalContext.current
    var page by remember(id) { mutableStateOf<YouTubeMusic.ArtistPage?>(null) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    var about by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val ui by player.ui.collectAsState()
    LaunchedEffect(id) { runCatching { YouTubeMusic.artist(id) }.onSuccess { page = it }.onFailure { error = "Couldn't load $name — check your connection" } }
    LazyColumn(Modifier.fillMaxSize()) {
        item { BackRow() }
        val p = page
        if (p == null) { item { Loading(error) }; return@LazyColumn }
        item {
            Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Cover(p.art, Modifier.size(180.dp).vcrGlass(CircleShape, grain = 0.18f, bezel = true), CircleShape, p.name)
                Text(p.name.ifEmpty { name }, Modifier.padding(top = 14.dp, start = 20.dp, end = 20.dp), style = W.ui(30.sp, FontWeight.ExtraBold), maxLines = 2)
                if (p.listeners.isNotEmpty()) Text(p.listeners, style = W.ui(13.sp), color = W.text2)
                val songs = p.songs.map { it.track }
                Row(Modifier.padding(top = 14.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Pill("Play", Icons.Filled.PlayArrow, PillStyle.PRIMARY, songs.isNotEmpty()) { player.playList(songs) }
                    Pill("Shuffle", Icons.Filled.Shuffle, PillStyle.GLASS, songs.isNotEmpty()) { player.playList(songs, shuffled = true) }
                    Pill("Radio", Icons.Filled.Radio, PillStyle.SMART, songs.isNotEmpty()) {
                        scope.launch {
                            val seed = songs.first()
                            val more = runCatching { Radio.similar(c, seed, songs.map { it.key }.toSet(), 30) }.getOrDefault(emptyList())
                            player.playList((listOf(seed) + more).shuffled().let { l -> listOf(seed) + l.filter { it.key != seed.key } })
                        }
                    }
                }
            }
        }
        if (p.songs.isNotEmpty()) {
            item { Section("Top songs", if (p.songsPlaylist != null) "All songs" else null) { p.songsPlaylist?.let { Nav.open(Detail.Collection(it, "${p.name}: songs")) } } }
            val songs = p.songs.map { it.track }
            glassList(songs, "top") { i, t -> TrackRow(player, t, ui.current?.key == t.key, { player.playList(songs, i) }) }
        }
        p.shelves.forEach { s -> item(key = s.title) { ShelfRow(player, s) } }
        if (p.about.isNotEmpty()) item {
            Section("About")
            Text(p.about, Modifier.padding(horizontal = 20.dp).clickable { about = !about }, style = W.ui(13.sp), color = W.text2,
                maxLines = if (about) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis)
        }
        item { BottomSpace() }
    }
}

@UnstableApi
@Composable
fun CollectionScreen(player: HybridPlayer, id: String, title: String) {
    var col by remember(id) { mutableStateOf<YouTubeMusic.Collection?>(null) }
    var error by remember(id) { mutableStateOf<String?>(null) }
    LaunchedEffect(id) { runCatching { YouTubeMusic.collection(id) }.onSuccess { col = it }.onFailure { error = "Couldn't load $title — check your connection" } }
    val cl = col
    if (cl == null) Column { BackRow(title); Loading(error) }
    else TrackListScreen(player, cl.title.ifEmpty { title }, cl.subtitle, cl.art, cl.tracks, playlist = !id.startsWith("MPRE"))
}

/** A list of songs with a big cover: album, playlist, mix. Play / Shuffle / Save as a playlist of yours. */
@UnstableApi
@Composable
fun TrackListScreen(player: HybridPlayer, title: String, subtitle: String, art: String?, tracks: List<Track>, mosaic: List<String> = emptyList(), playlist: Boolean = false) {
    val c = LocalContext.current
    val ui by player.ui.collectAsState()
    var saved by remember(title) { mutableStateOf(false) }
    LazyColumn(Modifier.fillMaxSize()) {
        item { BackRow() }
        item {
            Column(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                when {
                    mosaic.size >= 4 -> Mosaic(mosaic, title, 200.dp)
                    playlist -> PlaylistCover(art, title, 200.dp, RoundedCornerShape(W.Radius.card))
                    else -> Cover(art, Modifier.size(200.dp).vcrGlass(RoundedCornerShape(W.Radius.card), grain = 0.18f, bezel = true), RoundedCornerShape(W.Radius.card), title)
                }
                Text(title, Modifier.padding(top = 14.dp, start = 20.dp, end = 20.dp), style = W.ui(24.sp, FontWeight.ExtraBold), maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(listOf(subtitle, songs(tracks.size)).filter { it.isNotEmpty() }.joinToString(" · "), Modifier.padding(horizontal = 20.dp),
                    style = W.ui(13.sp), color = W.text2, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Row(Modifier.padding(top = 14.dp, bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Pill("Play", Icons.Filled.PlayArrow, PillStyle.PRIMARY, tracks.isNotEmpty()) { player.playList(tracks) }
                    Pill("Shuffle", Icons.Filled.Shuffle, PillStyle.GLASS, tracks.isNotEmpty()) { player.playList(tracks, shuffled = true) }
                    Pill(if (saved) "Saved" else "Save", Icons.AutoMirrored.Filled.PlaylistAdd, PillStyle.GLASS, tracks.isNotEmpty() && !saved) {
                        Library.get(c).createPlaylist(title, tracks); saved = true
                    }
                }
            }
        }
        glassList(tracks, "t") { i, t -> TrackRow(player, t, ui.current?.key == t.key, { player.playList(tracks, i) }) }
        item { BottomSpace() }
    }
}

/** A mood or genre: its shelves of playlists. */
@UnstableApi
@Composable
fun BrowseScreen(player: HybridPlayer, id: String, params: String, title: String) {
    var shelves by remember(id, params) { mutableStateOf<List<Shelf>?>(null) }
    var error by remember(id, params) { mutableStateOf<String?>(null) }
    LaunchedEffect(id, params) { runCatching { YouTubeMusic.shelves(id, params.ifEmpty { null }) }.onSuccess { shelves = it }.onFailure { error = "Couldn't load $title" } }
    LazyColumn(Modifier.fillMaxSize()) {
        item { BackRow() }
        item { Text(title, Modifier.padding(20.dp, 8.dp), style = W.ui(30.sp, FontWeight.Bold)) }
        val s = shelves
        if (s == null) item { Loading(error) } else s.forEach { sh -> item { ShelfRow(player, sh) } }
        item { BottomSpace() }
    }
}
