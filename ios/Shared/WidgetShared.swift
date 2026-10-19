import AppIntents
import CoreText
import Foundation
import WidgetKit

/// What the widgets show, written by the app whenever the player changes (WidgetBridge) into the App Group folder
/// both can read, and read by the widget extension.
struct WidgetSnapshot: Codable, Equatable {
    struct Upcoming: Codable, Equatable {
        var number: Int
        var title: String
        var artist: String
    }

    var title: String?
    var artist: String?
    var source: String?          // "LOCAL", "YOUTUBE", "SPOTIFY"
    var quality: String?         // "FLAC · 24/96 · 2,612 kbps"
    var playing = false
    var position: Double = 0     // seconds, at `at`
    var duration: Double = 0
    var at = Date()
    var track = ""               // "3/24"
    var shuffle = false
    var repeatMode = 0           // 0 off, 1 all, 2 one
    var liked = false
    var eqOn = true
    var eqPreset = "Flat"
    var eqGains: [Float] = Array(repeating: 0, count: 10)
    var upcoming: [Upcoming] = []
    var hasArt = false

    /// "FLAC 24/96", "MP3 320", "AAC 130": the LCD's short format badge.
    var format: String {
        guard let p = quality?.components(separatedBy: " · "), let first = p.first else { return "" }
        guard p.count >= 2 else { return first }
        let second = p[1].replacingOccurrences(of: "~", with: "").replacingOccurrences(of: " kbps", with: "").replacingOccurrences(of: ",", with: "")
        return "\(first) \(second)"
    }

    /// The source as the LCD badge says it.
    var sourceBadge: String {
        switch source { case "LOCAL": return "PHONE"; case "YOUTUBE": return "YTM"; case "SPOTIFY": return "SPOT"; default: return "" }
    }
}

enum WidgetFiles {
    static let group = "group.com.moloybiswas.wreckbox.player"
    static var dir: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static var snapshot: URL? { dir?.appendingPathComponent("now.json") }
    static var art: URL? { dir?.appendingPathComponent("art.jpg") }
    static var shared: UserDefaults? { UserDefaults(suiteName: group) }

    /// The large widget's open panel (0 Equaliser, 1 Queue, 2 Options).
    static var drawer: Int {
        get { shared?.object(forKey: "widgetDrawer") as? Int ?? 1 }
        set { shared?.set(newValue, forKey: "widgetDrawer") }
    }

    static func read() -> WidgetSnapshot? {
        guard let u = snapshot else { log("no App Group folder"); return nil }
        guard let d = try? Data(contentsOf: u) else { log("no now.json yet"); return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        do { return try dec.decode(WidgetSnapshot.self, from: d) } catch { log("now.json unreadable: \(error)"); return nil }
    }

    /// A line in widget.log (App Group): what the widget extension did — the app passes it on to its test log.
    static func log(_ s: String) {
        guard let u = dir?.appendingPathComponent("widget.log") else { return }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let line = Data("\(f.string(from: Date())) \(s)\n".utf8)
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(line); try? h.close() } else { try? line.write(to: u) }
    }
}

/// The widget kind (WidgetCenter reloads it by this name).
let widgetKind = "WreckBoxPlayerWidget"

/// Urbanist and Doto, from whichever bundle runs this (the app or the widget extension).
enum WreckFonts {
    nonisolated(unsafe) private static var done = false
    static func register() {
        guard !done, let dir = Bundle.main.resourceURL else { return }
        done = true
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            + ((try? fm.contentsOfDirectory(at: dir.appendingPathComponent("Fonts"), includingPropertiesForKeys: nil)) ?? [])
        for f in files where f.pathExtension.lowercased() == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
    }
}

// MARK: - The widgets' buttons

/// What a widget button asks for.
enum WidgetCommand: String, AppEnum {
    case toggle, next, previous, like, shuffle, repeatMode, back10, fwd10, eqToggle

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Player command"
    static let caseDisplayRepresentations: [WidgetCommand: DisplayRepresentation] = [
        .toggle: "Play / pause", .next: "Next", .previous: "Previous", .like: "Like", .shuffle: "Shuffle", .repeatMode: "Repeat",
        .back10: "Back 10 seconds", .fwd10: "Forward 10 seconds", .eqToggle: "Equaliser on / off",
    ]
}

/// Set by the app when it starts: runs a command on the player. (The widget extension compiles this too, but iOS
/// runs audio intents in the app's own process, so there it's never called.)
@MainActor
enum WidgetActions {
    static var run: ((WidgetCommand) -> Void)?
    static var preset: ((String) -> Void)?
    static var jump: ((Int) -> Void)?
}

/// A widget button. An audio-playback intent: iOS runs it inside the app (starting the app in the background if it
/// isn't running), so the press acts at once without opening the app.
struct PlayerCommandIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "WreckBox Player"
    static let isDiscoverable = false

    @Parameter(title: "Command") var command: WidgetCommand

    init() {}
    init(_ command: WidgetCommand) { self.command = command }

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetActions.run?(command)
        return .result()
    }
}

/// An EQ preset key in the Equaliser drawer.
struct EQPresetIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "WreckBox EQ preset"
    static let isDiscoverable = false

    @Parameter(title: "Preset") var preset: String

    init() {}
    init(_ preset: String) { self.preset = preset }

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetActions.preset?(preset)
        return .result()
    }
}

/// A song in the Queue drawer: plays it.
struct JumpIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "WreckBox play from queue"
    static let isDiscoverable = false

    @Parameter(title: "Place in the queue") var index: Int

    init() {}
    init(_ index: Int) { self.index = index }

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetActions.jump?(index)
        return .result()
    }
}

/// A tab on the large widget: shows that panel. Runs in the widget; it redraws itself.
struct DrawerIntent: AppIntent {
    static let title: LocalizedStringResource = "WreckBox widget drawer"
    static let isDiscoverable = false

    @Parameter(title: "Drawer") var drawer: Int

    init() {}
    init(_ drawer: Int) { self.drawer = drawer }

    func perform() async throws -> some IntentResult {
        WidgetFiles.drawer = drawer
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        return .result()
    }
}
