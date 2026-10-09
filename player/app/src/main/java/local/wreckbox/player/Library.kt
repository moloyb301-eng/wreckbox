package local.wreckbox.player

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** Where a track plays from. */
enum class Source(val label: String) { LOCAL("Phone"), YOUTUBE("YouTube"), SPOTIFY("Spotify") }

/**
 * A song from any source. `id` is the source's own id: a content:// URI or path for phone files, a YouTube video id,
 * a Spotify track id. `key` is unique across sources.
 */
data class Track(
    val source: Source,
    val id: String,
    val title: String,
    val artist: String,
    val album: String? = null,
    val durationMs: Long = 0,
    val art: String? = null,
) {
    val key get() = "${source.name}:$id"

    fun toJson(): JSONObject = JSONObject()
        .put("source", source.name).put("id", id).put("title", title).put("artist", artist)
        .put("album", album).put("durationMs", durationMs).put("art", art)

    companion object {
        fun fromJson(j: JSONObject) = Track(
            source = Source.valueOf(j.getString("source")),
            id = j.getString("id"),
            title = j.optString("title"),
            artist = j.optString("artist"),
            album = j.optString("album").takeIf { it.isNotEmpty() && it != "null" },
            durationMs = j.optLong("durationMs"),
            art = j.optString("art").takeIf { it.isNotEmpty() && it != "null" },
        )
    }
}

fun List<Track>.toJsonArray() = JSONArray().also { a -> forEach { a.put(it.toJson()) } }
fun JSONArray?.toTracks(): List<Track> =
    if (this == null) emptyList() else (0 until length()).mapNotNull { runCatching { Track.fromJson(getJSONObject(it)) }.getOrNull() }

data class Playlist(val id: String, val name: String, val tracks: List<Track>, val updatedAt: Long)

/**
 * The phone's own library: liked songs, playlists, recently played. Kept in library.json in the app's files so the
 * player works with nothing else installed; the WreckBox account sync (link code) reads and writes the same data.
 */
class Library private constructor(private val file: File) {
    data class Data(val likes: List<Track> = emptyList(), val playlists: List<Playlist> = emptyList(), val recent: List<Track> = emptyList())

    private val _data = MutableStateFlow(Data())
    val data: StateFlow<Data> = _data

    init { load() }

    fun isLiked(t: Track) = _data.value.likes.any { it.key == t.key }

    fun toggleLike(t: Track) = update {
        if (isLiked(t)) it.copy(likes = it.likes.filter { x -> x.key != t.key }) else it.copy(likes = listOf(t) + it.likes)
    }

    fun clearRecent() = update { it.copy(recent = emptyList()) }

    fun played(t: Track) = update { it.copy(recent = (listOf(t) + it.recent.filter { x -> x.key != t.key }).take(50)) }

    fun createPlaylist(name: String, tracks: List<Track> = emptyList()): Playlist {
        val p = Playlist(UUID.randomUUID().toString(), name.trim().ifEmpty { "New playlist" }, tracks, System.currentTimeMillis())
        update { it.copy(playlists = it.playlists + p) }
        return p
    }

    fun renamePlaylist(id: String, name: String) = editPlaylist(id) { it.copy(name = name.trim().ifEmpty { it.name }) }
    fun deletePlaylist(id: String) = update { it.copy(playlists = it.playlists.filter { p -> p.id != id }) }
    fun addToPlaylist(id: String, t: Track) = editPlaylist(id) { p -> if (p.tracks.any { it.key == t.key }) p else p.copy(tracks = p.tracks + t) }
    fun removeFromPlaylist(id: String, index: Int) = editPlaylist(id) { p -> p.copy(tracks = p.tracks.filterIndexed { i, _ -> i != index }) }
    fun moveInPlaylist(id: String, from: Int, to: Int) = editPlaylist(id) { p ->
        if (to !in p.tracks.indices) p else p.copy(tracks = p.tracks.toMutableList().apply { add(to, removeAt(from)) })
    }

    private fun editPlaylist(id: String, f: (Playlist) -> Playlist) = update { d ->
        d.copy(playlists = d.playlists.map { if (it.id == id) f(it).copy(updatedAt = System.currentTimeMillis()) else it })
    }

    @Synchronized
    private fun update(f: (Data) -> Data) {
        _data.value = f(_data.value)
        save()
    }

    private fun load() {
        // A damaged library file must never stop the app from opening: keep whatever can be read.
        val j = runCatching { JSONObject(file.readText()) }.getOrNull() ?: return
        runCatching { _data.value = Data(
            likes = j.optJSONArray("likes").toTracks(),
            recent = j.optJSONArray("recent").toTracks(),
            playlists = j.optJSONArray("playlists")?.let { a ->
                (0 until a.length()).map { i ->
                    val p = a.getJSONObject(i)
                    Playlist(p.getString("id"), p.getString("name"), p.optJSONArray("tracks").toTracks(), p.optLong("updatedAt"))
                }
            } ?: emptyList(),
        ) }
    }

    private fun save() {
        val d = _data.value
        val j = JSONObject()
            .put("likes", d.likes.toJsonArray())
            .put("recent", d.recent.toJsonArray())
            .put("playlists", JSONArray().also { a ->
                d.playlists.forEach { p ->
                    a.put(JSONObject().put("id", p.id).put("name", p.name).put("updatedAt", p.updatedAt).put("tracks", p.tracks.toJsonArray()))
                }
            })
        runCatching {
            val tmp = File(file.path + ".tmp")
            tmp.writeText(j.toString())
            tmp.renameTo(file)
        }
    }

    companion object {
        @Volatile private var instance: Library? = null
        fun get(c: Context) = instance ?: synchronized(this) { instance ?: Library(File(c.filesDir, "library.json")).also { instance = it } }
    }
}
