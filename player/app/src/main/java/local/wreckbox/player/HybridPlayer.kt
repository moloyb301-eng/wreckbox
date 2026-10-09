package local.wreckbox.player

import android.content.Context
import android.net.Uri
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.SimpleBasePlayer
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONObject
import java.io.File

/**
 * The one player behind everything: a queue of tracks from any source. Phone files play in ExoPlayer, YouTube Music
 * and Spotify tracks in their hidden pages (WebEngine). To Android (the media notification, lock screen, headset and
 * Bluetooth buttons, Android Auto, the widget) it's a single ordinary player — a Media3 SimpleBasePlayer.
 *
 * The queue is ours: when a song ends (or a service tries to carry on with its own autoplay) we stop that page and
 * start the next track of our queue, whatever its source.
 */
@UnstableApi
class HybridPlayer(private val context: Context, private val onWebPlaying: (Boolean) -> Unit) : SimpleBasePlayer(Looper.getMainLooper()) {

    data class Ui(
        val queue: List<Track> = emptyList(),
        val index: Int = -1,
        val playing: Boolean = false,
        val buffering: Boolean = false,
        val shuffle: Boolean = false,
        val repeat: Int = Player.REPEAT_MODE_OFF,
        val message: String? = null,
        /** What's playing, technically: "FLAC · 24/96 · 2,612 kbps", "OPUS · ~160 kbps" (Quality). */
        val quality: String? = null,
        /** Songs autoplay added (similar to what was playing): their keys, and the song the latest mix came from. */
        val radio: Set<String> = emptySet(),
        val radioFrom: String? = null,
        val radioLoading: Boolean = false,
    ) {
        val current get() = queue.getOrNull(index)
    }

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui

    private var queue: List<Track> = emptyList()
    private var original: List<Track>? = null // the order before shuffle
    private var index = -1
    private var playWhenReady = false
    private var buffering = false
    private var repeat = Player.REPEAT_MODE_OFF
    private var message: String? = null
    private var startedAt = 0L

    // The audio it plays is also copied to Levels (the dot displays' real spectrum) — only analysed while one is shown.
    private val exo: ExoPlayer = ExoPlayer.Builder(context, object : androidx.media3.exoplayer.DefaultRenderersFactory(context) {
        override fun buildAudioSink(c: Context, enableFloatOutput: Boolean, enableAudioTrackPlaybackParams: Boolean) =
            androidx.media3.exoplayer.audio.DefaultAudioSink.Builder(c)
                .setAudioProcessors(arrayOf(androidx.media3.exoplayer.audio.TeeAudioProcessor(Levels.sink)))
                .build()
    }).setHandleAudioBecomingNoisy(true).setWakeMode(C.WAKE_MODE_LOCAL).build().apply {
        addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (current()?.source != Source.LOCAL) return
                if (state == Player.STATE_READY) buffering = false
                if (state == Player.STATE_ENDED) trackEnded() else refresh()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) = refresh()

            override fun onAudioSessionIdChanged(audioSessionId: Int) = Eq.attach(audioSessionId)

            override fun onPlayerError(error: PlaybackException) {
                if (current()?.source == Source.LOCAL) failed("Couldn't play this file (${error.errorCodeName})")
            }
        })
    }
    private val engines = mutableMapOf<Service, WebEngine>()
    private val library = Library.get(context)
    private val queueFile = File(context.filesDir, "queue.json")


    private var quality: String? = null
    private val io = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val mainHandler = android.os.Handler(Looper.getMainLooper())

    // MARK: what the app calls

    fun current() = queue.getOrNull(index)

    fun playList(tracks: List<Track>, start: Int = 0, shuffled: Boolean = false) {
        if (tracks.isEmpty()) return
        original = null
        // A new list: the old radio (and any mix still loading for it) is gone.
        radioGen++
        radioJob = null
        radioKeys = emptySet()
        radioFrom = null
        // The queue keeps one entry per song (Media3 needs unique ids): drop repeats, keep the tapped song's place.
        // Shuffle starts on a random song, not always the list's first.
        val first = if (shuffled) tracks.random() else tracks.getOrNull(start.coerceIn(tracks.indices))
        queue = tracks.distinctBy { it.key }
        index = queue.indexOfFirst { it.key == first?.key }.coerceAtLeast(0)
        if (shuffled) shuffleUpcoming(true) else _shuffle = false
        playWhenReady = true
        startCurrent()
    }

    fun playNext(t: Track) {
        if (queue.isEmpty()) return playList(listOf(t))
        if (t.key == current()?.key) { message = "Already playing"; return refresh() }
        val cur = current()
        queue = queue.filter { it.key != t.key }.toMutableList()
        index = queue.indexOfFirst { it.key == cur?.key }.coerceAtLeast(0)
        queue = queue.toMutableList().apply { add(index + 1, t) }
        original = original?.let { o -> o.filter { it.key != t.key } + t }
        message = "Plays next: ${t.title}"
        changed()
    }

    fun addToQueue(t: Track) {
        if (queue.isEmpty()) return playList(listOf(t))
        if (queue.any { it.key == t.key }) { message = "Already in the queue"; return refresh() }
        // Your songs go before the autoplay ones (like Spotify): after the last song you queued, ahead of the mix.
        val firstAuto = queue.indexOfFirst { q -> queue.indexOf(q) > index && q.key in radioKeys }
        queue = if (firstAuto < 0) queue + t else queue.toMutableList().apply { add(firstAuto, t) }
        original = original?.plus(t)
        message = "Added to queue: ${t.title}"
        changed()
    }

    fun removeAt(i: Int) {
        if (i !in queue.indices || i == index) return
        val t = queue[i]
        queue = queue.filterIndexed { j, _ -> j != i }
        original = original?.filter { it.key != t.key }
        if (i < index) index--
        message = "Removed from queue: ${t.title}"
        changed()
    }

    fun move(from: Int, to: Int) {
        if (from !in queue.indices || to !in queue.indices || from == to) return
        val cur = current()
        queue = queue.toMutableList().apply { add(to, removeAt(from)) }
        index = queue.indexOfFirst { it.key == cur?.key }
        changed()
    }

    fun jumpTo(i: Int) {
        if (i !in queue.indices) return
        index = i
        playWhenReady = true
        startCurrent()
    }

    fun toggle() = if (playWhenReady) pauseNow() else resumeNow()

    fun positionMs(): Long = when (current()?.source) {
        null -> 0
        Source.LOCAL -> exo.currentPosition
        else -> engine()?.last?.let { s ->
            val drift = if (!s.paused && s.at > 0) System.currentTimeMillis() - s.at else 0
            (s.position * 1000).toLong() + drift
        } ?: 0
    }

    fun durationMs(): Long {
        val t = current() ?: return 0
        val live = when (t.source) {
            Source.LOCAL -> exo.duration.takeIf { it != C.TIME_UNSET } ?: 0
            else -> engine()?.last?.duration?.let { (it * 1000).toLong() } ?: 0
        }
        // YouTube can stretch the page's duration as it glides into the next song: the song's own length wins.
        if (t.source == Source.YOUTUBE && t.durationMs > 0 && live > t.durationMs + 5000) return t.durationMs
        return if (live > 0) live else t.durationMs
    }

    fun seekMs(ms: Long) {
        when (current()?.source) {
            null -> {}
            Source.LOCAL -> exo.seekTo(ms)
            else -> engine()?.seek(ms / 1000.0)
        }
        refresh()
    }

    private var _shuffle = false

    fun setShuffle(on: Boolean) {
        shuffleUpcoming(on)
        changed()
    }

    /** Drops the songs autoplay added after the current one (Up next → Clear autoplay). */
    fun clearAutoplay() {
        val cur = current()
        queue = queue.filterIndexed { i, t -> i <= index || t.key !in radioKeys }
        original = original?.filter { it.key !in radioKeys || it.key == cur?.key }
        index = queue.indexOfFirst { it.key == cur?.key }
        changed()
    }

    fun cycleRepeat() {
        repeat = when (repeat) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
            Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
        changed()
    }

    fun clearMessage() {
        message = null
        refresh()
    }

    // MARK: playing

    private fun engine(): WebEngine? = current()?.let { t -> service(t)?.let { engines[it] } }
    private fun service(t: Track) = when (t.source) {
        Source.YOUTUBE -> Service.YOUTUBE
        Source.SPOTIFY -> Service.SPOTIFY
        Source.LOCAL -> null
    }

    private fun engineFor(s: Service) = engines.getOrPut(s) {
        WebEngine(context, s, { st -> onWebState(s, st) }, { why -> onWebEnded(s, "page: $why") }).also { if (Levels.wanted) syncLevels() }
    }

    // MARK: the dot displays' spectrum (only while one is on screen)

    private val levelsTick = object : Runnable {
        override fun run() {
            if (!Levels.wanted) return
            if (current()?.source == Source.LOCAL) Levels.tickLocal(exo.currentPosition, exo.isPlaying)
            mainHandler.postDelayed(this, 100) // 10 a second: smooth enough for dots, light on the CPU
        }
    }

    /** Who measures: ExoPlayer's tap for phone files, the page for YouTube; Spotify can't be measured. */
    private fun syncLevels() {
        val src = current()?.source
        val on = Levels.wanted
        engines[Service.YOUTUBE]?.levels(on && src == Source.YOUTUBE)
        mainHandler.removeCallbacks(levelsTick)
        if (on && src == Source.LOCAL) mainHandler.post(levelsTick)
        if (src != Source.LOCAL && src != Source.YOUTUBE) Levels.clear()
    }

    private fun startCurrent() {
        val t = current() ?: return
        message = null
        buffering = true
        startedAt = System.currentTimeMillis()
        lastPos = 0.0
        baseDur = 0.0
        seenV = null
        lastMoved = startedAt
        nudged = false
        val svc = service(t)
        warmUpcoming()
        mainHandler.removeCallbacks(parkIdle)
        mainHandler.postDelayed(parkIdle, 120_000)
        Levels.clear()
        quality = Quality.cached(t)
        if (t.source == Source.LOCAL && quality == null) io.execute {
            val q = Quality.of(context, t)
            mainHandler.post { if (current()?.key == t.key) { quality = q; refresh() } }
        }
        // Only one thing plays at a time.
        engines.filterKeys { it != svc }.values.forEach { it.stop() }
        if (svc == null) {
            onWebPlaying(false)
            exo.setMediaItem(MediaItem.fromUri(Uri.parse(t.id)))
            exo.prepare()
            exo.playWhenReady = playWhenReady
            Eq.attach(exo.audioSessionId)
        } else {
            exo.stop()
            val e = engineFor(svc)
            if (playWhenReady) e.playTrack(t.id) else e.stop()
            onWebPlaying(playWhenReady)
        }
        library.played(t)
        if (Levels.wanted) syncLevels()
        changed()
    }

    private fun pauseNow() {
        playWhenReady = false
        if (current()?.source == Source.LOCAL) exo.pause() else engine()?.pause()
        onWebPlaying(false)
        refresh()
    }

    private fun resumeNow() {
        val t = current() ?: return
        playWhenReady = true
        when {
            t.source == Source.LOCAL -> { if (exo.playbackState == Player.STATE_IDLE || exo.playbackState == Player.STATE_ENDED) startCurrent() else exo.play() }
            engine()?.last?.hasMedia == true -> { engine()?.play(); onWebPlaying(true) }
            else -> startCurrent() // the page was never loaded (e.g. after a restart)
        }
        refresh()
    }

    private var lastPos = 0.0
    private var lastDur = 0.0
    private var seenV: String? = null // the video id the YouTube page first showed for this song; a change means it moved on by itself
    private var baseDur = 0.0 // the page's duration for the song we started (YouTube can stretch it when it glides on)
    private var lastMoved = 0L
    private var nudged = false

    private fun onWebState(s: Service, st: WebState) {
        val t = current()
        if (t == null || service(t) != s) return
        // Started = the song's clock moves. (Spotify's bar says "playing" at 0:00 while its copy protection loads — that's
        // still starting, not a stall.)
        if (!st.paused && (st.position > 0.5 || (st.hasMedia && s != Service.SPOTIFY))) buffering = false
        // The service moved on by itself (autoplay after our song, without an ended event): that was the end.
        val wrapped = lastDur > 5 && lastPos > lastDur - 4 && st.position < 2 && !st.ad
        val now = System.currentTimeMillis()
        // YouTube Music also glides into the next song on the same stream (position keeps counting, no ended event):
        // the page's video id is no longer ours and we're at/after our song's end.
        if (baseDur <= 0 && st.duration > 0 && st.position < 30 && !st.ad) baseDur = st.duration
        if (s == Service.YOUTUBE && !st.ad && now - startedAt > 5000) {
            val v = Regex("[?&]v=([^&#]+)").find(st.url)?.groupValues?.get(1)
            if (v != null) { if (seenV == null) seenV = v else if (v != seenV) return onWebEnded(s, "video id changed") }
            val ours = if (t.durationMs > 0) t.durationMs / 1000.0 else baseDur
            if (v != null && v != t.id && ours > 0 && st.position >= ours - 5) return onWebEnded(s, "glided into the next video")
        }
        if (!st.ad) Quality.youtube(st.itag)?.let { if (it != quality) { quality = it; Quality.put(t, it) } }
        if (st.position != lastPos || st.paused || st.ad) lastMoved = now
        lastPos = st.position
        lastDur = st.duration
        if (wrapped && now - startedAt > 5000) return onWebEnded(s, "clock wrapped to 0")
        // "Playing" but the clock stopped: near the end that's the end (Spotify can stall in its last seconds);
        // mid-song, nudge it once, then give up on it.
        if (playWhenReady && !buffering && st.duration > 0 && now - lastMoved > 6000) {
            if (st.position > st.duration - 12) return onWebEnded(s, "stalled near the end")
            if (now - lastMoved > 20_000) return failed("The song stalled")
            if (!nudged) { nudged = true; engine()?.play() }
        }
        // Nothing playing 25 s after we asked: say so and go on.
        // (Spotify gets longer: the first song after the app starts loads its copy protection first.)
        if (playWhenReady && buffering && System.currentTimeMillis() - startedAt > (if (s == Service.SPOTIFY) 45_000 else 25_000)) {
            return failed(if (s == Service.SPOTIFY) "Spotify didn't start — signed in?" else "YouTube didn't start this song")
        }
        // The page paused on its own (e.g. another device took over the account): follow it.
        if (!buffering && st.paused && playWhenReady && st.hasMedia && System.currentTimeMillis() - startedAt > 8000 && !st.ad && st.position > 1) {
            playWhenReady = false
            onWebPlaying(false)
        }
        refresh()
    }

    private fun onWebEnded(s: Service, why: String = "ended event") {
        event("end ${s.name}: $why")
        val t = current() ?: return
        if (service(t) != s) return
        if (System.currentTimeMillis() - startedAt < 4000) return // a previous song's end arriving late
        trackEnded()
    }

    /**
     * A Spotify song coming up soon and Spotify not playing now: load its page ahead of time, so its copy protection
     * is ready (else the first Spotify song after a start hangs at 0:00 for ~20 s).
     */
    /**
     * Pages not playing and not needed for the next two songs are unloaded after 2 minutes (memory, timers); a later
     * song from that service loads its page again (a couple of seconds).
     */
    private val parkIdle = Runnable {
        val cur = current()?.let { service(it) }
        val soon = queue.drop(index + 1).take(2).mapNotNull { service(it) }.toSet()
        engines.filterKeys { it != cur && it !in soon }.values.forEach { it.park() }
    }

    private fun warmUpcoming() {
        val cur = current() ?: return
        if (cur.source == Source.SPOTIFY) return
        if (queue.drop(index + 1).take(2).any { it.source == Source.SPOTIFY }) engineFor(Service.SPOTIFY).warm()
    }

    // MARK: autoplay (song radio)

    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)
    /** Keep going with similar music when the queue runs out (like Spotify's Autoplay / YouTube Music's radio). */
    var autoplay: Boolean
        get() = prefs.getBoolean("autoplay", true)
        set(v) { prefs.edit().putBoolean("autoplay", v).apply(); if (v) maybeAutoplay() else refresh() }
    private var radioKeys: Set<String> = emptySet()
    private var radioFrom: String? = null
    private var radioJob: kotlinx.coroutines.Job? = null
    private var radioGen = 0
    private val scope = kotlinx.coroutines.MainScope()

    /**
     * On the last or second-last song (and not repeating): fetch songs similar to the one playing and add them to the
     * queue, so a single searched song becomes a radio and a finished playlist carries on.
     */
    private fun maybeAutoplay() {
        val seed = current() ?: return
        if (!autoplay || repeat != Player.REPEAT_MODE_OFF || index < queue.size - 2 || radioJob != null) return
        val gen = radioGen
        radioJob = scope.launch {
            val exclude = queue.map { it.key }.toSet() + queue.map { Radio.name(it) } + library.data.value.recent.take(30).map { Radio.name(it) }
            val found = runCatching { Radio.similar(context, seed, exclude) }.getOrDefault(emptyList())
            if (gen != radioGen) return@launch // the queue was replaced meanwhile
            radioJob = null
            if (found.isEmpty()) { refresh(); return@launch }
            val fresh = found.filter { f -> queue.none { it.key == f.key } }
            queue = queue + fresh
            original = original?.plus(fresh)
            radioKeys = radioKeys + fresh.map { it.key }
            radioFrom = seed.title
            changed()
        }
        refresh()
    }

    private fun trackEnded() {
        engine()?.stop()
        when {
            repeat == Player.REPEAT_MODE_ONE -> startCurrent()
            index + 1 < queue.size -> { index++; startCurrent() }
            repeat == Player.REPEAT_MODE_ALL && queue.isNotEmpty() -> { index = 0; startCurrent() }
            else -> { playWhenReady = false; buffering = false; onWebPlaying(false); refresh() }
        }
    }

    private fun failed(why: String) {
        event("failed: $why")
        message = why
        buffering = false
        if (index + 1 < queue.size) { index++; startCurrent() } else { playWhenReady = false; onWebPlaying(false); refresh() }
    }

    private fun shuffleUpcoming(on: Boolean) {
        val cur = current()
        if (on && !_shuffle) {
            original = queue
            val upcoming = queue.drop(index + 1).shuffled()
            queue = queue.take(index + 1) + upcoming
        } else if (!on && _shuffle) {
            original?.let { o -> queue = o; index = o.indexOfFirst { it.key == cur?.key }.coerceAtLeast(0) }
            original = null
        }
        _shuffle = on
    }

    // MARK: state for Android and the app

    private fun changed() {
        save()
        refresh()
        maybeAutoplay()
    }

    private fun refresh() {
        // After a restart nothing was started yet: the label is still known from the library scan.
        if (quality == null) current()?.let { quality = Quality.cached(it) }
        val u = Ui(queue, index, isPlayingNow(), buffering && playWhenReady, _shuffle, repeat, message, quality, radioKeys, radioFrom, radioJob != null)
        val widget = u.copy(message = null) != _ui.value.copy(message = null)
        _ui.value = u
        publish(u)
        if (widget) PlayerWidget.render()
    }

    private var pubSig = ""
    private var pubPos = 0L
    private var pubAt = 0L
    private var pubPlaying = false

    /**
     * Tells Android (media session → notification, lock screen, Bluetooth) only when something it shows changed, or the
     * position jumped (a seek, or a web page drifting). Each update makes the Bluetooth stack re-send media info to
     * the headphones over the same link as the audio; doing that every few seconds made Bluetooth audio drop out.
     */
    private fun publish(u: Ui) {
        val now = android.os.SystemClock.elapsedRealtime()
        val pos = positionMs()
        val sig = "${u.queue.size}|${u.current?.key}|$playWhenReady|${u.playing}|${u.buffering}|$_shuffle|$repeat|${durationMs() / 1000}"
        val expected = if (pubPlaying) pubPos + (now - pubAt) else pubPos
        if (sig == pubSig && kotlin.math.abs(pos - expected) < 2500) return
        pubSig = sig
        pubPos = pos
        pubAt = now
        pubPlaying = u.playing
        invalidateState()
    }

    private fun isPlayingNow() = when (current()?.source) {
        null -> false
        Source.LOCAL -> exo.isPlaying || (playWhenReady && exo.playbackState == Player.STATE_BUFFERING)
        else -> playWhenReady
    }

    override fun getState(): State {
        val items = queue.distinctBy { it.key }.map { t ->
            MediaItemData.Builder(t.key)
                .setMediaItem(t.toMediaItem())
                .setDurationUs(if (t.key == current()?.key && durationMs() > 0) durationMs() * 1000 else if (t.durationMs > 0) t.durationMs * 1000 else C.TIME_UNSET)
                .setIsSeekable(true)
                .build()
        }
        val state = when {
            queue.isEmpty() -> Player.STATE_IDLE
            buffering && playWhenReady -> Player.STATE_BUFFERING
            !playWhenReady && index == queue.size - 1 && positionMs() >= durationMs() - 1000 && durationMs() > 0 -> Player.STATE_ENDED
            else -> Player.STATE_READY
        }
        return State.Builder()
            .setAvailableCommands(Player.Commands.Builder().addAll(
                Player.COMMAND_PLAY_PAUSE, Player.COMMAND_PREPARE, Player.COMMAND_STOP, Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM,
                Player.COMMAND_SEEK_TO_NEXT, Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, Player.COMMAND_SEEK_TO_PREVIOUS,
                Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM, Player.COMMAND_SEEK_TO_MEDIA_ITEM, Player.COMMAND_SEEK_TO_DEFAULT_POSITION,
                Player.COMMAND_SET_SHUFFLE_MODE, Player.COMMAND_SET_REPEAT_MODE, Player.COMMAND_GET_CURRENT_MEDIA_ITEM,
                Player.COMMAND_GET_TIMELINE, Player.COMMAND_GET_METADATA, Player.COMMAND_SET_MEDIA_ITEM, Player.COMMAND_CHANGE_MEDIA_ITEMS,
                Player.COMMAND_RELEASE,
            ).build())
            .setPlaylist(items)
            .setCurrentMediaItemIndex(index.coerceAtLeast(0))
            // A fixed position while paused (and an extrapolating one while playing) so Media3 notices a seek made while
            // paused and updates the notification / lock screen; a live lambda looked unchanged to it.
            // Fixed, so it doesn't change every tick (each change is another update sent to Bluetooth).
            .setContentBufferedPositionMs(SimpleBasePlayer.PositionSupplier.getConstant(maxOf(durationMs(), positionMs())))
            .setContentPositionMs(if (isPlayingNow()) SimpleBasePlayer.PositionSupplier.getExtrapolating(positionMs(), 1f) else SimpleBasePlayer.PositionSupplier.getConstant(positionMs()))
            .setPlayWhenReady(playWhenReady, Player.PLAY_WHEN_READY_CHANGE_REASON_USER_REQUEST)
            .setPlaybackState(state)
            .setIsLoading(buffering)
            .setShuffleModeEnabled(_shuffle)
            .setRepeatMode(repeat)
            .build()
    }

    // Commands from Android (notification, lock screen, headset, Bluetooth, widget).
    override fun handleSetPlayWhenReady(play: Boolean): ListenableFuture<*> {
        if (play) resumeNow() else pauseNow()
        return Futures.immediateVoidFuture()
    }

    override fun handlePrepare(): ListenableFuture<*> = Futures.immediateVoidFuture()

    override fun handleStop(): ListenableFuture<*> {
        pauseNow()
        return Futures.immediateVoidFuture()
    }

    override fun handleSeek(mediaItemIndex: Int, positionMs: Long, seekCommand: Int): ListenableFuture<*> {
        val target = if (mediaItemIndex == C.INDEX_UNSET) index else mediaItemIndex
        if (target != index && target in queue.indices) {
            index = target
            startCurrent()
        } else if (seekCommand == Player.COMMAND_SEEK_TO_PREVIOUS && positionMs == 0L) {
            seekMs(0)
        } else if (positionMs != C.TIME_UNSET) {
            seekMs(positionMs)
        }
        return Futures.immediateVoidFuture()
    }

    override fun handleSetShuffleModeEnabled(enabled: Boolean): ListenableFuture<*> {
        setShuffle(enabled)
        return Futures.immediateVoidFuture()
    }

    override fun handleSetRepeatMode(mode: Int): ListenableFuture<*> {
        repeat = mode
        changed()
        return Futures.immediateVoidFuture()
    }

    override fun handleSetMediaItems(mediaItems: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long): ListenableFuture<*> {
        val tracks = mediaItems.mapNotNull { m -> queue.firstOrNull { it.key == m.mediaId } }
        if (tracks.isNotEmpty()) playList(tracks, startIndex.coerceAtLeast(0))
        return Futures.immediateVoidFuture()
    }

    override fun handleRelease(): ListenableFuture<*> {
        save()
        exo.release()
        engines.values.forEach { it.destroy() }
        return Futures.immediateVoidFuture()
    }

    // MARK: saved queue (what was playing comes back after a restart, paused)

    private fun save() = runCatching {
        queueFile.writeText(JSONObject().put("queue", queue.toJsonArray()).put("index", index).put("shuffle", _shuffle)
            .put("repeat", repeat).put("position", positionMs()).toString())
    }

    private fun restore() {
        // A bad saved queue must never stop the service from starting: on any problem, forget it.
        runCatching {
            val j = JSONObject(queueFile.readText())
            val saved = j.optJSONArray("queue").toTracks()
            val at = saved.getOrNull(j.optInt("index", -1))
            queue = saved.distinctBy { it.key }
            index = queue.indexOfFirst { it.key == at?.key }.let { if (it < 0) queue.size.coerceAtMost(1) - 1 else it }
            _shuffle = j.optBoolean("shuffle")
            repeat = j.optInt("repeat")
        }.onFailure { queue = emptyList(); index = -1; _shuffle = false; runCatching { queueFile.delete() } }
        refresh()
    }

    fun savePosition() = save()

    // Last, so every field above is set before the saved queue is restored.
    init {
        Eq.load(context)
        Eq.onChange = { g -> engines.values.forEach { it.eq(g) } }
        Levels.onWantedChanged = { mainHandler.post { syncLevels() } }
        restore()
    }

    /** A line in player.log (for testing over USB): why a song ended or was skipped. */
    private fun event(what: String) = runCatching {
        java.io.File(context.getExternalFilesDir(null), "player.log").appendText(
            "${java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.US).format(java.util.Date())} EVENT $what (${current()?.title}, ${positionMs() / 1000}s)\n")
    }

    /** The playing page's raw state, for the log. */
    fun webDebug(): String = engine()?.last?.let { "page paused=${it.paused} media=${it.hasMedia} ad=${it.ad} buffering=$buffering want=$playWhenReady hiccups=${it.hiccups} waits=${it.waits}" } ?: "local"

}

fun Track.toMediaItem(): MediaItem = MediaItem.Builder()
    .setMediaId(key)
    .setMediaMetadata(MediaMetadata.Builder()
        .setTitle(title)
        .setArtist(artist)
        .setAlbumTitle(album)
        .setArtworkUri(art?.let { Uri.parse(it) })
        .setDisplayTitle(title)
        .setSubtitle(artist)
        .setIsPlayable(true)
        .setIsBrowsable(false)
        .build())
    .build()
