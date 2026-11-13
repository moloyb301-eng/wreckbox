import AppKit
import SwiftUI

// MARK: - Home

struct HomePage: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var library = Library.shared
    @ObservedObject var local = LocalMusic.shared
    @ObservedObject var spotify = SpotifyAPI.shared

    var body: some View {
        PageScaffold(title: "Home") {
            nowCard.padding(.top, 10)
            if !spotify.connected || !SpotifyApp.installed {
                HStack {
                    Text(!SpotifyApp.installed ? "Spotify songs play in the Spotify app — install it to play them." : "Connect Spotify to search it too.")
                        .font(W.ui(13)).foregroundStyle(W.text2)
                    Spacer()
                    Pill(label: "Accounts", icon: "person.crop.circle", style: .smart) { Nav.shared.settings = true }
                }
                .padding(14).smartGlass(16).padding(.top, 12)
            }
            SectionHeader(title: "Liked songs", action: library.data.likes.isEmpty ? nil : "Shuffle") { player.playList(library.data.likes, shuffled: true) }
            if library.data.likes.isEmpty { hint("Like a song (♥) and it shows up here.") }
            else { TrackList(tracks: Array(library.data.likes.prefix(5))) }
            SectionHeader(title: "Your playlists", action: "All") { Nav.shared.page = .playlists }
            playlistShelf
            SectionHeader(title: "Recently played", action: library.data.recent.isEmpty ? nil : "Clear") { library.clearRecent() }
            if library.data.recent.isEmpty { hint("Songs you play show up here.") }
            else { TrackList(tracks: Array(library.data.recent.prefix(8))) }
            SectionHeader(title: "On this Mac", action: local.tracks.isEmpty ? nil : "Shuffle all") { player.playList(local.tracks, shuffled: true) }
            HStack(spacing: 10) {
                Pill(label: "Play all", icon: "play.fill", enabled: !local.tracks.isEmpty) { player.playList(local.tracks) }
                Pill(label: local.scanning ? "Scanning…" : "Rescan", icon: "arrow.clockwise", enabled: !local.scanning) { Task { await local.rescan() } }
                Text("\(local.tracks.count) songs").font(W.dot(11)).foregroundStyle(W.text3)
            }
            .padding(.bottom, 8)
            TrackList(tracks: Array(local.tracks.prefix(8)))
            if local.tracks.count > 8 { Button("Show all \(local.tracks.count)") { Nav.shared.page = .onMac }.buttonStyle(.plain).font(W.ui(13, .semibold)).foregroundStyle(W.lilac).padding(.top, 6) }
        }
    }

    private func hint(_ s: String) -> some View { Text(s).font(W.ui(13)).foregroundStyle(W.text3).padding(.vertical, 6) }

    /// "Now playing / paused" card with the candy play button.
    private var nowCard: some View {
        HStack(spacing: 16) {
            Cover(art: player.current?.art, size: 84, radius: 12, rim: player.current != nil)
            VStack(alignment: .leading, spacing: 4) {
                DotLabel(player.current == nil ? "Nothing playing" : player.playing ? "Now playing" : "Paused", color: W.lilac)
                Text(player.current?.title ?? "Search for a song, or play what's on this Mac").font(W.ui(19, .bold)).foregroundStyle(W.text).lineLimit(1)
                Text(player.current?.artist ?? "").font(W.ui(13)).foregroundStyle(W.text2).lineLimit(1)
            }
            Spacer()
            CandyButton(size: 58, playing: player.playing) { player.toggle() }
        }
        .padding(16)
        .glass(W.Radius.card)
        .contentShape(Rectangle())
        .onTapGesture { if player.current != nil { Nav.shared.page = .playing } }
    }

    private var playlistShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(library.data.playlists) { p in
                    Button { Nav.shared.page = .playlist(p.id) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Cover(art: p.tracks.first?.art, size: 120, radius: 14)
                            Text(p.name).font(W.ui(13, .semibold)).foregroundStyle(W.text).lineLimit(1)
                            Text("\(p.tracks.count) songs").font(W.dot(10)).foregroundStyle(W.text3)
                        }
                        .frame(width: 120)
                    }
                    .buttonStyle(.plain)
                }
                Button { NewPlaylist.ask() } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 26, weight: .semibold))
                        Text("New playlist").font(W.ui(13, .semibold))
                    }
                    .foregroundStyle(W.text2).frame(width: 120, height: 120).glass(14)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Search

struct SearchPage: View {
    @ObservedObject var nav = Nav.shared
    @FocusState private var focused: Bool

    var body: some View {
        PageScaffold(title: "Search") {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(W.text3)
                TextField("Song, artist, or a line of the lyrics", text: $nav.searchText)
                    .textFieldStyle(.plain).font(W.ui(16, .medium)).focused($focused)
                    .onSubmit(run)
                if nav.searching { ProgressView().controlSize(.small) }
                if !nav.searchText.isEmpty { Button { nav.searchText = ""; nav.results = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(W.text3) }.buttonStyle(.plain) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).glass(16).padding(.top, 10)
            if let r = nav.results {
                let counts = Dictionary(grouping: r.tracks, by: \.source).mapValues(\.count)
                HStack(spacing: 8) {
                    Chip(label: "All", count: r.tracks.count, selected: nav.filter == nil) { nav.filter = nil }
                    ForEach([Source.local, .youtube, .spotify], id: \.self) { s in
                        Chip(label: s.label, count: counts[s] ?? 0, selected: nav.filter == s) { nav.filter = s }
                    }
                }
                .padding(.vertical, 14)
                if !r.failed.isEmpty {
                    Text("Couldn't reach \(r.failed.joined(separator: " and ")) — showing the rest.").font(W.ui(12.5)).foregroundStyle(W.peach).padding(.bottom, 8)
                }
                let shown = r.tracks.filter { nav.filter == nil || $0.source == nav.filter }
                if shown.isEmpty { Text("Nothing found.").font(W.ui(14)).foregroundStyle(W.text3) }
                TrackList(tracks: shown)
            } else {
                Text("Searches this Mac, YouTube Music and Spotify at once. Covers, karaoke and slowed / sped-up versions are pushed down unless you ask for them.")
                    .font(W.ui(13)).foregroundStyle(W.text3).padding(.top, 14)
            }
        }
        .onAppear { focused = true }
    }

    private func run() {
        let q = nav.searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        nav.searching = true
        Task {
            let r = await Search.all(q)
            guard nav.searchText.trimmingCharacters(in: .whitespaces) == q else { return }
            nav.results = r
            nav.searching = false
        }
    }
}

// MARK: - Playlists

struct PlaylistsPage: View {
    @ObservedObject var library = Library.shared
    var body: some View {
        PageScaffold(title: "Playlists") {
            Pill(label: "New playlist", icon: "plus", style: .primary) { NewPlaylist.ask() }.padding(.vertical, 12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)], alignment: .leading, spacing: 18) {
                Button { Nav.shared.page = .liked } label: { tile("Liked songs", library.data.likes.first?.art, library.data.likes.count) }.buttonStyle(.plain)
                ForEach(library.data.playlists) { p in
                    Button { Nav.shared.page = .playlist(p.id) } label: { tile(p.name, p.tracks.first?.art, p.tracks.count) }.buttonStyle(.plain)
                }
            }
        }
    }

    private func tile(_ name: String, _ art: String?, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Cover(art: art, size: 150, radius: 16)
            Text(name).font(W.ui(14, .semibold)).foregroundStyle(W.text).lineLimit(1)
            Text("\(n) songs").font(W.dot(10)).foregroundStyle(W.text3)
        }
    }
}

struct PlaylistPage: View {
    let id: String
    @ObservedObject var library = Library.shared
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        if let p = library.playlist(id) {
            PageScaffold(title: p.name) {
                HStack(spacing: 10) {
                    Pill(label: "Play", icon: "play.fill", style: .primary, enabled: !p.tracks.isEmpty) { Player.shared.playList(p.tracks) }
                    Pill(label: "Shuffle", icon: "shuffle", enabled: !p.tracks.isEmpty) { Player.shared.playList(p.tracks, shuffled: true) }
                    Pill(label: "Rename", icon: "pencil") { name = p.name; renaming = true }
                    Pill(label: "Delete", icon: "trash") {
                        let a = NSAlert()
                        a.messageText = "Delete “\(p.name)”?"
                        a.informativeText = "The songs stay where they are; only the playlist goes."
                        a.addButton(withTitle: "Delete"); a.addButton(withTitle: "Cancel")
                        if a.runModal() == .alertFirstButtonReturn { library.deletePlaylist(p.id); Nav.shared.page = .playlists }
                    }
                }
                .padding(.vertical, 12)
                if p.tracks.isEmpty { Text("Empty — add songs from any list with ⋮ → Add to playlist…").font(W.ui(13)).foregroundStyle(W.text3).padding(.top, 10) }
                TrackList(tracks: p.tracks, numbered: true, playlistID: p.id)
            }
            .alert("Rename playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Rename") { library.renamePlaylist(p.id, name) }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            PageScaffold(title: "Playlist") { Text("This playlist is gone.").foregroundStyle(W.text3) }
        }
    }
}

enum NewPlaylist {
    @MainActor
    @discardableResult
    static func ask(adding t: Track? = nil) -> Playlist? {
        let a = NSAlert()
        a.messageText = "New playlist"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Name"
        a.accessoryView = field
        a.addButton(withTitle: "Create"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let p = Library.shared.createPlaylist(field.stringValue, tracks: t.map { [$0] } ?? [])
        return p
    }
}

struct AddToPlaylistView: View {
    let track: Track
    @ObservedObject var library = Library.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to playlist").font(W.ui(18, .bold))
            Text(track.title).font(W.ui(13)).foregroundStyle(W.text2).lineLimit(1)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(library.data.playlists) { p in
                        Button {
                            let added = library.add(track, to: p.id)
                            dismiss()
                            if !added { NSSound.beep() }
                        } label: {
                            HStack { Text(p.name).font(W.ui(14, .semibold)); Spacer(); Text("\(p.tracks.count)").font(W.dot(10)).foregroundStyle(W.text3) }
                                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(W.glassFill)).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 280)
            HStack {
                Pill(label: "New playlist…", icon: "plus") { dismiss(); DispatchQueue.main.async { NewPlaylist.ask(adding: track) } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 360)
        .background(W.bgRaised)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - On this Mac

struct OnMacPage: View {
    @ObservedObject var local = LocalMusic.shared
    var body: some View {
        PageScaffold(title: "On this Mac") {
            HStack(spacing: 10) {
                Pill(label: "Play all", icon: "play.fill", style: .primary, enabled: !local.tracks.isEmpty) { Player.shared.playList(local.tracks) }
                Pill(label: "Shuffle", icon: "shuffle", enabled: !local.tracks.isEmpty) { Player.shared.playList(local.tracks, shuffled: true) }
                Pill(label: local.scanning ? "Scanning…" : "Rescan", icon: "arrow.clockwise", enabled: !local.scanning) { Task { await local.rescan() } }
                Text("\(local.tracks.count) songs · \(Prefs.musicFolders.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", "))")
                    .font(W.dot(10)).foregroundStyle(W.text3).lineLimit(1)
            }
            .padding(.vertical, 12)
            if local.tracks.isEmpty { Text(local.scanning ? "Looking through your music folders…" : "No music found. Add folders in Settings.").font(W.ui(13)).foregroundStyle(W.text3) }
            TrackList(tracks: local.tracks)
        }
    }
}

// MARK: - Playing

struct NowPlayingPage: View {
    @ObservedObject var player = Player.shared
    @ObservedObject var library = Library.shared
    @State private var scrub: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(spacing: 18) {
                Cover(art: player.current?.art, size: 330, radius: 26, rim: true)
                    .shadow(color: W.lilac.opacity(0.35), radius: 40)
                    .padding(.top, 30)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.current?.title ?? "Nothing playing").font(W.ui(22, .heavy)).foregroundStyle(W.text).lineLimit(2)
                        Text(player.current?.artist ?? "").font(W.ui(15)).foregroundStyle(W.text2).lineLimit(1)
                    }
                    Spacer()
                    if let t = player.current {
                        RoundButton(icon: library.isLiked(t) ? "heart.fill" : "heart", help: "Like", tint: library.isLiked(t) ? W.lilac : W.text) { library.toggleLike(t) }
                        RoundButton(icon: "plus", help: "Add to playlist") { Nav.shared.addTo = t }
                    }
                }
                .frame(width: 330)
                lcd.frame(width: 330)
                transport.frame(width: 330)
                HStack {
                    Pill(label: "Equaliser", icon: "slider.vertical.3") { Nav.shared.eqSheet = true }
                    Pill(label: "Desktop widget", icon: "rectangle.on.rectangle") { DesktopWidget.shared.toggle() }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            UpNext().frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 28)
    }

    /// The LCD: clock, track number, source, shuffle / repeat, format and bitrate; the seek bar under it.
    private var lcd: some View {
        TimelineView(.periodic(from: .now, by: player.playing ? 0.5 : 60)) { _ in
            Lcd {
                HStack(alignment: .firstTextBaseline) {
                    LcdText(text: timeLabel(scrub ?? player.position), ghost: "88:88", size: 26)
                    Text("/ \(timeLabel(player.duration))").font(W.dot(12)).foregroundStyle(W.peach.opacity(0.6))
                    Spacer()
                    DotSpectrum(live: player.playing && player.current?.source != .spotify, cols: 8, rows: 5, dot: 4, gap: 1.5)
                }
                HStack(spacing: 5) {
                    Text(player.current == nil ? "TRK ---" : "TRK \(player.index + 1)/\(player.queue.count)").font(W.dot(10)).foregroundStyle(W.lilac.opacity(0.7))
                    Spacer()
                    if let s = player.current?.source { LcdBadge(text: s.tag, color: W.color(s)) }
                    if player.shuffle { LcdBadge(text: "SHUF") }
                    if player.repeatMode != .off { LcdBadge(text: player.repeatMode == .one ? "RPT 1" : "RPT") }
                }
                Text(player.quality ?? (player.current?.source == .spotify ? "Spotify stream" : " ")).font(W.dot(11)).foregroundStyle(W.peach.opacity(0.85))
                GeometryReader { g in
                    let f = player.duration > 0 ? min(1, (scrub ?? player.position) / player.duration) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1))
                        Capsule().fill(LinearGradient(colors: W.smartColors, startPoint: .leading, endPoint: .trailing)).frame(width: max(4, g.size.width * f))
                    }
                    .frame(height: 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in scrub = max(0, min(1, v.location.x / g.size.width)) * player.duration }
                        .onEnded { _ in if let s = scrub { player.seek(s) }; scrub = nil })
                }
                .frame(height: 16)
            }
        }
    }

    private var transport: some View {
        HStack {
            RoundButton(icon: "shuffle", help: "Shuffle", tint: player.shuffle ? W.lilac : W.text2) { player.setShuffle(!player.shuffle) }
            Spacer()
            RoundButton(icon: "backward.fill", help: "Previous (⌘←)", size: 42) { player.previous() }
            CandyButton(size: 70, playing: player.playing) { player.toggle() }.padding(.horizontal, 10)
            RoundButton(icon: "forward.fill", help: "Next (⌘→)", size: 42) { player.next() }
            Spacer()
            RoundButton(icon: player.repeatMode == .one ? "repeat.1" : "repeat", help: "Repeat: off → all → one",
                        tint: player.repeatMode == .off ? W.text2 : W.lilac) { player.cycleRepeat() }
        }
    }
}

/// Up next: what's after the current song; the autoplay songs under "Autoplay · similar to …" with Clear.
struct UpNext: View {
    @ObservedObject var player = Player.shared

    var body: some View {
        let upcoming = Array(player.queue.enumerated().dropFirst(max(0, player.index + 1)))
        let mine = upcoming.filter { !player.radioKeys.contains($0.element.key) }
        let auto = upcoming.filter { player.radioKeys.contains($0.element.key) }
        Scroller {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(title: "Up next")
                if let t = player.current {
                    TrackRow(track: t, number: player.index + 1, onTap: {}, inQueue: player.index)
                }
                if upcoming.isEmpty {
                    Text(player.radioLoading ? "Finding similar songs…" : "Nothing up next.").font(W.ui(13)).foregroundStyle(W.text3).padding(.vertical, 6)
                }
                ForEach(mine, id: \.element.key) { i, t in
                    TrackRow(track: t, number: i + 1, onTap: { player.jump(to: i) }, inQueue: i)
                }
                if !auto.isEmpty {
                    SectionHeader(title: "Autoplay · similar to \(player.radioFrom ?? "this")", action: "Clear") { player.clearAutoplay() }
                    ForEach(auto, id: \.element.key) { i, t in
                        TrackRow(track: t, number: i + 1, onTap: { player.jump(to: i) }, inQueue: i)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Equaliser

struct EqualiserView: View {
    @ObservedObject var eq = EQ.shared
    @ObservedObject var player = Player.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Equaliser").font(W.ui(20, .bold))
                Spacer()
                Toggle("", isOn: Binding(get: { eq.on }, set: { eq.setOn($0) })).toggleStyle(.switch).labelsHidden()
            }
            if player.current?.source == .spotify {
                Text("Spotify plays in its own app, which the EQ can't reach — it applies to Mac files and YouTube Music.")
                    .font(W.ui(12)).foregroundStyle(W.peach)
            }
            Lcd {
                HStack { DotLabel("10 bands · ±12 dB", color: W.text3, size: 9); Spacer(); Text(eq.on ? eq.preset : "Off").font(W.ui(12, .semibold)).foregroundStyle(W.lilac) }
                EqDots(gains: eq.gains, on: eq.on) { i, db in eq.setBand(i, db) }.frame(height: 150)
                HStack(spacing: 0) { ForEach(EQ.labels, id: \.self) { Text($0).font(W.dot(9)).foregroundStyle(W.text3).frame(maxWidth: .infinity) } }
            }
            Text("Drag or click the dot columns to shape the sound.").font(W.ui(12)).foregroundStyle(W.text3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(EQ.presets, id: \.0) { p in Chip(label: p.0, selected: eq.on && eq.preset == p.0) { eq.choose(p.0) } }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 470)
        .background(W.bgRaised)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var spotify = SpotifyAPI.shared
    @ObservedObject var player = Player.shared
    @Environment(\.dismiss) private var dismiss
    @State private var ytSignedIn = false
    @State private var clientID = ""
    @State private var folders = Prefs.musicFolders
    @State private var blockAds = Prefs.blockAds

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Settings").font(W.ui(22, .bold))
                DotLabel("Accounts")
                card {
                    row("YouTube Music", ytSignedIn ? "Signed in" : "Not signed in — songs still play; Premium gets better quality and no ads") {
                        if ytSignedIn {
                            Pill(label: "Sign out") { Task { await YouTubeAccount.signOut(); ytSignedIn = await YouTubeAccount.signedIn() } }
                        } else {
                            Pill(label: "Sign in", style: .primary) {
                                SignInWindow.shared.onDone = { Task { ytSignedIn = await YouTubeAccount.signedIn() } }
                                SignInWindow.shared.open(YouTubeEngine.signIn)
                            }
                        }
                    }
                    Divider().overlay(W.hairline)
                    row("Spotify search", spotify.connected ? "Connected with your Spotify developer app" : "Your own Spotify developer app's Client ID (developer.spotify.com/dashboard), redirect URI http://127.0.0.1:8888/callback") {
                        if spotify.connected { Pill(label: "Sign out") { spotify.signOut() } }
                        else { Pill(label: "Connect", style: .primary, enabled: !clientID.isEmpty) { spotify.setClientID(clientID); Task { await spotify.connect() } } }
                    }
                    if !spotify.connected {
                        TextField("Client ID", text: $clientID).textFieldStyle(.roundedBorder).font(W.ui(13))
                    }
                    if let s = spotify.status { Text(s).font(W.ui(12)).foregroundStyle(W.peach) }
                    Divider().overlay(W.hairline)
                    row("Spotify playback", SpotifyApp.installed ? "Plays in the Spotify app (opened hidden). macOS asks once to let WreckBox Player control it." : "Install the Spotify app to play Spotify songs") { EmptyView() }
                }
                DotLabel("Playing")
                card {
                    Toggle(isOn: Binding(get: { Prefs.autoplay }, set: { player.setAutoplay($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Autoplay similar songs").font(W.ui(14, .semibold))
                            Text("When the queue runs out, keep going with ~25 similar songs (YouTube Music's song radio).").font(W.ui(12)).foregroundStyle(W.text2)
                        }
                    }
                    Divider().overlay(W.hairline)
                    Toggle(isOn: $blockAds) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Block ads").font(W.ui(14, .semibold))
                            Text("Skips YouTube ads and blocks ad servers (applies from the next launch). Premium never sees ads anyway.").font(W.ui(12)).foregroundStyle(W.text2)
                        }
                    }
                    .onChange(of: blockAds) { _, v in Prefs.blockAds = v }
                }
                DotLabel("Music on this Mac")
                card {
                    ForEach(folders, id: \.self) { f in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(W.text2)
                            Text((f as NSString).abbreviatingWithTildeInPath).font(W.ui(13))
                            Spacer()
                            Button { folders.removeAll { $0 == f }; Prefs.musicFolders = folders } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(W.text3)
                        }
                    }
                    HStack {
                        Pill(label: "Add folder…", icon: "plus") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = true
                            if p.runModal() == .OK { folders += p.urls.map(\.path).filter { !folders.contains($0) }; Prefs.musicFolders = folders }
                        }
                        Pill(label: "Rescan now", icon: "arrow.clockwise") { Task { await LocalMusic.shared.rescan() } }
                    }
                }
                DotLabel("Widgets")
                card {
                    row("Desktop widget", "The Y2K player on your desktop — Equaliser, Queue and Options drawers. ⌥⌘W") {
                        Pill(label: DesktopWidget.shared.isOpen ? "Hide" : "Show") { DesktopWidget.shared.toggle() }
                    }
                    Divider().overlay(W.hairline)
                    row("macOS widget", "Right-click the desktop → Edit Widgets → WreckBox Player (small, medium or large). Its buttons bring the app forward for a moment.") { EmptyView() }
                }
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            .padding(24)
        }
        .frame(width: 560, height: 640)
        .background(W.bgRaised)
        .environment(\.colorScheme, .dark)
        .task {
            ytSignedIn = await YouTubeAccount.signedIn()
            clientID = spotify.config?.clientID ?? ""
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) { c() }.padding(16).glass(16)
    }

    private func row<A: View>(_ title: String, _ detail: String, @ViewBuilder _ action: () -> A) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(W.ui(14, .semibold))
                Text(detail).font(W.ui(12)).foregroundStyle(W.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            action()
        }
    }
}
