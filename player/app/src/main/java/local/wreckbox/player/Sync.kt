package local.wreckbox.player

import android.content.Context
import android.os.Build
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Link to WreckBox: the Player's playlists (and likes) go to your WreckBox account, where the WreckBox app on your
 * computer adds them as playlists and downloads their songs in FLAC (Soulseek first) — to your phone through WreckBox.
 *
 * Linking: the Player shows a code; you type it into WreckBox (signed in). The Player then holds a token that can only
 * read and write its own playlists on the account — nothing else. Works fully without it.
 */
object Sync {
    private const val API = "https://wreckbox-api.moloyb301.workers.dev"

    data class State(
        val linked: Boolean = false,
        val email: String = "",
        val code: String? = null,          // showing a code, waiting for WreckBox to approve it
        val lastSync: Long = 0,
        val error: String? = null,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state
    private lateinit var app: Context
    private val prefs get() = app.getSharedPreferences("sync", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var pairing: Job? = null

    fun init(c: Context) {
        if (::app.isInitialized) return
        app = c.applicationContext
        _state.value = State(linked = token() != null, email = prefs.getString("email", "") ?: "", lastSync = prefs.getLong("lastSync", 0))
        // Upload whenever the library changes (a few seconds after the last change).
        scope.launch {
            @OptIn(kotlinx.coroutines.FlowPreview::class)
            Library.get(app).data.drop(1).debounce(4000).collect { if (token() != null) push() }
        }
    }

    private fun token() = prefs.getString("token", null)

    /** Shows a code and waits (up to 15 minutes) for WreckBox to approve it. */
    fun startLinking() {
        pairing?.cancel()
        pairing = scope.launch {
            val r = runCatching { call("POST", "/v1/player/pair", JSONObject().put("name", "WreckBox Player · ${Build.MODEL}")) }.getOrElse {
                _state.value = _state.value.copy(error = "Couldn't reach WreckBox — check your connection."); return@launch
            }
            val code = r.optString("code")
            val secret = r.optString("secret")
            _state.value = _state.value.copy(code = code, error = null)
            val until = System.currentTimeMillis() + 15 * 60_000
            while (System.currentTimeMillis() < until) {
                delay(3000)
                val c = runCatching { call("POST", "/v1/player/claim", JSONObject().put("code", code).put("secret", secret)) }.getOrNull() ?: continue
                if (c.optBoolean("pending")) continue
                val t = c.optString("token")
                if (t.isEmpty()) { _state.value = _state.value.copy(code = null, error = c.optString("error", "That code expired — try again.")); return@launch }
                prefs.edit().putString("token", t).putString("email", c.optString("email")).apply()
                _state.value = State(linked = true, email = c.optString("email"))
                // A new phone with nothing on it: bring the playlists back; otherwise send ours.
                val lib = Library.get(app)
                if (lib.data.value.playlists.isEmpty() && lib.data.value.likes.isEmpty()) restore() else push()
                return@launch
            }
            _state.value = _state.value.copy(code = null, error = "The code expired — get a new one.")
        }
    }

    fun cancelLinking() { pairing?.cancel(); _state.value = _state.value.copy(code = null) }

    fun unlink() = scope.launch {
        runCatching { call("DELETE", "/v1/player/playlists", null, auth = true) }
        prefs.edit().clear().apply()
        _state.value = State()
    }

    /** Sends the playlists and likes (all of them: the account keeps the Player's current set). */
    fun push() = scope.launch {
        val d = Library.get(app).data.value
        val body = JSONObject()
            .put("playlists", JSONArray().also { a ->
                d.playlists.forEach { p -> a.put(JSONObject().put("id", p.id).put("name", p.name).put("updatedAt", p.updatedAt).put("tracks", p.tracks.toJsonArray())) }
            })
            .put("likes", d.likes.toJsonArray())
        runCatching { call("PUT", "/v1/player/playlists", body, auth = true) }
            .onSuccess {
                val now = System.currentTimeMillis()
                prefs.edit().putLong("lastSync", now).apply()
                _state.value = _state.value.copy(lastSync = now, error = null)
            }
            .onFailure { e -> _state.value = _state.value.copy(error = e.message) }
    }

    /** Brings back what's saved on the account (new phone, reinstall): adds playlists and likes not here yet. */
    fun restore() = scope.launch {
        val j = runCatching { call("GET", "/v1/player/playlists", null, auth = true) }.getOrNull() ?: return@launch
        val lib = Library.get(app)
        withContext(Dispatchers.Main) {
            j.optJSONArray("playlists")?.let { a ->
                for (i in 0 until a.length()) {
                    val p = a.getJSONObject(i)
                    if (lib.data.value.playlists.none { it.name == p.optString("name") }) lib.createPlaylist(p.optString("name"), p.optJSONArray("tracks").toTracks())
                }
            }
            j.optJSONArray("likes").toTracks().reversed().forEach { if (!lib.isLiked(it)) lib.toggleLike(it) }
        }
    }

    private fun call(method: String, path: String, body: JSONObject?, auth: Boolean = false): JSONObject {
        val c = URL(API + path).openConnection() as HttpURLConnection
        c.requestMethod = method
        c.connectTimeout = 10_000
        c.readTimeout = 20_000
        c.setRequestProperty("content-type", "application/json")
        if (auth) {
            c.setRequestProperty("authorization", "Bearer ${token() ?: ""}")
            c.setRequestProperty("x-wreckbox-player", "1")
        }
        if (body != null) { c.doOutput = true; c.outputStream.use { it.write(body.toString().toByteArray()) } }
        val code = c.responseCode
        val text = (if (code < 400) c.inputStream else c.errorStream)?.bufferedReader()?.use { it.readText() } ?: "{}"
        val j = runCatching { JSONObject(text) }.getOrDefault(JSONObject())
        if (code == 401 && auth) {
            prefs.edit().clear().apply()
            _state.value = State(error = j.optString("error", "Not linked any more."))
        }
        if (code >= 400) throw RuntimeException(j.optString("error", "WreckBox said $code"))
        return j
    }
}
