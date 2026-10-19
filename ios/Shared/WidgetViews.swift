import AppIntents
import SwiftUI
import WidgetKit

// The iPhone widgets: the Android Player's Y2K widget re-imagined in iOS's shape. An iPhone widget is a fixed, opaque
// rounded tile, so instead of the Sonique silhouette (logo bump, S-curve, round pod, hanging tabs) the tile itself is
// the casing — violet graphite, a sheen, faint swirls, a bevel and the iridescent rim — and everything on it follows
// the tile: iOS's standard margins and corners concentric with the tile's (ContainerRelativeShape).
//  - The LCD (ripple glass; peach Doto clock over ghost 88:88, TRK counter, lilac badges, the dot display, title,
//    artist, seek bar) is the hero.
//  - The dial becomes the jog pad: a rounded square with the candy play button in the middle and four keys round it
//    (+10 s above, −10 s below, previous / next at the sides), as on Android.
//  - The hanging tabs become a segmented strip, and the drawer a panel in the tile (Large).
//  - No glow: blurred shadows are offscreen bitmaps the widget can't afford; the light comes from gradients instead.
//
// Sizes:
//  - Large: the LCD + pad, the logo and the tabs, and the Equaliser / Queue / Options panel.
//  - Medium: the LCD + pad.
//  - Small: the LCD and the transport.
//  - Lock screen: now playing, a play/pause ring, a line of text.
//
// Memory rules (a widget extension has ~30 MB; running out = a blank tile, and every reload — each button press —
// redraws everything): no pictures at all (the casing is shapes: WidgetShapes.swift), no Canvas, no shadows, no
// GeometryReader (one inside a button crashed iOS 27's renderer), one light timeline entry; the clock and the seek
// bar run by themselves.

struct PlayerEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
    /// The widget's size on this phone (from the timeline context).
    var size: CGSize
    var drawer: Int = WidgetFiles.drawer
}

struct PlayerProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlayerEntry {
        PlayerEntry(date: Date(), snap: WidgetSnapshot(title: "Babydoll", artist: "Ari Abdul", source: "LOCAL", quality: "FLAC · 16/44.1 · 912 kbps",
                                                       playing: true, position: 42, duration: 151, track: "003/024"), size: context.displaySize)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlayerEntry) -> Void) {
        WidgetFiles.log("snapshot for \(context.family)")
        completion(Self.entry(size: context.displaySize) ?? placeholder(in: context))
    }

    /// One entry; the app reloads the widgets whenever something they show changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlayerEntry>) -> Void) {
        WidgetFiles.log("timeline for \(context.family) \(Int(context.displaySize.width))×\(Int(context.displaySize.height))")
        let e = Self.entry(size: context.displaySize) ?? PlayerEntry(date: Date(), snap: WidgetSnapshot(), size: context.displaySize)
        // If the app hasn't said otherwise a little after the song should have ended (it was closed mid-song), show
        // it paused at the end instead of "playing" with a stopped clock.
        var entries = [e]
        if e.snap.playing && e.snap.duration > 0 {
            // The seek bar moves in steps: about 40 per song, at least 3 s apart.
            let remaining = max(0, e.snap.duration - e.snap.position)
            let step = max(3, e.snap.duration / 40)
            var t = step
            while t < remaining && entries.count < 60 {
                entries.append(PlayerEntry(date: Date().addingTimeInterval(t), snap: e.snap, size: e.size, drawer: e.drawer))
                t += step
            }
            let endsAt = e.snap.at.addingTimeInterval(max(0, e.snap.duration - e.snap.position) + 10)
            var stopped = e.snap
            stopped.playing = false
            stopped.position = stopped.duration
            entries.append(PlayerEntry(date: endsAt, snap: stopped, size: e.size, drawer: e.drawer))
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    static func entry(size: CGSize) -> PlayerEntry? {
        // Only the snapshot: the widgets draw no pictures.
        guard let s = WidgetFiles.read() else { return nil }
        return PlayerEntry(date: Date(), snap: s, size: size)
    }
}

/// The palette's darks, as on Android.
enum Ink {
    static let well = Color(hex: 0x07060A)
    static let keyTop = Color(hex: 0x34303F), keyBottom = Color(hex: 0x16141C)
    static let cardTop = Color(hex: 0x120F1A)
    static let candyText = Color(hex: 0x0A0A0C)
    static let padTop = Color(hex: 0x3E3A4B), padBottom = Color(hex: 0x15131B)
}

struct PlayerWidgetView: View {
    @Environment(\.widgetFamily) private var systemFamily
    let entry: PlayerEntry
    /// Drawn by the app for testing (wreckbox://widgetlab): the background inline, iOS's margins added by hand.
    var lab = false
    /// The size to draw in the test drawing (an app can't set the widget environment).
    var labFamily: WidgetFamily?
    private var family: WidgetFamily { labFamily ?? systemFamily }
    var s: WidgetSnapshot { entry.snap }

    private var start: Date { s.at.addingTimeInterval(-s.position) }
    private var end: Date { start.addingTimeInterval(max(s.duration, s.position + 1)) }
    /// How far through the song at this entry's time (the timeline steps the bar along while playing).
    private var fraction: Double {
        guard s.duration > 0 else { return 0 }
        let pos = s.playing ? s.position + entry.date.timeIntervalSince(s.at) : s.position
        return min(1, max(0, pos / s.duration))
    }
    /// The open panel on the large widget (one is always open; an old "none" counts as Queue).
    private var drawer: Int { (0...2).contains(entry.drawer) ? entry.drawer : 1 }

    var body: some View {
        switch family {
        case .accessoryInline: inline.modifier(Backed(lab: lab, casing: false))
        case .accessoryCircular: circular.modifier(Backed(lab: lab, casing: false))
        case .accessoryRectangular: rectangular.modifier(Backed(lab: lab, casing: false))
        case .systemSmall: small.modifier(Backed(lab: lab, casing: true)).widgetURL(Self.openURL)
        case .systemLarge, .systemExtraLarge: large.modifier(Backed(lab: lab, casing: true)).widgetURL(Self.openURL)
        default: deck.modifier(Backed(lab: lab, casing: true)).widgetURL(Self.openURL)
        }
    }

    /// Tapping anywhere that isn't a button opens Now playing.
    static let openURL = URL(string: "wreckbox://show?page=playing")!

    /// The casing behind (the container background in a widget; inline, with the margins, in the app's test drawing).
    private struct Backed: ViewModifier {
        let lab: Bool
        let casing: Bool
        func body(content: Content) -> some View {
            if lab { content.padding(16).background { if casing { CasingView() } } }
            else { content.containerBackground(for: .widget) { if casing { CasingView() } else { Color.clear } } }
        }
    }

    // MARK: medium (and the top of large): the LCD beside the jog pad

    private var deck: some View {
        HStack(spacing: 10) {
            lcd
            JogPad(playing: s.playing).aspectRatio(1, contentMode: .fit)
        }
    }

    // MARK: large

    private var large: some View {
        VStack(spacing: 10) {
            deck.frame(height: 138)
            HStack(spacing: 8) {
                logo
                Spacer(minLength: 4)
                tabs
            }
            .frame(height: 26)
            Group {
                switch drawer {
                case 0: eqPanel
                case 2: optionsPanel
                default: queuePanel
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Card())
        }
    }

    /// The record tile + WRECKBOX in Doto, in the app's gradient; the status light after it.
    private var logo: some View {
        HStack(spacing: 6) {
            Disc(size: 18, tile: true)
            Text("WRECKBOX").font(Y2K.dot(11, .black)).tracking(1.6).lineLimit(1).fixedSize()
                .foregroundStyle(LinearGradient(colors: [Y2K.blue, Y2K.peach, Y2K.lilac], startPoint: .leading, endPoint: .trailing))
            StatusLight(on: s.playing)
        }
    }

    // MARK: LCD

    private var lcd: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Clock(s: s, start: start, end: end, size: 26)
                Spacer(minLength: 4)
                DotDisplay(gains: s.eqOn ? s.eqGains : [], playing: s.playing).frame(width: 46, height: 24).padding(.top, 3)
            }
            HStack(spacing: 4) {
                Text(s.track.isEmpty ? "TRK ---/---" : "TRK \(s.track)").font(Y2K.dot(8)).tracking(1.1).foregroundStyle(Y2K.lilac.opacity(150 / 255))
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 2)
                ForEach(badges(room: 84), id: \.self) { Badge(text: $0) }
            }
            .frame(height: 11).padding(.top, 2)
            Rectangle().fill(Y2K.lilac.opacity(40 / 255)).frame(height: 0.8).padding(.vertical, 4)
            Text(s.title ?? "Nothing playing").font(Y2K.ui(14, .bold)).foregroundStyle(Y2K.text).lineLimit(1)
            Text(s.artist ?? "Tap play to pick up where you left off").font(Y2K.ui(11, .medium)).foregroundStyle(Y2K.text2).lineLimit(1)
            Spacer(minLength: 4)
            SeekBar(fraction: fraction).frame(height: 4)
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LcdGlass())
    }

    /// Source, format, shuffle, repeat: added by importance while they fit beside the counter.
    private func badges(room: CGFloat) -> [String] {
        var out: [String] = [], used: CGFloat = 0
        for b in [s.sourceBadge, s.format, s.shuffle ? "SHUF" : "", s.repeatMode == 2 ? "RPT1" : s.repeatMode == 1 ? "RPT" : ""] where !b.isEmpty {
            let w = CGFloat(b.count) * 5.6 + 14
            if used + w <= room { out.append(b); used += w }
        }
        return out
    }

    // MARK: tabs + panels

    private static let tabNames = ["EQ", "Queue", "Options"]

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Button(intent: DrawerIntent(i)) {
                    Text(Self.tabNames[i]).font(Y2K.ui(11.5, .bold)).foregroundStyle(drawer == i ? Ink.candyText : Y2K.text2).lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).frame(height: 22)
                        .background { if drawer == i { Capsule().fill(LinearGradient(colors: Y2K.smartColors, startPoint: .leading, endPoint: .trailing)) } }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Ink.well))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.8))
    }

    private var eqPanel: some View {
        let presets: [(String, String)] = [("Flat", "Flat"), ("Bass boost", "Bass"), ("Club", "Club"), ("Hip-hop", "Hip-hop"),
                                           ("Electronic", "Electro"), ("Vocal", "Vocal"), ("Treble", "Treble"), ("Loudness", "Loud")]
        return HStack(alignment: .top, spacing: 8) {
            EqPanel(gains: s.eqGains, on: s.eqOn, preset: s.eqPreset)
            VStack(spacing: 5) {
                HStack {
                    Text("PRESETS").font(Y2K.dot(8)).tracking(1.2).foregroundStyle(Y2K.text3)
                    Spacer(minLength: 2)
                    Button(intent: PlayerCommandIntent(.eqToggle)) { Key(label: s.eqOn ? "On" : "Off", lit: s.eqOn, w: 40, size: 10.5, weight: .bold) }.buttonStyle(.plain)
                }
                ForEach(0..<4, id: \.self) { r in
                    HStack(spacing: 5) {
                        ForEach(0..<2, id: \.self) { c in
                            let p = presets[r * 2 + c]
                            Button(intent: EQPresetIntent(p.0)) { Key(label: p.1, lit: s.eqOn && s.eqPreset == p.0, size: 11) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(width: 136)
        }
        .padding(10)
    }

    private var queuePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("UP NEXT").font(Y2K.dot(8)).tracking(1.2).foregroundStyle(Y2K.text3)
                Spacer()
                Text(s.track.isEmpty ? "" : "TRK \(s.track)").font(Y2K.dot(8)).tracking(1.2).foregroundStyle(Y2K.lilac.opacity(0.6))
            }
            .frame(height: 16)
            if s.upcoming.isEmpty {
                Text("Nothing up next").font(Y2K.ui(12, .medium)).foregroundStyle(Y2K.text3).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            ForEach(Array(s.upcoming.prefix(5).enumerated()), id: \.offset) { _, u in
                Button(intent: JumpIntent(u.number - 1)) { QueueRow(number: u.number, title: u.title, artist: u.artist) }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private var optionsPanel: some View {
        let source: String? = s.source.map { $0 == "YOUTUBE" ? "YouTube Music" : $0 == "LOCAL" ? "Phone" : "Spotify" }
        let info = [s.track.isEmpty ? "Nothing queued" : "TRK \(s.track)", source, s.quality].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            Text(info.uppercased()).font(Y2K.dot(8)).tracking(1.1).foregroundStyle(Y2K.text3).lineLimit(1).frame(height: 16)
            HStack(spacing: 6) {
                Button(intent: PlayerCommandIntent(.shuffle)) { Key(label: s.shuffle ? "Shuffle on" : "Shuffle", lit: s.shuffle, h: 34, size: 12) }.buttonStyle(.plain)
                Button(intent: PlayerCommandIntent(.repeatMode)) { Key(label: s.repeatMode == 2 ? "Repeat 1" : s.repeatMode == 1 ? "Repeat on" : "Repeat", lit: s.repeatMode != 0, h: 34, size: 12) }.buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                Button(intent: PlayerCommandIntent(.like)) { Key(label: s.liked ? "♥ Liked" : "♡ Like", lit: s.liked, h: 34, size: 12) }.buttonStyle(.plain)
                Link(destination: URL(string: "wreckbox://show?page=eq")!) { Key(label: "Equaliser", h: 34, size: 12) }
                Link(destination: Self.openURL) { Key(label: "Open app", h: 34, size: 12) }
            }
        }
        .padding(12)
    }

    // MARK: small: the LCD and the transport

    private var small: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Clock(s: s, start: start, end: end, size: 18)
                    Spacer(minLength: 2)
                    if !s.sourceBadge.isEmpty { Badge(text: s.sourceBadge).padding(.top, 5) }
                }
                Rectangle().fill(Y2K.lilac.opacity(40 / 255)).frame(height: 0.8).padding(.vertical, 3)
                Text(s.title ?? "Nothing playing").font(Y2K.ui(13, .bold)).foregroundStyle(Y2K.text).lineLimit(1)
                Text(s.artist ?? "WreckBox Player").font(Y2K.ui(10.5, .medium)).foregroundStyle(Y2K.text2).lineLimit(1)
                Spacer(minLength: 3)
                SeekBar(fraction: fraction).frame(height: 4)
            }
            .padding(.horizontal, 9).padding(.top, 4).padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(LcdGlass())
            HStack(spacing: 0) {
                Button(intent: PlayerCommandIntent(.previous)) { Key(glyph: "backward.end.fill", w: 38, h: 28, size: 11) }.buttonStyle(.plain)
                Spacer(minLength: 0)
                Button(intent: PlayerCommandIntent(.toggle)) { Candy(size: 42, playing: s.playing) }.buttonStyle(.plain)
                Spacer(minLength: 0)
                Button(intent: PlayerCommandIntent(.next)) { Key(glyph: "forward.end.fill", w: 38, h: 28, size: 11) }.buttonStyle(.plain)
            }
            .frame(height: 42)
        }
    }

    // MARK: lock screen

    private var inline: some View {
        Label(s.title.map { "\($0) — \(s.artist ?? "")" } ?? "WreckBox Player", systemImage: s.playing ? "waveform" : "pause")
    }

    private var circular: some View {
        Button(intent: PlayerCommandIntent(.toggle)) {
            ZStack {
                AccessoryWidgetBackground()
                Circle().stroke(.white.opacity(0.25), lineWidth: 3).padding(4)
                Circle().trim(from: 0, to: fraction).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90)).padding(4)
                Image(systemName: s.playing ? "pause.fill" : "play.fill").font(.system(size: 16, weight: .bold))
            }
        }
        .buttonStyle(.plain)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: s.playing ? "waveform" : "pause.fill").font(.caption2)
                Text(s.title ?? "Nothing playing").font(.headline).lineLimit(1)
            }
            Text(s.artist ?? "WreckBox Player").font(.caption).lineLimit(1).foregroundStyle(.secondary)
            BarFill(fraction: 1).fill(.white.opacity(0.25)).overlay(BarFill(fraction: fraction).fill(.white)).frame(height: 3)
        }
        .widgetAccentable()
    }

    static func time(_ s: Double) -> String { let i = Int(max(0, s)); return String(format: "%d:%02d", i / 60, i % 60) }
}

// MARK: - Pieces (Android's drawables in iOS's shape — shapes and gradients only)

/// The jog pad (Android's dial in a rounded square concentric with the tile): the candy play button in a dark well,
/// +10 s above, −10 s below, previous / next at the sides.
private struct JogPad: View {
    let playing: Bool
    var body: some View {
        ZStack {
            ContainerRelativeShape().fill(LinearGradient(colors: [Ink.padTop, Ink.padBottom], startPoint: .top, endPoint: .bottom))
            ContainerRelativeShape().inset(by: 1)
                .strokeBorder(LinearGradient(colors: [.white.opacity(80 / 255), .black.opacity(130 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2)
            ContainerRelativeShape().strokeBorder(LinearGradient(colors: Y2K.smartColors, startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
            VStack(spacing: 0) {
                padKey(.fwd10, "goforward.10")
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    padKey(.previous, "backward.end.fill")
                    Spacer(minLength: 0)
                    Button(intent: PlayerCommandIntent(.toggle)) {
                        ZStack {
                            Circle().fill(Ink.well).frame(width: 60, height: 60)
                            Candy(size: 52, playing: playing)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    padKey(.next, "forward.end.fill")
                }
                Spacer(minLength: 0)
                padKey(.back10, "gobackward.10")
            }
            .padding(5)
        }
    }

    private func padKey(_ c: WidgetCommand, _ glyph: String) -> some View {
        Button(intent: PlayerCommandIntent(c)) {
            Image(systemName: glyph).font(.system(size: 11, weight: .heavy)).foregroundStyle(Y2K.text)
                .frame(width: 30, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The status light: peach when playing (a lighter core instead of a glow), dim otherwise.
private struct StatusLight: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().fill(on ? Y2K.peach.opacity(0.35) : .clear).frame(width: 9, height: 9)
            Circle().fill(on ? Y2K.peach : .white.opacity(50 / 255)).frame(width: 5, height: 5)
            Circle().fill(.white.opacity(on ? 0.7 : 0)).frame(width: 2, height: 2).offset(x: -0.8, y: -0.8)
        }
    }
}

/// The clock: peach Doto digits over faint "88:88" segments (right-aligned, so the digits sit on their segments), the
/// lilac state mark before them; it runs by itself while playing.
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

/// The seek bar: a dark well with a peach fill (Android's wb_seek). A shape, stepped along by the timeline — not
/// ProgressView(timerInterval:): its built-in GeometryReader placed the fill at x = NaN now and then in iOS 27's
/// widget renderer ("view origin is invalid: (nan, 3.0)"), crashing it and blanking the widget.
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

/// A glossy smoked-plastic key (wb_chip): a dark violet capsule, a light rim, gloss on its top half; lit, a candy key
/// in the app's gradient (wb_chip_on) with dark text. Fills the width it's given unless `w` is set.
private struct Key: View {
    var label: String = ""
    var glyph: String?
    var lit = false
    var w: CGFloat?
    var h: CGFloat = 24
    var size: CGFloat = 11
    var weight: Font.Weight = .semibold

    var body: some View {
        ZStack(alignment: .top) {
            Capsule().fill(lit ? AnyShapeStyle(LinearGradient(colors: Y2K.smartColors, startPoint: .leading, endPoint: .trailing))
                               : AnyShapeStyle(LinearGradient(colors: [Ink.keyTop, Ink.keyBottom], startPoint: .top, endPoint: .bottom)))
            Capsule().fill(LinearGradient(colors: [.white.opacity(lit ? 0.45 : 0.18), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(height: h * 0.45).padding(.horizontal, 6).padding(.top, 1.5)
            Capsule().strokeBorder(lit ? .white.opacity(0.6) : .white.opacity(0.22), lineWidth: 1)
            Group {
                if let glyph {
                    Image(systemName: glyph).font(.system(size: size, weight: .heavy)).foregroundStyle(lit ? Ink.candyText : Y2K.text)
                } else {
                    Text(label).font(Y2K.ui(size, weight)).foregroundStyle(lit ? .black : Y2K.text2).lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 4)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: w, height: h)
        .frame(maxWidth: w == nil ? .infinity : nil)
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

/// A screen panel (wb_card): dark violet glass with a light lip, concentric with the tile.
private struct Card: View {
    var body: some View {
        ContainerRelativeShape().fill(LinearGradient(colors: [Ink.cardTop, Ink.well], startPoint: .top, endPoint: .bottom))
            .overlay(ContainerRelativeShape().strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

/// A row of the Queue panel: Doto number, Urbanist title, dim artist, a hairline under it.
private struct QueueRow: View {
    let number: Int, title: String, artist: String
    var body: some View {
        HStack(spacing: 0) {
            Text(String(format: "%02d", number)).font(Y2K.dot(11, .bold)).foregroundStyle(Y2K.lilac).frame(width: 26, alignment: .leading)
            Text(title).font(Y2K.ui(12.5, .semibold)).foregroundStyle(Y2K.text).lineLimit(1).layoutPriority(1)
            Text(artist).font(Y2K.ui(11, .medium)).foregroundStyle(Y2K.text2).lineLimit(1).padding(.leading, 8)
            Spacer(minLength: 0)
        }
        .frame(height: 27)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(18 / 255)).frame(height: 0.6) }
        .contentShape(Rectangle())
    }
}

/// The Equaliser panel: ten dot columns from −12 to +12 dB, lit from the 0 line, the preset on top. Shapes, one per
/// colour (no Canvas: that's an offscreen bitmap).
private struct EqPanel: View {
    let gains: [Float]
    let on: Bool
    let preset: String
    fileprivate static let dots = 13, half = 6
    private static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    var body: some View {
        let levels = (0..<10).map { i in Int(((i < gains.count ? Double(gains[i]) : 0) / 12 * Double(Self.half)).rounded()) }
        func lit(_ i: Int, _ row: Int) -> Bool {
            let k = Self.half - row, level = levels[i]
            return (level > 0 && k >= 1 && k <= level) || (level < 0 && k < 0 && k >= level)
        }
        return ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.well.opacity(0.6))
            EqDots { _, row in row == Self.half }.fill(Y2K.text3)
            EqDots { i, row in row != Self.half && !lit(i, row) }.fill(.white.opacity(18 / 255))
            if on {
                ForEach(0..<Self.dots, id: \.self) { row in
                    if row != Self.half { EqDots { i, r in r == row && lit(i, r) }.fill(Y2K.dotColor(Double(row) / Double(Self.dots - 1))) }
                }
            } else {
                EqDots { i, row in lit(i, row) }.fill(.white.opacity(90 / 255))
            }
            VStack(spacing: 0) {
                HStack {
                    Text("EQUALISER").font(Y2K.dot(8)).tracking(1.2).foregroundStyle(Y2K.text3)
                    Spacer(minLength: 2)
                    Text(on ? preset : "Off").font(Y2K.ui(10.5, .semibold)).foregroundStyle(on ? Y2K.lilac : Y2K.text3).lineLimit(1)
                }
                .padding(.horizontal, 8).padding(.top, 7)
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    ForEach(Self.labels, id: \.self) { Text($0).font(Y2K.dot(5.5)).foregroundStyle(Y2K.text3).lineLimit(1).fixedSize().frame(maxWidth: .infinity) }
                }
                .padding(.horizontal, 6).frame(height: 10).padding(.bottom, 4)
            }
        }
    }

    /// The dots for which `pick(column, row)` holds.
    private struct EqDots: Shape {
        let pick: (Int, Int) -> Bool
        func path(in r: CGRect) -> Path {
            let w = r.width, h = r.height
            let top: CGFloat = 26, bottom = h - 18, step = (bottom - top) / CGFloat(EqPanel.dots - 1), colW = (w - 12) / 10
            var p = Path()
            for i in 0..<10 { for row in 0..<EqPanel.dots where pick(i, row) {
                let x = 6 + colW * (CGFloat(i) + 0.5)
                p.addRoundedRect(in: CGRect(x: x - 3.2, y: top + CGFloat(row) * step - 1.2, width: 6.4, height: 2.4), cornerSize: CGSize(width: 1, height: 1))
            } }
            return p
        }
    }
}

/// The LCD's dot display: 8 columns × 6 dots. A widget can't follow the music live, so it shows the EQ's shape (lit
/// from the bottom); dim when the EQ is flat or off and nothing plays.
private struct DotDisplay: View {
    let gains: [Float]
    let playing: Bool
    private static let cols = 8, rows = 6

    var body: some View {
        let lit = (0..<Self.cols).map { i -> Int in
            let g = gains.isEmpty ? 0 : gains[min(gains.count - 1, i * gains.count / Self.cols)]
            return gains.isEmpty && !playing ? 0 : max(playing ? 2 : 1, min(Self.rows, Int(((Double(g) + 12) / 24 * Double(Self.rows)).rounded())))
        }
        // DotGrid counts rows from the top; level r (from the bottom) is row rows-1-r.
        return ZStack {
            DotGrid(cols: Self.cols, rows: Self.rows) { c, row in Self.rows - 1 - row >= lit[c] }.fill(.white.opacity(22 / 255))
            ForEach(0..<Self.rows, id: \.self) { level in
                DotGrid(cols: Self.cols, rows: Self.rows) { c, row in Self.rows - 1 - row == level && level < lit[c] }
                    .fill(Y2K.dotColor(Double(level) / Double(Self.rows - 1)))
            }
        }
    }
}
