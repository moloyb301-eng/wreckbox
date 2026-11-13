import AppKit
import Shared
import SwiftUI
import WidgetKit

// The macOS widget (desktop / Notification Centre): the Player's LCD look — cover, title and artist, source and format
// badges, a clock and progress that run by themselves, and the transport. Small: the whole widget plays / pauses.
// Medium: + previous / next / like. Large: + the next five songs, shuffle / repeat and the EQ preset.
// It reads what the app writes (WidgetFiles); its buttons are wbplayer:// links the app runs.

struct Entry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
    let art: NSImage?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snap: WidgetSnapshot(title: "Babydoll", artist: "Ari Abdul", source: "LOCAL", quality: "FLAC · 16/44.1 · 912 kbps",
                                                 playing: true, position: 42, duration: 151, track: "3/24"), art: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(current() ?? placeholder(in: context)) }

    /// One entry: the app reloads the widget whenever something it shows changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [current() ?? Entry(date: Date(), snap: WidgetSnapshot(), art: nil)], policy: .never))
    }

    private func current() -> Entry? {
        guard let s = WidgetFiles.read() else { return nil }
        return Entry(date: Date(), snap: s, art: s.hasArt ? NSImage(contentsOf: WidgetFiles.art) : nil)
    }
}

// MARK: - Look

private enum Tone {
    static let peach = Color(red: 0.937, green: 0.686, blue: 0.525)
    static let lilac = Color(red: 0.733, green: 0.588, blue: 0.855)
    static let blue = Color(red: 0.663, green: 0.784, blue: 0.941)
    static let smart = [blue, peach, lilac]
    static func dot(_ s: CGFloat) -> Font { .custom("Doto", size: s).weight(.bold) }
    static func ui(_ s: CGFloat, _ w: Font.Weight = .regular) -> Font { .custom("Urbanist", size: s).weight(w) }
}

struct PlayerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry
    var s: WidgetSnapshot { entry.snap }

    /// When the song "started" (for the self-running clock and progress).
    private var start: Date { s.at.addingTimeInterval(-s.position) }
    private var end: Date { start.addingTimeInterval(max(s.duration, s.position + 1)) }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge, .systemExtraLarge: large
            default: medium
            }
        }
        .containerBackground(for: .widget) { background }
    }

    private var background: some View {
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.04)
            if let art = entry.art {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill).blur(radius: 30).opacity(0.45).saturation(1.3)
            }
            RadialGradient(colors: [Color(red: 0.165, green: 0.12, blue: 0.24).opacity(0.8), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 300)
            LinearGradient(colors: [.black.opacity(0.1), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: sizes

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                cover(54)
                Spacer()
                Image(systemName: s.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 28))
                    .foregroundStyle(LinearGradient(colors: Tone.smart, startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            Spacer(minLength: 0)
            titles(14, 11)
            progress
            HStack { clock(13); Spacer(); badges(limit: 1) }
        }
        .widgetURL(WidgetCommand.toggle.url)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            cover(118)
            VStack(alignment: .leading, spacing: 6) {
                HStack { clock(18); Spacer(); badges(limit: 2) }
                titles(15, 12)
                progress
                Spacer(minLength: 0)
                transport
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                cover(132)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { clock(20); Spacer(); badges(limit: 3) }
                    titles(17, 13)
                    Text(s.quality ?? (s.source == "SPOTIFY" ? "Spotify stream" : " ")).font(Tone.dot(10)).foregroundStyle(Tone.peach.opacity(0.85))
                    progress
                    Spacer(minLength: 0)
                    transport
                }
            }
            .frame(height: 132)
            HStack(spacing: 8) {
                key(s.shuffle ? "shuffle.circle.fill" : "shuffle", .shuffle, lit: s.shuffle)
                key(s.repeatMode == 2 ? "repeat.1" : "repeat", .repeatMode, lit: s.repeatMode != 0)
                key("gobackward.10", .back10)
                key("goforward.10", .fwd10)
                Spacer()
                Text("EQ · \(s.eqOn ? s.eqPreset : "Off")").font(Tone.dot(10)).foregroundStyle(Tone.lilac)
            }
            Rectangle().fill(Tone.lilac.opacity(0.18)).frame(height: 0.8)
            Text("UP NEXT").font(Tone.dot(10)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
            if s.upcoming.isEmpty { Text("Nothing up next").font(Tone.ui(12)).foregroundStyle(.white.opacity(0.45)) }
            ForEach(s.upcoming, id: \.number) { u in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", u.number)).font(Tone.dot(10)).foregroundStyle(Tone.lilac).frame(width: 20, alignment: .leading)
                    Text(u.title).font(Tone.ui(12, .semibold)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                    Text(u.artist).font(Tone.ui(11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: pieces

    private func cover(_ size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
        return ZStack {
            if let art = entry.art { Image(nsImage: art).resizable().aspectRatio(contentMode: .fill) }
            else { LinearGradient(colors: Tone.smart.map { $0.opacity(0.4) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                   Image(systemName: "opticaldisc").font(.system(size: size * 0.35)).foregroundStyle(.white.opacity(0.4)) }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(AngularGradient(colors: Tone.smart + [Tone.blue], center: .center), lineWidth: s.title == nil ? 0 : 1.5))
    }

    private func titles(_ t: CGFloat, _ a: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(s.title ?? "Nothing playing").font(Tone.ui(t, .bold)).foregroundStyle(.white).lineLimit(1)
            Text(s.artist ?? "Open WreckBox Player").font(Tone.ui(a, .medium)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
        }
    }

    /// The clock: runs by itself while playing (peach Doto, like the LCD).
    @ViewBuilder private func clock(_ size: CGFloat) -> some View {
        Group {
            if s.playing && s.duration > 0 { Text(timerInterval: start...end, countsDown: false) }
            else { Text(Self.time(s.position)) }
        }
        .font(Tone.dot(size)).foregroundStyle(Tone.peach).shadow(color: Tone.peach.opacity(0.6), radius: 4)
        .monospacedDigit()
    }

    @ViewBuilder private var progress: some View {
        Group {
            if s.playing && s.duration > 0 { ProgressView(timerInterval: start...end, countsDown: false, label: { EmptyView() }, currentValueLabel: { EmptyView() }) }
            else { ProgressView(value: s.duration > 0 ? min(1, s.position / s.duration) : 0) }
        }
        .progressViewStyle(.linear).tint(Tone.peach).controlSize(.small)
    }

    private func badges(limit: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array([s.sourceBadge, s.format, s.shuffle ? "SHUF" : ""].filter { !$0.isEmpty }.prefix(limit)), id: \.self) { b in
                Text(b).font(Tone.dot(8.5)).foregroundStyle(Tone.lilac).lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Tone.lilac.opacity(0.55), lineWidth: 0.8))
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            key("backward.fill", .previous)
            Link(destination: WidgetCommand.toggle.url) {
                ZStack {
                    Circle().fill(LinearGradient(colors: Tone.smart, startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .heavy)).foregroundStyle(Color(white: 0.1))
                }
                .frame(width: 36, height: 36)
            }
            key("forward.fill", .next)
            Spacer()
            key(s.liked ? "heart.fill" : "heart", .like, lit: s.liked)
        }
    }

    private func key(_ icon: String, _ c: WidgetCommand, lit: Bool = false) -> some View {
        Link(destination: c.url) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(lit ? Tone.lilac : .white.opacity(0.85))
                .frame(width: 28, height: 28).background(Circle().fill(.white.opacity(0.08)))
        }
    }

    static func time(_ s: Double) -> String { let i = Int(max(0, s)); return String(format: "%d:%02d", i / 60, i % 60) }
}

struct PlayerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: Provider()) { PlayerWidgetView(entry: $0) }
            .configurationDisplayName("WreckBox Player")
            .description("What's playing, with play / pause, next and up next.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct PlayerWidgets: WidgetBundle {
    var body: some Widget { PlayerWidget() }
}
