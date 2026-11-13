import AppKit
import Combine
import MediaPlayer

/// The one player behind everything: a queue of tracks from any source. Mac files play in LocalAudio, YouTube Music
/// in its hidden page (YouTubeEngine), Spotify in the Spotify app (SpotifyApp). To macOS (Now Playing, media keys,
/// AirPods / headset buttons) it's a single player.
///
/// The queue is ours: when a song ends — or a service tries to carry on with its own autoplay — that source is stopped
/// and the next track of our queue starts, whatever its source. (A port of the Android Player's HybridPlayer.)
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    enum Repeat: Int, Codable { case off = 0, all = 1, one = 2 }

    @Published private(set) var queue: [Track] = []
    @Published private(set) var index = -1
    @Published private(set) var playWhenReady = false
    @Published private(set) var buffering = false
    @Published private(set) var shuffle = false
    @Published private(set) var repeatMode: Repeat = .off
    @Published private(set) var message: String?
    /// What's playing, technically: "FLAC · 24/96 · 2,612 kbps", "OPUS · ~160 kbps".
    @Published private(set) var quality: String?
    /// Songs autoplay added (similar to what was playing), and the song the latest mix came from.
    @Published private(set) var radioKeys: Set<String> = []
    @Published private(set) var radioFrom: String?
    @Published private(set) var radioLoading = false

    var current: Track? { queue[safe: index] }
    var playing: Bool { playWhenReady && current != nil }

    private var original: [Track]?
    private var startedAt = Date()
    private let local = LocalAudio()
    private lazy var youtube: YouTubeEngine = {
        let e = YouTubeEngine()
        e.onState = { [weak self] s in self?.onYouTube(s) }
        e.onEnded = { [weak self] why in self?.webEnded(.youtube, why) }
        return e
    }()
    private let spotify = SpotifyApp()
    private var spState: (state: SpotifyApp.State, at: Date)?
    private var radioTask: Task<Void, Never>?
    private var radioGen = 0
    private var messageClear: DispatchWorkItem?

    private init() {
        local.onEnd = { [weak self] in self?.trackEnded() }
        spotify.onState = { [weak self] s in self?.onSpotify(s) }
        EQ.shared.onChange = { [weak self] g in if self?.current?.source == .youtube { self?.youtube.eq(g) } }
        Levels.shared.onWantedChanged = { [weak self] _ in self?.syncLevels() }
        restore()
        setUpRemoteCommands()
    }

    // MARK: what the app calls

    func playList(_ tracks: [Track], start: Int = 0, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        original = nil
        // A new list: the old radio (and any mix still loading for it) is gone.
        radioGen += 1
        radioTask?.cancel(); radioTask = nil; radioLoading = false
        radioKeys = []; radioFrom = nil
        // One entry per song; shuffle starts on a random song.
        let first = shuffled ? tracks.randomElement() : tracks[safe: max(0, min(start, tracks.count - 1))]
        var seen = Set<String>()
        queue = tracks.filter { seen.insert($0.key).inserted }
        index = max(0, queue.firstIndex { $0.key == first?.key } ?? 0)
        shuffle = false
        if shuffled { shuffleUpcoming(true) }
        playWhenReady = true
        startCurrent()
    }

    func playNext(_ t: Track) {
        if queue.isEmpty { return playList([t]) }
        if t.key == current?.key { return say("Already playing") }
        let cur = current
        queue.removeAll { $0.key == t.key }
        index = max(0, queue.firstIndex { $0.key == cur?.key } ?? 0)
        queue.insert(t, at: index + 1)
        original = original.map { $0.filter { $0.key != t.key } + [t] }
        say("Plays next: \(t.title)")
        changed()
    }

    func addToQueue(_ t: Track) {
        if queue.isEmpty { return playList([t]) }
        if queue.contains(where: { $0.key == t.key }) { return say("Already in the queue") }
        // Your songs go before the autoplay ones.
        if let firstAuto = queue.indices.first(where: { $0 > index && radioKeys.contains(queue[$0].key) }) {
            queue.insert(t, at: firstAuto)
        } else {
            queue.append(t)
        }
        original?.append(t)
        say("Added to queue: \(t.title)")
        changed()
    }

    func remove(at i: Int) {
        guard queue.indices.contains(i), i != index else { return }
        let t = queue.remove(at: i)
        original?.removeAll { $0.key == t.key }
        if i < index { index -= 1 }
        say("Removed from queue: \(t.title)")
        changed()
    }

    func move(_ from: Int, _ to: Int) {
        guard queue.indices.contains(from), queue.indices.contains(to), from != to else { return }
        let cur = current
        queue.insert(queue.remove(at: from), at: to)
        index = queue.firstIndex { $0.key == cur?.key } ?? index
        changed()
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        index = i
        playWhenReady = true
        startCurrent()
    }

    func toggle() { playWhenReady ? pause() : resume() }

    func next() {
        guard !queue.isEmpty else { return }
        if index + 1 < queue.count { index += 1 } else if repeatMode == .all { index = 0 } else { return }
        playWhenReady = true
        startCurrent()
    }

    /// Restarts the song if more than 3 s in; otherwise the previous song.
    func previous() {
        guard current != nil else { return }
        if position > 3 || index == 0 { seek(0); return }
        index -= 1
        playWhenReady = true
        startCurrent()
    }

    var position: Double {
        guard let t = current else { return 0 }
        switch t.source {
        case .local: return local.position
        case .youtube:
            let s = youtube.last
            return s.position + (!s.paused ? Date().timeIntervalSince(s.at) : 0)
        case .spotify:
            guard let s = spState, s.state.trackID == t.id else { return 0 }
            return s.state.position + (s.state.playing ? Date().timeIntervalSince(s.at) : 0)
        }
    }

    var duration: Double {
        guard let t = current else { return 0 }
        let live: Double
        switch t.source {
        case .local: live = local.duration
        case .youtube: live = youtube.last.duration
        case .spotify: live = spState?.state.trackID == t.id ? spState!.state.duration : 0
        }
        // YouTube can stretch the page's duration as it glides into the next song: the song's own length wins.
        if t.source == .youtube, t.duration > 0, live > t.duration + 5 { return t.duration }
        return live > 0 ? live : t.duration
    }

    func seek(_ s: Double) {
        guard let t = current else { return }
        switch t.source {
        case .local: local.seek(s)
        case .youtube: youtube.seek(s)
        case .spotify: spotify.seek(s); if var st = spState { st.state.position = s; st.at = Date(); spState = st }
        }
        publish()
    }

    func skip(_ by: Double) { seek(max(0, min(duration - 1, position + by))) }

    func setShuffle(_ on: Bool) { shuffleUpcoming(on); changed() }

    func cycleRepeat() {
        repeatMode = repeatMode == .off ? .all : repeatMode == .all ? .one : .off
        changed()
    }

    /// Drops the songs autoplay added after the current one.
    func clearAutoplay() {
        let cur = current
        queue = queue.enumerated().filter { $0.offset <= index || !radioKeys.contains($0.element.key) }.map(\.element)
        original = original?.filter { !radioKeys.contains($0.key) || $0.key == cur?.key }
        index = queue.firstIndex { $0.key == cur?.key } ?? index
        radioKeys = []
        changed()
    }

    func setAutoplay(_ on: Bool) { Prefs.autoplay = on; if on { maybeAutoplay() }; objectWillChange.send() }

    // MARK: playing

    private var lastPos = 0.0, lastDur = 0.0, baseDur = 0.0, lastMoved = Date(), nudged = false
    private var seenV: String?

    private func startCurrent() {
        guard let t = current else { return }
        message = nil
        buffering = true
        startedAt = Date()
        lastPos = 0; lastDur = 0; baseDur = 0; seenV = nil; lastMoved = startedAt; nudged = false
        Levels.shared.clear()
        quality = Quality.cached(t)
        // Only one thing plays at a time.
        if t.source != .local { local.stop() }
        if t.source != .youtube { youtube.stop() }
        if t.source != .spotify { spotify.stop(); spState = nil }
        switch t.source {
        case .local:
            do {
                try local.load(t.id)
                buffering = false
                if playWhenReady { local.play() }
            } catch {
                return failed("Couldn't play this file")
            }
        case .youtube:
            if playWhenReady { youtube.playTrack(t.id) } else { youtube.stop() }
        case .spotify:
            guard SpotifyApp.installed else { return failed("Spotify songs need the Spotify app") }
            spState = nil
            if playWhenReady { spotify.play(t.id) }
        }
        Library.shared.played(t)
        syncLevels()
        changed()
    }

    func pause() {
        playWhenReady = false
        switch current?.source {
        case .local: local.pause()
        case .youtube: youtube.pause()
        case .spotify: spotify.pause()
        case nil: break
        }
        publish()
    }

    func resume() {
        guard let t = current else { return }
        playWhenReady = true
        switch t.source {
        case .local: if local.hasFile { local.play() } else { startCurrent() }
        case .youtube: if youtube.last.hasMedia { youtube.play() } else { startCurrent() }
        case .spotify: if spState?.state.trackID == t.id { spotify.resume() } else { startCurrent() }
        }
        publish()
    }

    // MARK: YouTube's page

    private func onYouTube(_ st: WebState) {
        guard let t = current, t.source == .youtube else { return }
        let now = Date()
        if !st.paused, st.hasMedia { buffering = false }
        if baseDur <= 0, st.duration > 0, st.position < 30, !st.ad { baseDur = st.duration }
        if !st.ad, now.timeIntervalSince(startedAt) > 5 {
            // YouTube Music glides into the next song on the same stream (no ended event): its video id isn't ours.
            let v = st.url.range(of: #"[?&]v=([^&#]+)"#, options: .regularExpression).map { String(st.url[$0].dropFirst(3)) }
            if let v {
                if seenV == nil { seenV = v } else if v != seenV { return webEnded(.youtube, "video id changed") }
                let ours = t.duration > 0 ? t.duration : baseDur
                if v != t.id, ours > 0, st.position >= ours - 5 { return webEnded(.youtube, "glided into the next video") }
            }
        }
        if !st.ad, let q = Quality.youtube(st.itag), q != quality { quality = q; Quality.put(t, q) }
        let wrapped = lastDur > 5 && lastPos > lastDur - 4 && st.position < 2 && !st.ad
        if st.position != lastPos || st.paused || st.ad { lastMoved = now }
        lastPos = st.position; lastDur = st.duration
        if wrapped, now.timeIntervalSince(startedAt) > 5 { return webEnded(.youtube, "clock wrapped to 0") }
        // "Playing" but the clock stopped: near the end that's the end; mid-song nudge it once, then give up.
        if playWhenReady, !buffering, st.duration > 0, now.timeIntervalSince(lastMoved) > 6 {
            if st.position > st.duration - 12 { return webEnded(.youtube, "stalled near the end") }
            if now.timeIntervalSince(lastMoved) > 20 { return failed("The song stalled") }
            if !nudged { nudged = true; youtube.play() }
        }
        if playWhenReady, buffering, now.timeIntervalSince(startedAt) > 25 { return failed("YouTube didn't start this song") }
        publish()
    }

    // MARK: the Spotify app

    private func onSpotify(_ s: SpotifyApp.State) {
        guard let t = current, t.source == .spotify else { return }
        let now = Date()
        let prev = spState?.state
        spState = (s, now)
        if s.trackID == t.id, s.playing, s.position > 0.3 { buffering = false }
        let since = now.timeIntervalSince(startedAt)
        if since > 6, !buffering {
            // Spotify carried on to a song of its own: ours has ended.
            if let id = s.trackID, id != t.id { spotify.pause(); return webEnded(.spotify, "spotify moved on") }
            // It stopped at the end of ours.
            if let p = prev, p.playing, !s.playing, p.duration > 0, p.position > p.duration - 3 { return webEnded(.spotify, "stopped at the end") }
            // Paused from the Spotify app or another device: follow it.
            if playWhenReady, !s.playing, s.position > 1 { playWhenReady = false }
        }
        if playWhenReady, buffering, since > 30 { return failed(s.running ? "Spotify didn't start this song" : "Spotify didn't open") }
        publish()
    }

    private func webEnded(_ src: Source, _ why: String) {
        guard current?.source == src, Date().timeIntervalSince(startedAt) > 4 else { return }
        trackEnded()
    }

    private func trackEnded() {
        if current?.source == .youtube { youtube.stop() }
        switch true {
        case repeatMode == .one: startCurrent()
        case index + 1 < queue.count: index += 1; startCurrent()
        case repeatMode == .all && !queue.isEmpty: index = 0; startCurrent()
        default: playWhenReady = false; buffering = false; publish()
        }
    }

    private func failed(_ why: String) {
        say(why)
        buffering = false
        if index + 1 < queue.count { index += 1; startCurrent() } else { playWhenReady = false; publish() }
    }

    private func say(_ m: String) {
        message = m
        messageClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.message = nil }
        messageClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
        publish()
    }

    /// Who measures: the engine tap for Mac files, the page for YouTube; Spotify can't be measured.
    private func syncLevels() {
        let on = Levels.shared.wanted
        let src = current?.source
        local.spectrum(on && src == .local)
        if src == .youtube { youtube.levels(on) }
        if src == .spotify { Levels.shared.clear() }
    }

    // MARK: autoplay (song radio)

    /// On the last or second-last song (and not repeating): fetch songs similar to the one playing and add them.
    private func maybeAutoplay() {
        guard let seed = current, Prefs.autoplay, repeatMode == .off, index >= queue.count - 2, radioTask == nil else { return }
        let gen = radioGen
        radioLoading = true
        radioTask = Task { [weak self] in
            guard let self else { return }
            let recent = Library.shared.data.recent.prefix(30).map(Radio.name)
            let exclude = Set(self.queue.map(\.key) + self.queue.map(Radio.name) + recent)
            let found = await Radio.similar(to: seed, excluding: exclude)
            guard gen == radioGen else { return }
            radioTask = nil
            radioLoading = false
            let current = self.queue
            let fresh = found.filter { f in !current.contains { $0.key == f.key } }
            guard !fresh.isEmpty else { return publish() }
            queue += fresh
            original? += fresh
            radioKeys.formUnion(fresh.map(\.key))
            radioFrom = seed.title
            changed()
        }
    }

    private func shuffleUpcoming(_ on: Bool) {
        let cur = current
        if on && !shuffle {
            original = queue
            queue = Array(queue.prefix(index + 1)) + queue.dropFirst(index + 1).shuffled()
        } else if !on && shuffle, let o = original {
            queue = o
            index = max(0, o.firstIndex { $0.key == cur?.key } ?? 0)
            original = nil
        }
        shuffle = on
    }

    // MARK: state out

    private func changed() {
        save()
        publish()
        maybeAutoplay()
    }

    private var lastNowPlayingKey: String?

    /// Tells macOS (Now Playing, Control Centre) and the widgets.
    func publish() {
        objectWillChange.send()
        let center = MPNowPlayingInfoCenter.default()
        if let t = current {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artist,
                MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
                MPNowPlayingInfoPropertyPlaybackRate: playWhenReady ? 1.0 : 0.0,
            ]
            if let a = t.album { info[MPMediaItemPropertyAlbumTitle] = a }
            if let art = center.nowPlayingInfo?[MPMediaItemPropertyArtwork], lastNowPlayingKey == t.key { info[MPMediaItemPropertyArtwork] = art }
            center.nowPlayingInfo = info
            center.playbackState = playWhenReady ? .playing : .paused
            if lastNowPlayingKey != t.key {
                lastNowPlayingKey = t.key
                Task {
                    guard let img = await Images.shared.load(t.art, size: 300), self.current?.key == t.key else { return }
                    var i = center.nowPlayingInfo ?? [:]
                    i[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
                    center.nowPlayingInfo = i
                }
            }
        } else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }
        WidgetBridge.shared.changed()
    }

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { self?.seek(e.positionTime) }
            return .success
        }
    }

    // MARK: saved queue (what was playing comes back after a restart, paused)

    private struct Saved: Codable { var queue: [Track]; var index: Int; var shuffle: Bool; var repeatMode: Repeat; var position: Double; var original: [Track]? }

    func save() {
        AppDirs.save(Saved(queue: queue, index: index, shuffle: shuffle, repeatMode: repeatMode, position: position, original: original), "queue.json")
    }

    private func restore() {
        // A bad saved queue must never stop the app from starting.
        guard let s = AppDirs.load(Saved.self, "queue.json") else { return }
        var seen = Set<String>()
        queue = s.queue.filter { seen.insert($0.key).inserted }
        index = queue.isEmpty ? -1 : max(0, min(s.index, queue.count - 1))
        shuffle = s.shuffle
        original = s.original
        repeatMode = s.repeatMode
        quality = current.flatMap(Quality.cached)
        // A Mac file is loaded (paused) at the saved position, so Play carries on where it was.
        if let t = current, t.source == .local, (try? local.load(t.id)) != nil { local.seek(s.position) }
    }
}
