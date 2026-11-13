import Foundation

/// What the macOS widget shows, written by the app whenever the player changes (WidgetBridge) and read by the widget
/// extension. The widget is sandboxed: it may only read this one folder (a read-only exception in its entitlements).
public struct WidgetSnapshot: Codable, Equatable {
    public struct Upcoming: Codable, Equatable {
        public var number: Int
        public var title: String
        public var artist: String
        public init(number: Int, title: String, artist: String) { self.number = number; self.title = title; self.artist = artist }
    }

    public var title: String?
    public var artist: String?
    public var source: String?          // "LOCAL", "YOUTUBE", "SPOTIFY"
    public var quality: String?         // "FLAC · 24/96 · 2,612 kbps"
    public var playing: Bool
    public var position: Double         // seconds, at `at`
    public var duration: Double
    public var at: Date
    public var track: String            // "3/24"
    public var shuffle: Bool
    public var repeatMode: Int          // 0 off, 1 all, 2 one
    public var liked: Bool
    public var volume: Int              // 0…100, the Mac's output volume
    public var eqOn: Bool
    public var eqPreset: String
    public var upcoming: [Upcoming]
    public var hasArt: Bool

    public init(title: String? = nil, artist: String? = nil, source: String? = nil, quality: String? = nil, playing: Bool = false,
                position: Double = 0, duration: Double = 0, at: Date = Date(), track: String = "", shuffle: Bool = false,
                repeatMode: Int = 0, liked: Bool = false, volume: Int = 50, eqOn: Bool = true, eqPreset: String = "Flat",
                upcoming: [Upcoming] = [], hasArt: Bool = false) {
        self.title = title; self.artist = artist; self.source = source; self.quality = quality; self.playing = playing
        self.position = position; self.duration = duration; self.at = at; self.track = track; self.shuffle = shuffle
        self.repeatMode = repeatMode; self.liked = liked; self.volume = volume; self.eqOn = eqOn; self.eqPreset = eqPreset
        self.upcoming = upcoming; self.hasArt = hasArt
    }

    /// "FLAC 24/96", "MP3 320", "OPUS 160": the LCD's short format badge.
    public var format: String {
        guard let p = quality?.components(separatedBy: " · "), let first = p.first else { return "" }
        guard p.count >= 2 else { return first }
        let second = p[1].replacingOccurrences(of: "~", with: "").replacingOccurrences(of: " kbps", with: "").replacingOccurrences(of: ",", with: "")
        return "\(first) \(second)"
    }

    /// The source as the LCD badge says it.
    public var sourceBadge: String {
        switch source { case "LOCAL": return "MAC"; case "YOUTUBE": return "YTM"; case "SPOTIFY": return "SPOT"; default: return "" }
    }
}

public enum WidgetFiles {
    /// ~/Library/Application Support/WreckBox Player/Widget — the real home folder, also from inside the sandbox.
    public static var dir: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/WreckBox Player/Widget")
    }
    public static var snapshot: URL { dir.appendingPathComponent("now.json") }
    public static var art: URL { dir.appendingPathComponent("art.jpg") }

    public static func read() -> WidgetSnapshot? {
        guard let d = try? Data(contentsOf: snapshot) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(WidgetSnapshot.self, from: d)
    }
}

/// The widget's buttons are links the app handles: wbplayer://toggle, wbplayer://next, …
public enum WidgetCommand: String, CaseIterable {
    case toggle, next, previous, back10, fwd10, shuffle, repeatMode = "repeat", like, volUp, volDown, open
    public var url: URL { URL(string: "wbplayer://\(rawValue)")! }
}

/// The widget kind (WidgetCenter reloads it by this name).
public let widgetKind = "WreckBoxPlayerWidget"
