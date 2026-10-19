import SwiftUI
import WidgetKit

// The iPhone widgets: a now-playing display in the WreckBox look, Small and Medium. No buttons — tapping the widget
// opens Now playing in the app. (Widget buttons run their command by starting the app in the background, and the
// widget kept failing around them on the iPhone; the Live Activity has the controls.)
//  - Small: the LCD — state mark, running peach clock, source badge, title, artist, length + format.
//  - Medium: the cover beside the LCD.
// Memory rules (a widget extension has ~30 MB; running out = a blank tile): no pictures but the 128-px cover, no
// Canvas, no shadows, no GeometryReader, no ProgressView(timerInterval:) (its built-in GeometryReader crashed iOS 27's
// renderer: "view origin is invalid: (nan, 3.0)"); one entry per change, the clock runs by itself.

struct PlayerEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct PlayerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlayerEntry {
        PlayerEntry(date: Date(), snap: WidgetSnapshot(title: "Babydoll", artist: "Ari Abdul", source: "LOCAL", quality: "FLAC · 16/44.1 · 912 kbps",
                                                       playing: true, position: 42, duration: 151, track: "003/024"))
    }

    func getSnapshot(in context: Context, completion: @escaping (PlayerEntry) -> Void) {
        WidgetFiles.log("snapshot for \(context.family)")
        completion(Self.entry() ?? placeholder(in: context))
    }

    /// One entry; the app reloads the widgets whenever something they show changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlayerEntry>) -> Void) {
        WidgetFiles.log("timeline for \(context.family)")
        let e = Self.entry() ?? PlayerEntry(date: Date(), snap: WidgetSnapshot())
        // If the app hasn't said otherwise a little after the song should have ended (it was closed mid-song), show
        // it paused at the end instead of "playing" with a stopped clock.
        var entries = [e]
        if e.snap.playing && e.snap.duration > 0 {
            var stopped = e.snap
            stopped.playing = false
            stopped.position = stopped.duration
            entries.append(PlayerEntry(date: e.snap.at.addingTimeInterval(max(0, e.snap.duration - e.snap.position) + 10), snap: stopped))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    static func entry() -> PlayerEntry? {
        guard let s = WidgetFiles.read() else { return nil }
        return PlayerEntry(date: Date(), snap: s)
    }
}

/// The palette's darks, as on Android.
enum Ink {
    static let well = Color(hex: 0x07060A)
    static let keyTop = Color(hex: 0x34303F), keyBottom = Color(hex: 0x16141C)
    static let candyText = Color(hex: 0x0A0A0C)
}

struct PlayerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PlayerEntry
    var s: WidgetSnapshot { entry.snap }

    private var start: Date { s.at.addingTimeInterval(-s.position) }
    private var end: Date { start.addingTimeInterval(max(s.duration, s.position + 1)) }

    var body: some View {
        Group {
            if family == .systemMedium {
                HStack(spacing: 12) {
                    cover
                    lcd(clock: 24, small: false)
                }
            } else {
                lcd(clock: 20, small: true)
            }
        }
        .containerBackground(for: .widget) { CasingView() }
        .widgetURL(Self.openURL)
    }

    /// Tapping the widget opens Now playing.
    static let openURL = URL(string: "wreckbox://show?page=playing")!

    /// The cover (from the App Group, 128 px) with the iridescent rim; the record when there's none.
    private var cover: some View {
        Group {
            if s.hasArt, let img = WidgetFiles.art.flatMap({ UIImage(contentsOfFile: $0.path) }) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Ink.well
                    Disc(size: 64)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(ContainerRelativeShape())
        .overlay(ContainerRelativeShape().strokeBorder(LinearGradient(colors: Y2K.smartColors, startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
    }

    /// The LCD: state + clock and the source badge, a rule, title, artist, then length, format and the logo.
    private func lcd(clock: CGFloat, small: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Clock(s: s, start: start, end: end, size: clock)
                Spacer(minLength: 2)
                if !s.sourceBadge.isEmpty { Badge(text: s.sourceBadge).padding(.top, clock * 0.3) }
            }
            Rectangle().fill(Y2K.lilac.opacity(40 / 255)).frame(height: 0.8).padding(.vertical, 4)
            Text(s.title ?? "Nothing playing").font(Y2K.ui(small ? 13.5 : 15, .bold)).foregroundStyle(Y2K.text).lineLimit(small ? 2 : 1)
            Text(s.artist ?? "Tap to open WreckBox").font(Y2K.ui(small ? 11 : 12, .medium)).foregroundStyle(Y2K.text2).lineLimit(1)
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                Text(s.duration > 0 ? "/ \(Self.time(s.duration))" : "/ --:--").font(Y2K.dot(9)).foregroundStyle(Y2K.lilac.opacity(0.7))
                    .lineLimit(1).fixedSize()
                if !s.format.isEmpty && !small { Badge(text: s.format) }
                Spacer(minLength: 2)
                Disc(size: 12, tile: true)
                if !small {
                    Text("WRECKBOX").font(Y2K.dot(8.5, .black)).tracking(1.2).lineLimit(1).fixedSize()
                        .foregroundStyle(LinearGradient(colors: Y2K.smartColors, startPoint: .leading, endPoint: .trailing))
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LcdGlass())
    }

    static func time(_ s: Double) -> String { let i = Int(max(0, s)); return String(format: "%d:%02d", i / 60, i % 60) }
}

// MARK: - Pieces (shared with the Live Activity) — shapes and gradients only

/// The clock: peach Doto digits over faint "88:88" segments (right-aligned, so the digits sit on their segments), the
/// lilac state mark (▶ playing, ❚❚ paused) before them; it runs by itself while playing.
struct Clock: View {
    let s: WidgetSnapshot
    let start: Date, end: Date
    let size: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.2) {
            StateMark(state: s.title == nil ? 0 : s.playing ? 2 : 1).fill(Y2K.lilac).frame(width: size * 0.32, height: size * 0.4)
            ZStack(alignment: .trailing) {
                Text("88:88").font(Y2K.dot(size, .black)).foregroundStyle(Y2K.peach.opacity(30 / 255))
                Group {
                    if s.playing && s.duration > 0 { Text(timerInterval: start...end, countsDown: false) }
                    else { Text(PlayerWidgetView.time(s.position)) }
                }
                .font(Y2K.dot(size, .black)).foregroundStyle(Y2K.peach)
                .multilineTextAlignment(.trailing)
            }
            .fixedSize()
            .monospacedDigit()
        }
        .frame(height: size * 1.28)
    }
}

/// The seek bar (Live Activity): a dark well with a peach fill — a shape, not ProgressView(timerInterval:).
struct SeekBar: View {
    let fraction: Double
    var body: some View {
        ZStack {
            Capsule().fill(Ink.well)
            BarFill(fraction: fraction).fill(Y2K.peach)
        }
        .clipShape(Capsule())
    }
}

/// The left `fraction` of the rect, with round ends.
struct BarFill: Shape {
    let fraction: Double
    func path(in r: CGRect) -> Path {
        let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
        guard f > 0 else { return Path() }
        let w = max(r.height, r.width * f)
        return Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: w, height: r.height), cornerRadius: r.height / 2)
    }
}

/// A small outlined LCD badge: "YTM", "AAC 131".
struct Badge: View {
    let text: String
    var body: some View {
        Text(text).font(Y2K.dot(7.5)).tracking(0.75).foregroundStyle(Y2K.lilac).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).frame(height: 11)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Y2K.lilac.opacity(140 / 255), lineWidth: 0.8))
    }
}

/// The candy play button (wb_play): the gradient, a white rim, a gloss on top; a dark play / pause.
struct Candy: View {
    let size: CGFloat
    let playing: Bool
    var body: some View {
        ZStack {
            Circle().fill(Ink.well)
            Circle().fill(LinearGradient(colors: Y2K.smartColors, startPoint: .bottomLeading, endPoint: .topTrailing)).padding(2)
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1).padding(2)
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.66, height: size * 0.46).offset(y: -size * 0.2)
            PlayPauseGlyph(playing: playing).fill(Ink.candyText)
                .frame(width: size * 0.44, height: size * 0.44)
        }
        .frame(width: size, height: size)
    }
}
