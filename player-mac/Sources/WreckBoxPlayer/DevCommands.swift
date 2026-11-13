import AppKit
import SwiftUI

/// Test hooks for development (`open "wbplayer://dev/…"`):
///  - snapshot            → PNGs of the main window and the desktop widget in ~/Library/Application Support/WreckBox Player/snapshots
///  - page?to=home|search|playlists|playing
///  - play-local?n=5      → plays the first n songs on this Mac
///  - drawer?to=eq|queue|options|none
///  - state               → writes state.json (queue, index, position, playing, quality)
@MainActor
enum DevCommands {
    static func run(_ url: URL) {
        guard url.host == "dev" else { return }
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        switch url.path {
        case "/snapshot": snapshot()
        case "/page":
            Nav.shared.page = ["search": .search, "playlists": .playlists, "playing": .playing, "liked": .liked, "mac": .onMac][q["to"] ?? ""] ?? .home
        case "/play-local":
            let n = Int(q["n"] ?? "") ?? 5
            Player.shared.playList(Array(LocalMusic.shared.tracks.prefix(n)))
        case "/drawer":
            DesktopWidget.shared.model.drawer = ["eq": .eq, "queue": .queue, "options": .options][q["to"] ?? ""]
        case "/search":
            Nav.shared.page = .search
            Nav.shared.searchText = q["q"] ?? ""
            Task { Nav.shared.results = await Search.all(q["q"] ?? "") }
        case "/state": state()
        default: break
        }
    }

    private static var dir: URL {
        let d = AppDirs.support.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func snapshot() {
        // The main window, rendered off-screen (scroll views as stacks); panels as they are on screen.
        let r = ImageRenderer(content: MainView().environment(\.snapshotMode, true).frame(width: 1120, height: 760))
        r.scale = 2
        if let cg = r.cgImage { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("main.png")) }
        for (i, w) in NSApp.windows.enumerated() where w.isVisible && w is NSPanel {
            guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let name = w is NSPanel ? "widget" : w.title.isEmpty ? "window\(i)" : "main"
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    private static func state() {
        let p = Player.shared
        let s: [String: Any] = [
            "queue": p.queue.map { "\($0.source.rawValue) \($0.title) — \($0.artist)" }, "index": p.index, "playing": p.playing,
            "buffering": p.buffering, "position": p.position, "duration": p.duration, "quality": p.quality ?? "", "shuffle": p.shuffle,
            "repeat": p.repeatMode.rawValue, "message": p.message ?? "", "radio": p.radioKeys.count, "eq": "\(EQ.shared.on) \(EQ.shared.preset)",
            "likes": Library.shared.data.likes.count,
            "results": (Nav.shared.results?.tracks.prefix(8) ?? []).map { "\($0.source.rawValue) \($0.title) — \($0.artist) [\(timeLabel($0.duration))]" },
            "failed": Nav.shared.results?.failed ?? [], "local": LocalMusic.shared.tracks.count, "levels": Levels.shared.bands.map { $0.map { String(format: "%.2f", $0) } } ?? [],
        ]
        if let d = try? JSONSerialization.data(withJSONObject: s, options: .prettyPrinted) { try? d.write(to: dir.appendingPathComponent("state.json")) }
    }
}
