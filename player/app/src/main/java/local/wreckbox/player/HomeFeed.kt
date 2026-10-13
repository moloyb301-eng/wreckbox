package local.wreckbox.player

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.LocalDate

/**
 * Home's recommendations, built in the background and kept on the phone (home.json), so Home opens at once and still
 * has something offline:
 *  - feed: your YouTube Music home (signed in: Quick picks, Mixed for you, Listen again…)
 *  - mixes: one per top artist (their songs you love + YouTube's radio from them), this hour's mix, a liked-songs mix
 *  - because: songs like the one you played last
 *  - fresh: new singles and albums from your artists (this year and last)
 *  - rediscover: loved before, not played in a month; and phone songs you've never played
 *  - charts, moods: for a new phone with no history yet (and browsing)
 * Rebuilt when it's 6 hours old (or Refresh); each part is shown as soon as it's ready.
 */
object HomeFeed {
    val parts = MutableStateFlow<Map<String, List<Shelf>>>(emptyMap())
    val loading = MutableStateFlow(false)
    private var builtAt = 0L
    private var loaded = false

    private fun file(c: Context) = File(c.filesDir, "home.json")

    fun load(c: Context) {
        if (loaded) return
        loaded = true
        runCatching {
            val j = JSONObject(file(c).readText())
            builtAt = j.optLong("at")
            val p = j.getJSONObject("parts")
            parts.value = p.keys().asSequence().associateWith { k -> p.getJSONArray(k).let { a -> (0 until a.length()).map { Shelf.fromJson(a.getJSONObject(it)) } } }
        }
    }

    private fun save(c: Context) = runCatching {
        val p = JSONObject()
        parts.value.forEach { (k, v) -> p.put(k, JSONArray().also { a -> v.forEach { a.put(it.toJson()) } }) }
        file(c).writeText(JSONObject().put("at", builtAt).put("parts", p).toString())
    }

    private fun put(c: Context, key: String, shelves: List<Shelf>) {
        synchronized(this) { parts.value = parts.value + (key to shelves.filter { it.items.isNotEmpty() }) }
        save(c)
    }

    suspend fun refresh(c: Context, force: Boolean = false) {
        load(c)
        if (loading.value || (!force && System.currentTimeMillis() - builtAt < 6 * 3600_000L && parts.value.isNotEmpty())) return
        loading.value = true
        try {
            supervisorScope {
                launch { runCatching { put(c, "feed", feed()) }.onFailure { Debug.log("home feed failed: $it") } }
                launch { runCatching { put(c, "mixes", mixes(c)) }.onFailure { Debug.log("home mixes failed: $it") } }
                launch { runCatching { put(c, "because", because(c)) }.onFailure { Debug.log("home because failed: $it") } }
                launch { runCatching { put(c, "fresh", fresh(c)) }.onFailure { Debug.log("home fresh failed: $it") } }
                launch { runCatching { put(c, "rediscover", rediscover(c)) }.onFailure { Debug.log("home rediscover failed: $it") } }
                launch { runCatching { put(c, "charts", YouTubeMusic.shelves("FEmusic_charts").take(3).map { it.copy(title = "Charts · ${it.title}") }) }.onFailure { Debug.log("home charts failed: $it") } }
                launch { runCatching { put(c, "moods", YouTubeMusic.shelves("FEmusic_moods_and_genres")) }.onFailure { Debug.log("home moods failed: $it") } }
            }
            builtAt = System.currentTimeMillis()
            save(c)
            Debug.log("home built: " + parts.value.entries.joinToString { (k, v) -> "$k=${v.sumOf { it.items.size }}" })
        } finally { loading.value = false }
    }

    /** Your YouTube Music home (signed in = yours; otherwise its general one). */
    private suspend fun feed(): List<Shelf> = YouTubeMusic.shelves("FEmusic_home", auth = YouTubeMusic.signedIn())
        .filter { s -> s.items.any { it is Item.Song || it is Item.Album || it is Item.Playlist || it is Item.Artist } }
        .map { s -> s.copy(items = s.items.filter { it !is Item.Mood }) }

    private suspend fun mixes(c: Context): List<Shelf> = coroutineScope {
        val h = History.get(c)
        val lib = Library.get(c).data.value
        val out = mutableListOf<Item.Mix>()
        val tops = h.topArtists(6).filter { it.second.id.isNotEmpty() }
        val artistMixes = tops.mapIndexed { i, (artist, seed) ->
            async {
                runCatching {
                    val yours = h.top(200).filter { t -> History.artistsOf(t).firstOrNull() == History.artistsOf(artist).firstOrNull() && t.id.isNotEmpty() }.take(6)
                    val radio = Radio.similar(c, seed, yours.map { it.key }.toSet(), 24)
                    Item.Mix("mix:artist:$i", "$artist Mix", "${artist} and music like it", interleave(yours, radio).take(30))
                }.getOrNull()
            }
        }.awaitAll().filterNotNull().filter { it.tracks.size >= 8 }
        // This hour's songs: what you tend to play around now.
        val hour = h.forThisHour(12).filter { it.id.isNotEmpty() }
        if (hour.size >= 6) runCatching {
            val radio = Radio.similar(c, hour.first(), hour.map { it.key }.toSet(), 15)
            out += Item.Mix("mix:hour", "${partOfDay()} mix", "What you play around this time", interleave(hour.shuffled(), radio).take(30))
        }
        if (lib.likes.size >= 5) runCatching {
            val seeds = lib.likes.shuffled().take(3)
            val radio = seeds.map { s -> async { runCatching { Radio.similar(c, s, lib.likes.map { it.key }.toSet(), 10) }.getOrDefault(emptyList()) } }.awaitAll().flatten()
            out += Item.Mix("mix:liked", "Liked mix", "Your liked songs and new ones like them", interleave(lib.likes.shuffled().take(15), radio.distinctBy { Radio.name(it) }).take(30))
        }
        listOf(Shelf("Your mixes", artistMixes + out, "Made for you, refreshed daily"))
    }

    private fun interleave(a: List<Track>, b: List<Track>): List<Track> {
        val out = mutableListOf<Track>()
        val seen = mutableSetOf<String>()
        for (i in 0 until maxOf(a.size, b.size)) {
            listOfNotNull(a.getOrNull(i), b.getOrNull(i * 2), b.getOrNull(i * 2 + 1)).forEach { if (seen.add(Radio.name(it))) out += it }
        }
        return out
    }

    fun partOfDay(): String = when (java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY)) {
        in 5..11 -> "Morning"; in 12..16 -> "Afternoon"; in 17..20 -> "Evening"; else -> "Late-night"
    }

    private suspend fun because(c: Context): List<Shelf> {
        val seeds = (History.get(c).recentPlays(3) + Library.get(c).data.value.recent).filter { it.id.isNotEmpty() }.distinctBy { Radio.name(it) }.take(2)
        return seeds.mapNotNull { seed ->
            runCatching {
                val found = Radio.similar(c, seed, emptySet(), 20)
                Shelf("Because you played ${seed.title}", found.map { Item.Song(it, it.artist) }, seed.artist)
            }.getOrNull()
        }
    }

    /** New releases from your top artists: their singles/albums dated this year or last. */
    private suspend fun fresh(c: Context): List<Shelf> = coroutineScope {
        val year = LocalDate.now().year
        val prefs = c.getSharedPreferences("artists", Context.MODE_PRIVATE)
        val found = History.get(c).topArtists(10).map { (artist, _) ->
            async(Dispatchers.IO) {
                runCatching {
                    val key = Search.norm(artist)
                    val id = prefs.getString(key, null) ?: YouTubeMusic.search(artist).let { r ->
                        (listOfNotNull(r.top as? Item.Artist) + r.artists).firstOrNull { Search.norm(it.title) == key }?.id
                    }?.also { prefs.edit().putString(key, it).apply() } ?: return@runCatching emptyList()
                    YouTubeMusic.artist(id).shelves.filter { it.title.contains("Single") || it.title.contains("Album") || it.title.contains("EP") }
                        .flatMap { it.items }.filterIsInstance<Item.Album>()
                        .mapNotNull { a ->
                            // The release year: a 20xx in the subtitle that isn't in the future (not a view count or a title)
                            val y = Regex("\\b(20\\d\\d)\\b").findAll(a.subtitle).mapNotNull { it.value.toIntOrNull() }.firstOrNull { it <= year } ?: return@mapNotNull null
                            if (y in (year - 1)..year) y to a.copy(artist = a.artist.ifEmpty { artist }, subtitle = "${a.subtitle.substringBefore(" • ")} · $artist · $y") else null
                        }.take(3)
                }.getOrDefault(emptyList())
            }
        }.awaitAll().flatten().sortedByDescending { it.first }.map { it.second }.distinctBy { it.id }
        listOf(Shelf("New from your artists", found.take(20)))
    }

    private suspend fun rediscover(c: Context): List<Shelf> = withContext(Dispatchers.Default) {
        val h = History.get(c)
        val forgotten = h.forgotten().filter { it.id.isNotEmpty() }
        val local = runCatching { Local.cached(c) }.getOrDefault(emptyList())
        // Phone songs you've never played here — a different handful each day.
        val day = LocalDate.now().toEpochDay()
        val unplayed = local.filter { h.stat(it) == null }.shuffled(java.util.Random(day)).take(20)
        listOf(
            Shelf("Rediscover", forgotten.map { Item.Song(it, it.artist) }, "Loved before, not played lately"),
            Shelf("On this phone, never played", unplayed.map { Item.Song(it, it.artist) }),
        )
    }
}
