package local.wreckbox.player

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.Calendar
import kotlin.math.ln
import kotlin.math.min

/**
 * What you listen to, kept on this phone only (history.json in the app's files): per song, how often you played it,
 * how often you skipped it, when you last played it and at what hours; plus weight from imports (your YouTube Music
 * and Spotify history, likes and top lists). Search ranking and Home's recommendations read it.
 *
 * Songs are counted by name ("title|artist", Radio.name), so the same song played from the phone, YouTube or Spotify
 * is one song; the [Stat.track] kept is the most playable copy seen (phone > YouTube > Spotify).
 */
class History private constructor(private val file: File) {
    data class Stat(
        val track: Track,
        val plays: Int = 0,
        val skips: Int = 0,
        val firstAt: Long = 0,
        val lastAt: Long = 0,
        val listenedMs: Long = 0,
        /** Plays per hour of the day (0–23). */
        val hours: IntArray = IntArray(24),
        /** Extra weight from imports: liked elsewhere, in a top-songs list. */
        val boost: Double = 0.0,
    ) {
        /** How much you like it: plays (diminishing), minus skips, plus import weight. */
        val score get() = ln(1.0 + plays) * 2 - skips * 0.6 + boost
    }

    data class Data(val songs: Map<String, Stat> = emptyMap(), val artists: Map<String, Double> = emptyMap(), val recent: List<String> = emptyList(),
                    val imported: Map<String, Long> = emptyMap())

    private val _data = MutableStateFlow(Data())
    val data: StateFlow<Data> = _data

    init { load() }

    val plays get() = _data.value.songs.values.sumOf { it.plays }

    /**
     * A song stopped (finished, skipped or replaced): count it as a play when at least half (or 4 minutes) was heard, as a
     * skip when it was cut off in the first 30 seconds of a longer song; in between it's neither.
     */
    fun record(t: Track, listenedMs: Long, durMs: Long, at: Long = System.currentTimeMillis()) {
        val played = listenedMs >= min(240_000L, (if (durMs > 0) durMs else 180_000L) / 2)
        val skipped = !played && listenedMs < 30_000 && (durMs == 0L || durMs > 60_000)
        if (!played && !skipped) return
        update { d ->
            val n = name(t)
            val s = d.songs[n] ?: Stat(t, firstAt = at)
            val hours = s.hours.copyOf().also { if (played) it[hourOf(at)]++ }
            val ns = s.copy(track = better(s.track, t), plays = s.plays + if (played) 1 else 0, skips = s.skips + if (skipped) 1 else 0,
                lastAt = maxOf(s.lastAt, at), listenedMs = s.listenedMs + listenedMs, hours = hours)
            d.copy(songs = d.songs + (n to ns), recent = if (played) (listOf(n) + d.recent.filter { it != n }).take(200) else d.recent,
                artists = d.artists + artistsOf(t).associateWith { a -> (d.artists[a] ?: 0.0) + if (played) 1.0 else -0.3 })
        }
    }

    /** One imported play (from YouTube Music's history or a data export). */
    class Play(val track: Track, val at: Long, val listenedMs: Long = 0)

    /**
     * Imported plays; a source can be imported again without counting the same plays twice ([source] remembers up to
     * which time it was imported).
     */
    fun importPlays(source: String, plays: List<Play>, newerOnly: Boolean = true): Int {
        val since = if (newerOnly) _data.value.imported[source] ?: 0 else 0
        val fresh = plays.filter { it.at > since }
        if (fresh.isEmpty()) return 0
        update { d ->
            val songs = d.songs.toMutableMap()
            val artists = d.artists.toMutableMap()
            for (p in fresh) {
                val n = name(p.track)
                val s = songs[n] ?: Stat(p.track, firstAt = p.at)
                val hours = s.hours.copyOf().also { it[hourOf(p.at)]++ }
                songs[n] = s.copy(track = better(s.track, p.track), plays = s.plays + 1, firstAt = minOf(s.firstAt.takeIf { it > 0 } ?: p.at, p.at),
                    lastAt = maxOf(s.lastAt, p.at), listenedMs = s.listenedMs + p.listenedMs, hours = hours)
                artistsOf(p.track).forEach { a -> artists[a] = (artists[a] ?: 0.0) + 1.0 }
            }
            val recent = (fresh.sortedByDescending { it.at }.map { name(it.track) } + d.recent).distinct().take(200)
            d.copy(songs = songs, artists = artists, recent = if (d.recent.isEmpty()) recent else d.recent,
                imported = d.imported + (source to maxOf(d.imported[source] ?: 0, fresh.maxOf { it.at })))
        }
        return fresh.size
    }

    /** Songs with weight but no plays to count (liked on a service, in a top list): [weight] each. */
    fun importFavourites(source: String, tracks: List<Track>, weight: Double) {
        if (tracks.isEmpty()) return
        update { d ->
            val songs = d.songs.toMutableMap()
            val artists = d.artists.toMutableMap()
            for (t in tracks) {
                val n = name(t)
                val s = songs[n] ?: Stat(t)
                songs[n] = s.copy(track = better(s.track, t), boost = maxOf(s.boost, weight))
                artistsOf(t).forEach { a -> artists[a] = (artists[a] ?: 0.0) + weight * 0.5 }
            }
            d.copy(songs = songs, artists = artists, imported = d.imported + (source to System.currentTimeMillis()))
        }
    }

    /** Artists from a service's "top artists" list: the first counts most. */
    fun importArtists(source: String, names: List<String>) = update { d ->
        val artists = d.artists.toMutableMap()
        names.forEachIndexed { i, a -> Search.norm(a).takeIf { it.isNotEmpty() }?.let { artists[it] = (artists[it] ?: 0.0) + (names.size - i) * 0.5 } }
        d.copy(artists = artists, imported = d.imported + (source to System.currentTimeMillis()))
    }

    fun clear() = update { Data() }

    // MARK: reading

    fun stat(t: Track) = _data.value.songs[name(t)]

    /** How much you like this artist (0 = never heard), by any of the track's artists. */
    fun artistScore(artist: String): Double = artistsOf(artist).maxOfOrNull { _data.value.artists[it] ?: 0.0 } ?: 0.0

    /** Your top artists, best first, with a representative song each (the one you play most). */
    fun topArtists(n: Int): List<Pair<String, Track>> {
        val d = _data.value
        val bySong = d.songs.values.filter { it.score > 0 }.groupBy { artistsOf(it.track).firstOrNull() ?: "" }
        return d.artists.entries.filter { it.value > 0 && it.key.isNotEmpty() }.sortedByDescending { it.value }.mapNotNull { (a, _) ->
            bySong[a]?.maxByOrNull { it.score }?.let { s -> (s.track.artist.split(",", "&", " x ", " feat").first().trim()) to s.track }
        }.take(n)
    }

    /** The most recent songs you played through (not skips), newest first. */
    fun recentPlays(n: Int): List<Track> = _data.value.recent.mapNotNull { _data.value.songs[it]?.takeIf { s -> s.plays > s.skips }?.track }.take(n)

    /** Loved before, not played lately: played 3+ times, last over [days] days ago. */
    fun forgotten(days: Int = 30, n: Int = 20): List<Track> {
        val cut = System.currentTimeMillis() - days * 86_400_000L
        return _data.value.songs.values.filter { it.plays >= 3 && it.lastAt in 1 until cut && it.plays > it.skips * 2 }
            .sortedByDescending { it.score }.map { it.track }.take(n)
    }

    /** Songs you tend to play at this hour of the day (± 1 hour). */
    fun forThisHour(n: Int = 25): List<Track> {
        val h = hourOf(System.currentTimeMillis())
        return _data.value.songs.values.map { s -> s to (s.hours[(h + 23) % 24] + s.hours[h] * 2 + s.hours[(h + 1) % 24]) }
            .filter { it.second >= 2 }.sortedByDescending { it.second }.map { it.first.track }.take(n)
    }

    /** Your most-played songs. */
    fun top(n: Int): List<Track> = _data.value.songs.values.filter { it.score > 0.5 }.sortedByDescending { it.score }.map { it.track }.take(n)

    // MARK: storage

    @Synchronized
    private fun update(f: (Data) -> Data) {
        _data.value = f(_data.value)
        save()
    }

    private fun load() {
        val j = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return
        runCatching {
            val songs = mutableMapOf<String, Stat>()
            j.optJSONObject("songs")?.let { o ->
                o.keys().forEach { k ->
                    val s = o.getJSONObject(k)
                    val h = s.optJSONArray("hours")
                    songs[k] = Stat(Track.fromJson(s.getJSONObject("t")), s.optInt("p"), s.optInt("s"), s.optLong("f"), s.optLong("l"), s.optLong("ms"),
                        IntArray(24) { h?.optInt(it) ?: 0 }, s.optDouble("b", 0.0))
                }
            }
            val artists = mutableMapOf<String, Double>()
            j.optJSONObject("artists")?.let { o -> o.keys().forEach { artists[it] = o.optDouble(it) } }
            val imported = mutableMapOf<String, Long>()
            j.optJSONObject("imported")?.let { o -> o.keys().forEach { imported[it] = o.optLong(it) } }
            val recent = j.optJSONArray("recent")?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
            _data.value = Data(songs, artists, recent, imported)
        }
    }

    private fun save() {
        val d = _data.value
        val songs = JSONObject()
        d.songs.forEach { (k, s) ->
            songs.put(k, JSONObject().put("t", s.track.toJson()).put("p", s.plays).put("s", s.skips).put("f", s.firstAt).put("l", s.lastAt)
                .put("ms", s.listenedMs).put("b", s.boost).put("hours", JSONArray(s.hours.toList())))
        }
        val j = JSONObject().put("songs", songs).put("artists", JSONObject(d.artists as Map<*, *>)).put("recent", JSONArray(d.recent))
            .put("imported", JSONObject(d.imported as Map<*, *>))
        runCatching {
            val tmp = File(file.path + ".tmp")
            tmp.writeText(j.toString())
            tmp.renameTo(file)
        }
    }

    companion object {
        @Volatile private var instance: History? = null
        fun get(c: Context) = instance ?: synchronized(this) { instance ?: History(File(c.filesDir, "history.json")).also { instance = it } }

        fun name(t: Track) = Radio.name(t)

        /** "Ritviz & Nucleya" → ["ritviz", "nucleya"], normalised. */
        fun artistsOf(t: Track) = artistsOf(t.artist)
        fun artistsOf(artist: String) = artist.removeSuffix(" - Topic").split(",", "&", " x ", " X ", " feat.", " feat", " ft.", " and ", " with ")
            .map { Search.norm(it) }.filter { it.isNotEmpty() }

        private fun hourOf(at: Long) = Calendar.getInstance().apply { timeInMillis = at }.get(Calendar.HOUR_OF_DAY)

        /** The copy to keep: a phone file plays best, then YouTube (starts fastest), then Spotify. */
        private fun better(a: Track, b: Track): Track {
            // (A song from Spotify's short export has no id: it can't play, so any other copy wins.)
            fun rank(t: Track) = if (t.id.isEmpty()) 9 else when (t.source) { Source.LOCAL -> 0; Source.YOUTUBE -> 1; Source.SPOTIFY -> 2 }
            if (rank(b) < rank(a)) return b.copy(art = b.art ?: a.art)
            // A fresh read of the same song corrects its length (older Spotify reads could get it wrong).
            val same = a.source == b.source && a.id == b.id && b.durationMs > 0
            return a.copy(art = a.art ?: b.art, durationMs = if (same) b.durationMs else a.durationMs)
        }
    }
}
