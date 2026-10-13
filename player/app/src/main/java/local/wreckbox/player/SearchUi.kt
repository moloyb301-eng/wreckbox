package local.wreckbox.player

import android.content.ActivityNotFoundException
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.common.util.UnstableApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The Search page's state, kept outside the page so switching tabs doesn't wipe it. */
object SearchMemory {
    val query = mutableStateOf("")
    val results = mutableStateOf<Search.Results?>(null)
    val searched = mutableStateOf("")
    val filter = mutableStateOf(Filter.ALL)
    var job: Job? = null
}

/** Search-while-typing's results: the top result and the first songs (from the shared YouTube searches + your music). */
class Live(val top: Item?, val hits: List<Hit>, val extra: List<Pair<Track, Boolean>>, val query: String = "")

enum class Filter(val label: String) { ALL("All"), SONGS("Songs"), ARTISTS("Artists"), ALBUMS("Albums"), PLAYLISTS("Playlists"), PHONE("Phone"), YOUTUBE("YouTube"), SPOTIFY("Spotify") }

/**
 * Search: suggestions while you type (YouTube Music's completions + your own songs), recent searches when empty,
 * voice search; results arrive as each source answers — the top result, songs (one row per song, the copy that plays
 * best, the other sources as tags), artists, albums and playlists.
 */
@UnstableApi
@Composable
fun SearchPage(player: HybridPlayer) {
    val c = LocalContext.current
    val ui by player.ui.collectAsState()
    var q by SearchMemory.query
    var results by SearchMemory.results
    var searched by SearchMemory.searched
    var filter by SearchMemory.filter
    var typing by remember { mutableStateOf(false) }
    var suggestions by remember { mutableStateOf<Pair<List<String>, List<Item>>>(emptyList<String>() to emptyList()) }
    var mine by remember { mutableStateOf<List<Track>>(emptyList()) }
    var live by remember { mutableStateOf<Live?>(null) }
    var recent by remember { mutableStateOf(RecentSearches.all(c)) }
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    val scope = rememberCoroutineScope()

    fun run(text: String = q) {
        val query = text.trim()
        if (query.isEmpty()) return
        q = query
        typing = false
        searched = query
        filter = Filter.ALL
        keyboard?.hide()
        focus.clearFocus()
        RecentSearches.add(c, query)
        recent = RecentSearches.all(c)
        SearchMemory.job?.cancel()
        // What typing already found shows at once; the full search fills in the rest.
        results = live?.takeIf { it.query == query }?.let { Search.Results(query, it.top, it.hits) } ?: Search.Results(query)
        SearchMemory.job = scope.launch {
            Search.stream(c, query).collect { results = it }
            keyboard?.hide() // also after a hardware Enter, where the first hide can come too early
        }
    }

    // The Search page opened: get the connection to YouTube ready, so the first search skips the handshake.
    LaunchedEffect(Unit) { YouTubeMusic.warm() }
    // While typing: your own songs at once, YouTube's completions after a short pause, and after a slightly longer
    // one the search itself — results show under the suggestions, and Enter reuses the same searches (YtCache).
    LaunchedEffect(q, typing) {
        if (!typing || q.isBlank()) { suggestions = emptyList<String>() to emptyList(); mine = emptyList(); live = null; return@LaunchedEffect }
        mine = withContext(Dispatchers.Default) { SearchIndex.search(c, q, 4) }
        delay(150)
        launch { suggestions = runCatching { YouTubeMusic.suggestions(q) }.getOrDefault(emptyList<String>() to emptyList()) }
        if (q.trim().length < 2) return@LaunchedEffect
        delay(250)
        val query = q.trim()
        val mixed = Search.YtCache.mixed(query)
        val songs = Search.YtCache.songs(query)
        // Whichever YouTube search answers first is shown first.
        launch {
            runCatching { songs.await() }.getOrNull()?.let { s ->
                val cur = live?.takeIf { it.query == query } // the mixed search may have answered already
                live = Live(cur?.top, withContext(Dispatchers.Default) { Search.rank(c, query, mine.map { it to false } + s.map { it to false } + (cur?.extra ?: emptyList())) }, cur?.extra ?: emptyList(), query)
            }
        }
        runCatching { mixed.await() }.getOrNull()?.let { r ->
            val extra = r.songs.map { it.track to it.video }
            val songsNow = if (songs.isCompleted) runCatching { songs.getCompleted() }.getOrDefault(emptyList()) else emptyList()
            live = Live(r.top, withContext(Dispatchers.Default) { Search.rank(c, query, mine.map { it to false } + extra + songsNow.map { it to false }) }, extra, query)
        }
    }

    val voice = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { r ->
        r.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.let { run(it) }
    }

    fun listen() {
        try {
            voice.launch(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                .putExtra(RecognizerIntent.EXTRA_PROMPT, "Say a song or an artist"))
        } catch (_: ActivityNotFoundException) { }
    }

    val r = results
    val busy = r != null && !r.done
    fun play(t: Track) { Clicks.picked(c, searched, t); player.playList(listOf(t)) }

    LazyColumn(Modifier.fillMaxSize()) {
        item {
            Text("Search", style = W.ui(30.sp, FontWeight.Bold), modifier = Modifier.padding(20.dp, 14.dp, 20.dp, 12.dp))
            GlassField(q, { q = it; typing = true }, "Song, artist or a line from the lyrics", Modifier.padding(horizontal = 16.dp), Icons.Filled.Search,
                trailing = {
                    if (q.isNotEmpty()) IconButton({ q = ""; results = null; searched = ""; typing = false; SearchMemory.job?.cancel() }) { Icon(Icons.Filled.Close, "Clear", tint = W.text3) }
                    else IconButton(::listen) { Icon(Icons.Filled.Mic, "Voice search", tint = W.text2) }
                },
                onDone = { run() })
            if (busy) LinearProgressIndicator(Modifier.padding(horizontal = 32.dp, vertical = 8.dp).fillMaxWidth().height(2.dp).clip(CircleShape), color = W.lilac, trackColor = W.hairline)
        }

        // While typing: completions, then your own songs and direct hits.
        if (typing && q.isNotBlank()) {
            items(suggestions.first.take(6).size) { i ->
                val s = suggestions.first[i]
                Row(Modifier.fillMaxWidth().clickable { run(s) }.padding(horizontal = 22.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.Search, null, Modifier.size(18.dp), tint = W.text3)
                    Text(s, Modifier.weight(1f).padding(start = 14.dp), style = W.ui(15.sp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Icon(Icons.Filled.NorthWest, "Use", Modifier.size(16.dp).clickable { q = "$s " }, tint = W.text3)
                }
            }
            val lv = live
            if (lv != null && (lv.hits.isNotEmpty() || lv.top != null)) {
                // Live results (search while typing)
                lv.top?.takeIf { it !is Item.Song }?.let { top -> item { Section("Top result"); SmallItemRow(top) { Nav.tap(player, top, listOf(top)) } } }
                item { Section("Songs", "All results") { run() } }
                hitList(player, lv.hits.take(6), ui.current?.key, ::play)
            } else if (mine.isNotEmpty()) {
                item { Section("Your music") }
                glassList(mine, "mine") { _, t -> TrackRow(player, t, ui.current?.key == t.key, { play(t) }) }
            }
            val direct = suggestions.second.filter { it is Item.Artist || it is Item.Album }.take(3)
            if (direct.isNotEmpty() && lv?.top == null) {
                item { Section("Quick results") }
                items(direct.size) { i -> SmallItemRow(direct[i]) { if (direct[i] is Item.Song) play((direct[i] as Item.Song).track) else Nav.tap(player, direct[i], direct) } }
            }
            item { BottomSpace() }
            return@LazyColumn
        }

        // Empty: recent searches
        if (r == null) {
            if (recent.isNotEmpty()) {
                item { Section("Recent searches", "Clear") { RecentSearches.clear(c); recent = emptyList() } }
                items(recent.size) { i ->
                    val s = recent[i]
                    Row(Modifier.fillMaxWidth().clickable { run(s) }.padding(start = 22.dp, end = 10.dp, top = 4.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.History, null, Modifier.size(18.dp), tint = W.text3)
                        Text(s, Modifier.weight(1f).padding(start = 14.dp), style = W.ui(15.sp), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        IconButton({ RecentSearches.remove(c, s); recent = RecentSearches.all(c) }) { Icon(Icons.Filled.Close, "Remove", Modifier.size(16.dp), tint = W.text3) }
                    }
                }
            } else item {
                Column(Modifier.fillMaxWidth().padding(top = 60.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    DotSpectrum(false, cols = 7, rows = 5, dot = 6.dp, gap = 3.dp)
                    Text("Phone, YouTube Music and Spotify — all at once", Modifier.padding(top = 16.dp), style = W.ui(13.sp), color = W.text3)
                }
            }
            item { BottomSpace() }
            return@LazyColumn
        }

        // Results
        item {
            r.corrected?.let { fixed ->
                Row(Modifier.padding(20.dp, 10.dp, 20.dp, 0.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Showing results for ", style = W.ui(13.sp), color = W.text2)
                    Text(fixed, style = W.ui(13.sp, FontWeight.Bold), color = W.lilac)
                }
            }
            val counts = mapOf(
                Filter.ALL to null, Filter.SONGS to r.hits.size, Filter.ARTISTS to r.artists.size, Filter.ALBUMS to r.albums.size, Filter.PLAYLISTS to r.playlists.size,
                Filter.PHONE to r.hits.count { it.track.source == Source.LOCAL }, Filter.YOUTUBE to r.hits.count { h -> h.track.source == Source.YOUTUBE || h.alts.any { it.source == Source.YOUTUBE } },
                Filter.SPOTIFY to r.hits.count { h -> h.track.source == Source.SPOTIFY || h.alts.any { it.source == Source.SPOTIFY } },
            )
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(16.dp, 12.dp, 16.dp, 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                counts.forEach { (f, n) -> if (n == null || n > 0) Chip(f.label, filter == f, n) { filter = f } }
            }
            if (r.done && r.failed.isNotEmpty())
                Text("Couldn't reach ${r.failed.joinToString(" or ")} — check your connection or sign-in.", Modifier.padding(20.dp, 6.dp), color = W.text2, style = W.ui(12.sp))
            if (r.done && r.hits.isEmpty() && r.artists.isEmpty() && r.albums.isEmpty()) Text("Nothing found for “$searched”.", Modifier.padding(20.dp), color = W.text2, style = W.ui(14.sp))
        }
        val hitsShown = when (filter) {
            Filter.ALL, Filter.SONGS -> r.hits
            Filter.PHONE -> r.hits.filter { it.track.source == Source.LOCAL }
            Filter.YOUTUBE -> r.hits.mapNotNull { h -> if (h.track.source == Source.YOUTUBE) h else h.alts.firstOrNull { it.source == Source.YOUTUBE }?.let { Hit(it) } }
            Filter.SPOTIFY -> r.hits.mapNotNull { h -> if (h.track.source == Source.SPOTIFY) h else h.alts.firstOrNull { it.source == Source.SPOTIFY }?.let { Hit(it) } }
            else -> emptyList()
        }
        if (filter == Filter.ALL) {
            r.top?.let { top -> item(key = "top") { TopResult(player, top, r) { play(it) } } }
            if (hitsShown.isNotEmpty()) item { Section("Songs", if (hitsShown.size > 8) "All ${hitsShown.size}" else null) { filter = Filter.SONGS } }
            hitList(player, hitsShown.take(8), ui.current?.key, ::play)
            if (r.artists.isNotEmpty()) item { ShelfRow(player, Shelf("Artists", r.artists)) }
            if (r.albums.isNotEmpty()) item { ShelfRow(player, Shelf("Albums & singles", r.albums)) }
            if (r.playlists.isNotEmpty()) item { ShelfRow(player, Shelf("Playlists", r.playlists)) }
        } else when (filter) {
            Filter.ARTISTS -> items(r.artists.size) { i -> SmallItemRow(r.artists[i]) { Nav.tap(player, r.artists[i], r.artists) } }
            Filter.ALBUMS -> items(r.albums.size) { i -> SmallItemRow(r.albums[i]) { Nav.tap(player, r.albums[i], r.albums) } }
            Filter.PLAYLISTS -> items(r.playlists.size) { i -> SmallItemRow(r.playlists[i]) { Nav.tap(player, r.playlists[i], r.playlists) } }
            else -> hitList(player, hitsShown, ui.current?.key, ::play)
        }
        item { BottomSpace() }
    }
}

/** Songs as rows: the copy that plays, the other sources as tags, and "Play from …" in the menu. */
@UnstableApi
private fun androidx.compose.foundation.lazy.LazyListScope.hitList(player: HybridPlayer, hits: List<Hit>, playing: String?, play: (Track) -> Unit) {
    glassList(hits.map { it.track }, "h") { i, t ->
        val h = hits[i]
        TrackRow(player, t, playing == t.key, { play(t) }, also = h.alts.map { it.source }.distinct().filter { it != t.source }, extra = if (h.alts.isEmpty()) null else { close ->
            h.alts.distinctBy { it.source }.forEach { alt ->
                DropdownMenuItem({ Text("Play from ${alt.source.label}") }, { play(alt); close() }, leadingIcon = { Icon(Icons.Filled.PlayCircleOutline, null) })
            }
        })
    }
}

/** The top result: a big card — an artist (open, radio) or a song (play). */
@UnstableApi
@Composable
private fun TopResult(player: HybridPlayer, top: Item, r: Search.Results, play: (Track) -> Unit) {
    Section("Top result")
    Row(Modifier.padding(horizontal = 16.dp).fillMaxWidth().smartGlass(RoundedCornerShape(W.Radius.card)).clickable {
        if (top is Item.Song) play(top.track) else Nav.tap(player, top, listOf(top))
    }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
        if (top is Item.Playlist) PlaylistCover(top.art, top.title, 92.dp)
        else Cover(top.art, Modifier.size(92.dp).vcrGlass(if (top is Item.Artist) CircleShape else RoundedCornerShape(W.Radius.tile), 0.18f, bezel = true),
            if (top is Item.Artist) CircleShape else RoundedCornerShape(W.Radius.tile), top.title)
        Column(Modifier.weight(1f).padding(start = 16.dp)) {
            DotLabel(when (top) { is Item.Artist -> "Artist"; is Item.Album -> "Album"; is Item.Playlist -> "Playlist"; is Item.Song -> if (top.video) "Video" else "Song"; else -> "" },
                color = W.lilac, size = 10.sp)
            Text(top.title, style = W.ui(22.sp, FontWeight.ExtraBold), maxLines = 2, overflow = TextOverflow.Ellipsis)
            val sub = if (top is Item.Song) top.track.artist else top.subtitle.substringAfter(" • ", top.subtitle)
            if (sub.isNotEmpty()) Text(sub, style = W.ui(13.sp), color = W.text2, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Row(Modifier.padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                when (top) {
                    is Item.Song -> Pill("Play", Icons.Filled.PlayArrow, PillStyle.PRIMARY) { play(top.track) }
                    is Item.Artist -> {
                        // Their songs in these results, best first.
                        val theirs = r.hits.map { it.track }.filter { t -> History.artistsOf(t).any { it in History.artistsOf(top.title) } }
                        Pill("Play", Icons.Filled.PlayArrow, PillStyle.PRIMARY, theirs.isNotEmpty()) { player.playList(theirs) }
                        Pill("Open", Icons.AutoMirrored.Filled.ArrowForward) { Nav.tap(player, top, listOf(top)) }
                    }
                    else -> Pill("Open", Icons.AutoMirrored.Filled.ArrowForward) { Nav.tap(player, top, listOf(top)) }
                }
            }
        }
    }
}

/** An artist / album / playlist / song as a list row. */
@Composable
fun SmallItemRow(item: Item, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        if (item is Item.Playlist) PlaylistCover(item.art, item.title, 50.dp, RoundedCornerShape(W.Radius.art))
        else Cover(item.art, Modifier.size(50.dp), if (item is Item.Artist) CircleShape else RoundedCornerShape(W.Radius.art), item.title)
        Column(Modifier.weight(1f).padding(start = 14.dp)) {
            Text(item.title, style = W.ui(15.sp, FontWeight.SemiBold), maxLines = 1, overflow = TextOverflow.Ellipsis)
            val kind = when (item) { is Item.Artist -> "Artist"; is Item.Album -> ""; is Item.Playlist -> ""; is Item.Song -> if (item.video) "Video" else "Song"; else -> "" }
            val sub = if (item is Item.Song) item.track.artist else item.subtitle
            Text(listOf(kind, sub).filter { it.isNotEmpty() }.joinToString(" · "), style = W.ui(12.5.sp), color = W.text2, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}
