import AppKit
import SwiftUI

enum Page: Hashable { case home, search, playlists, playlist(String), liked, onMac, playing }

@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    @Published var page: Page = .home
    @Published var settings = false
    @Published var eqSheet = false
    @Published var addTo: Track?          // "Add to playlist…" sheet
    @Published var searchText = ""
    @Published var results: Search.Found?
    @Published var searching = false
    @Published var filter: Source?
}

struct MainView: View {
    @ObservedObject var nav = Nav.shared
    @ObservedObject var player = Player.shared

    var body: some View {
        ZStack {
            AmbientBackground(art: player.current?.art)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sidebar
                    Divider().overlay(W.hairline)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if nav.page != .playing { MiniPlayer().padding(.horizontal, 14).padding(.bottom, 12) }
            }
            if let m = player.message {
                Text(m).font(W.ui(13, .semibold)).foregroundStyle(W.text)
                    .padding(.horizontal, 16).padding(.vertical, 9).glass(20)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 92)
                    .transition(.opacity).allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.message)
        .environment(\.colorScheme, .dark)
        .frame(minWidth: 860, minHeight: 600)
        .sheet(isPresented: $nav.settings) { SettingsView() }
        .sheet(isPresented: $nav.eqSheet) { EqualiserView() }
        .sheet(item: $nav.addTo) { AddToPlaylistView(track: $0) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Wordmark(size: 22).padding(.bottom, 18).padding(.leading, 6)
            navItem("Home", "house", .home)
            navItem("Search", "magnifyingglass", .search)
            navItem("Playlists", "music.note.list", .playlists)
            navItem("Playing", "waveform", .playing)
            DotLabel("Library", size: 10).padding(.top, 18).padding(.leading, 10).padding(.bottom, 4)
            navItem("Liked songs", "heart", .liked)
            navItem("On this Mac", "desktopcomputer", .onMac)
            Scroller {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Library.shared.data.playlists) { p in navItem(p.name, "music.note", .playlist(p.id)) }
                }
            }
            Spacer()
            HStack(spacing: 8) {
                RoundButton(icon: "rectangle.on.rectangle", help: "Desktop widget (⌥⌘W)", size: 30) { DesktopWidget.shared.toggle() }
                RoundButton(icon: "slider.vertical.3", help: "Equaliser", size: 30) { nav.eqSheet = true }
                RoundButton(icon: "gearshape", help: "Settings", size: 30) { nav.settings = true }
            }
            .padding(.leading, 6)
        }
        .padding(.horizontal, 10).padding(.vertical, 18)
        .frame(width: 210)
    }

    private func navItem(_ label: String, _ icon: String, _ page: Page) -> some View {
        let on = nav.page == page
        return Button { nav.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).frame(width: 18)
                Text(label).font(W.ui(14, on ? .bold : .medium)).lineLimit(1)
                Spacer()
            }
            .foregroundStyle(on ? W.text : W.text2)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? W.glassFill : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? W.hairline : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        switch nav.page {
        case .home: HomePage()
        case .search: SearchPage()
        case .playlists: PlaylistsPage()
        case .playlist(let id): PlaylistPage(id: id)
        case .liked: TrackListPage(title: "Liked songs", tracks: Library.shared.data.likes, empty: "Songs you ♥ show up here.")
        case .onMac: OnMacPage()
        case .playing: NowPlayingPage()
        }
    }
}

// MARK: - Mini player

struct MiniPlayer: View {
    @ObservedObject var player = Player.shared

    var body: some View {
        HStack(spacing: 12) {
            Cover(art: player.current?.art, size: 46, radius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.current?.title ?? "Nothing playing").font(W.ui(14, .bold)).foregroundStyle(W.text).lineLimit(1)
                HStack(spacing: 6) {
                    if let s = player.current?.source { SourceTag(source: s) }
                    Text(player.current?.artist ?? "Pick a song to start").font(W.ui(12)).foregroundStyle(W.text2).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { Nav.shared.page = .playing }
            if player.buffering { ProgressView().controlSize(.small) }
            RoundButton(icon: "backward.fill", help: "Previous (⌘←)", size: 32) { player.previous() }
            CandyButton(size: 42, playing: player.playing) { player.toggle() }
            RoundButton(icon: "forward.fill", help: "Next (⌘→)", size: 32) { player.next() }
            TimelineView(.periodic(from: .now, by: player.playing ? 1 : 60)) { _ in
                Text("\(timeLabel(player.position)) / \(timeLabel(player.duration))").font(W.dot(11)).foregroundStyle(W.text3).frame(width: 96)
            }
        }
        .padding(10)
        .glass(18)
    }
}

// MARK: - Pieces

struct Cover: View {
    let art: String?
    var size: CGFloat
    var radius: CGFloat = W.Radius.art
    var rim = false
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                // No cover: the pixel record on the gradient, not a grey square.
                LinearGradient(colors: [W.lilac.opacity(0.35), W.blue.opacity(0.2), W.peach.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
                PixelRecord(size: size * 0.5, tile: false).opacity(0.8)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08)))
        .modifier(RimIf(on: rim, radius: radius))
        .task(id: art) { image = await Images.shared.load(art, size: size) }
    }
}

private struct RimIf: ViewModifier {
    let on: Bool, radius: CGFloat
    func body(content: Content) -> some View { if on { content.iridescentRim(radius, width: 2) } else { content } }
}

struct SourceTag: View {
    let source: Source
    var body: some View {
        Text(source.tag).font(W.dot(9)).tracking(1).foregroundStyle(W.color(source))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(W.color(source).opacity(0.55), lineWidth: 0.8))
    }
}

/// A song row: tap to play (the rest of the list follows), ⋮ / right-click for the menu. Swipe it (drag sideways):
/// right → add to queue, left → play next; in Up next either way removes it.
struct TrackRow: View {
    let track: Track
    var number: Int?
    var onTap: () -> Void
    var inQueue: Int?                 // its place in the queue (Up next rows)
    var playlist: (id: String, index: Int, count: Int)?
    @ObservedObject private var player = Player.shared
    @ObservedObject private var library = Library.shared
    @State private var dx: CGFloat = 0
    @State private var hover = false

    var body: some View {
        let isCurrent = player.current?.key == track.key
        ZStack {
            // The hint under the row while swiping.
            if dx != 0 {
                let right = dx > 0
                Text(inQueue != nil ? "Remove from queue" : right ? "Add to queue" : "Play next")
                    .font(W.ui(12.5, .bold)).foregroundStyle(W.text)
                    .frame(maxWidth: .infinity, alignment: right ? .leading : .trailing).padding(.horizontal, 18)
                    .background(RoundedRectangle(cornerRadius: W.Radius.row).fill(W.smart.opacity(min(0.5, abs(dx) / 200))))
            }
            HStack(spacing: 12) {
                if let number { Text(String(format: "%02d", number)).font(W.dot(11)).foregroundStyle(isCurrent ? W.peach : W.text3).frame(width: 24) }
                Cover(art: track.art, size: 42, radius: 7, rim: isCurrent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(W.ui(14, .semibold)).foregroundStyle(isCurrent ? W.peach : W.text).lineLimit(1)
                    HStack(spacing: 6) {
                        SourceTag(source: track.source)
                        if let q = Quality.short(Quality.cached(track)) { Text(q).font(W.dot(9.5)).foregroundStyle(W.text3) }
                        Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(W.ui(12)).foregroundStyle(W.text2).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isCurrent && player.playing { DotSpectrum(live: true) }
                if library.isLiked(track) { Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(W.lilac) }
                if track.durationMs > 0 { Text(timeLabel(track.duration)).font(W.dot(11)).foregroundStyle(W.text3) }
                Menu { menuItems } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundStyle(W.text2).frame(width: 26, height: 26) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: W.Radius.row).fill(hover || isCurrent ? W.hover : .clear))
            .contentShape(Rectangle())
            .offset(x: dx)
        }
        .onHover { hover = $0 }
        .onTapGesture(count: 1, perform: onTap)
        .contextMenu { menuItems }
        .gesture(DragGesture(minimumDistance: 12).onChanged { v in
            if abs(v.translation.width) > abs(v.translation.height) { dx = v.translation.width }
        }.onEnded { v in
            let w = v.translation.width
            withAnimation(.spring(response: 0.3)) { dx = 0 }
            guard abs(w) > 90 else { return } // short swipes do nothing
            if let i = inQueue { player.remove(at: i) } else if w > 0 { player.addToQueue(track) } else { player.playNext(track) }
        })
    }

    @ViewBuilder private var menuItems: some View {
        if inQueue == nil {
            Button("Play next") { player.playNext(track) }
            Button("Add to queue") { player.addToQueue(track) }
        }
        Button(library.isLiked(track) ? "Unlike" : "Like") { library.toggleLike(track) }
        Button("Add to playlist…") { Nav.shared.addTo = track }
        if let i = inQueue {
            Divider()
            Button("Move up") { player.move(i, i - 1) }.disabled(i <= player.index + 1)
            Button("Move down") { player.move(i, i + 1) }.disabled(i >= player.queue.count - 1)
            Button("Remove from queue") { player.remove(at: i) }
        }
        if let p = playlist {
            Divider()
            Button("Move up") { library.move(p.index, p.index - 1, in: p.id) }.disabled(p.index == 0)
            Button("Move down") { library.move(p.index, p.index + 1, in: p.id) }.disabled(p.index >= p.count - 1)
            Button("Remove from playlist") { library.remove(at: p.index, from: p.id) }
        }
        if track.source == .local {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: track.id)]) }
        }
    }
}

/// A list of songs; tapping one plays the list from there.
struct TrackList: View {
    let tracks: [Track]
    var numbered = false
    var playlistID: String?

    var body: some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                TrackRow(track: t, number: numbered ? i + 1 : nil, onTap: { Player.shared.playList(tracks, start: i) },
                         playlist: playlistID.map { ($0, i, tracks.count) })
            }
        }
    }
}

struct PageScaffold<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        Scroller {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(W.ui(30, .heavy)).foregroundStyle(W.text).padding(.top, 26).padding(.bottom, 6)
                content
            }
            .padding(.horizontal, 28).padding(.bottom, 30)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TrackListPage: View {
    let title: String
    let tracks: [Track]
    var empty = ""
    var body: some View {
        PageScaffold(title: title) {
            HStack(spacing: 10) {
                Pill(label: "Play", icon: "play.fill", style: .primary, enabled: !tracks.isEmpty) { Player.shared.playList(tracks) }
                Pill(label: "Shuffle", icon: "shuffle", enabled: !tracks.isEmpty) { Player.shared.playList(tracks, shuffled: true) }
                Text("\(tracks.count) songs").font(W.dot(11)).foregroundStyle(W.text3).padding(.leading, 6)
            }
            .padding(.vertical, 12)
            if tracks.isEmpty { Text(empty).font(W.ui(14)).foregroundStyle(W.text3).padding(.top, 20) }
            TrackList(tracks: tracks)
        }
    }
}
