import AppKit
import Shared
import WidgetKit

/// Keeps the macOS widget current and runs the widgets' buttons.
///  - Out: the player's state as WidgetSnapshot (now.json + art.jpg in the folder the sandboxed widget may read), then
///    WidgetCenter reloads it. Written only when something the widget shows changed (or the position jumped) —
///    the widget animates its own clock and progress from `position`/`at`.
///  - In: wbplayer://<command> links from the widget, and the desktop widget's buttons, through `run`.
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()
    private var pending = false
    private var lastSig = ""
    private var lastArt: String?
    private var lastPos: (pos: Double, at: Date, playing: Bool) = (0, .distantPast, false)

    /// Something changed: write soon (changes come in bursts).
    func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pending = false
            self?.write()
        }
    }

    private func write() {
        let p = Player.shared
        let t = p.current
        let eq = EQ.shared
        let upcoming = p.queue.enumerated().dropFirst(p.index + 1).prefix(5).map {
            WidgetSnapshot.Upcoming(number: $0.offset + 1, title: $0.element.title, artist: $0.element.artist)
        }
        let snap = WidgetSnapshot(
            title: t?.title, artist: t?.artist, source: t?.source.rawValue, quality: p.quality, playing: p.playing,
            position: p.position, duration: p.duration, at: Date(), track: t == nil ? "" : "\(p.index + 1)/\(p.queue.count)",
            shuffle: p.shuffle, repeatMode: p.repeatMode.rawValue, liked: t.map(Library.shared.isLiked) ?? false,
            volume: Int((SystemVolume.value * 100).rounded()), eqOn: eq.on, eqPreset: eq.preset, upcoming: upcoming, hasArt: t?.art != nil)
        // The position only matters when it jumped (a seek) — otherwise the widget's clock runs by itself.
        let expected = lastPos.playing ? lastPos.pos + Date().timeIntervalSince(lastPos.at) : lastPos.pos
        let sig = [snap.title ?? "", snap.artist ?? "", snap.quality ?? "", "\(snap.playing)", "\(Int(snap.duration))", snap.track,
                   "\(snap.shuffle)", "\(snap.repeatMode)", "\(snap.liked)", "\(snap.volume)", "\(snap.eqOn)", snap.eqPreset,
                   upcoming.map(\.title).joined(separator: "|")].joined(separator: "§")
        guard sig != lastSig || abs(snap.position - expected) > 2.5 else { return }
        lastSig = sig
        lastPos = (snap.position, Date(), snap.playing)
        DesktopWidget.shared.refresh()

        try? FileManager.default.createDirectory(at: WidgetFiles.dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        try? enc.encode(snap).write(to: WidgetFiles.snapshot, options: .atomic)
        if t?.art != lastArt {
            lastArt = t?.art
            let art = t?.art
            Task {
                if let d = await Images.shared.data(art) { try? d.write(to: WidgetFiles.art, options: .atomic) }
                else { try? FileManager.default.removeItem(at: WidgetFiles.art) }
                WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
            }
        } else {
            WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        }
    }

    /// A widget button (or a wbplayer:// link).
    func run(_ c: WidgetCommand) {
        let p = Player.shared
        switch c {
        case .toggle: p.toggle()
        case .next: p.next()
        case .previous: p.previous()
        case .back10: p.skip(-10)
        case .fwd10: p.skip(10)
        case .shuffle: p.setShuffle(!p.shuffle)
        case .repeatMode: p.cycleRepeat()
        case .like: if let t = p.current { Library.shared.toggleLike(t) }
        case .volUp: SystemVolume.step(true); changed()
        case .volDown: SystemVolume.step(false); changed()
        case .open: AppDelegate.showMain(page: .playing)
        }
    }

    /// wbplayer://next etc. A link from the macOS widget brings the app forward; for anything but "open" it goes back
    /// to whatever was in front, so a press feels like a remote control.
    func handle(_ url: URL, previousApp: NSRunningApplication?) {
        guard url.scheme == "wbplayer" else { return }
        guard let c = WidgetCommand(rawValue: url.host ?? "") else { return DevCommands.run(url) }
        run(c)
        if c != .open, let prev = previousApp, prev != NSRunningApplication.current { prev.activate() }
    }
}
