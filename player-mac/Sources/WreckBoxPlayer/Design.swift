import AppKit
import CoreText
import SwiftUI

// The WreckBox look, as on the Android Player (Theme.kt) and the Mac app (Theme.swift): near-black frosted glass,
// Urbanist for text, Doto (dot-matrix) for labels and readouts, the light-blue → peach → lilac gradient for smart
// things, and a few Y2K touches used the same way everywhere — the LCD, the candy play button, the iridescent rim on
// covers, the dot spectrum and the pixel-record logo.

enum W {
    static let bg = Color(hex: 0x08080A)
    static let bgRaised = Color(hex: 0x111115)
    static let text = Color.white.opacity(0.94)
    static let text2 = Color.white.opacity(0.66)
    static let text3 = Color.white.opacity(0.46)
    static let hairline = Color.white.opacity(0.08)
    static let glassFill = Color.white.opacity(0.045)
    static let hover = Color.white.opacity(0.06)
    static let peach = Color(hex: 0xEFAF86)
    static let lilac = Color(hex: 0xBB96DA)
    static let blue = Color(hex: 0xA9C8F0)
    static let smartColors = [blue, peach, lilac]
    static let smart = LinearGradient(colors: smartColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let iridescent = AngularGradient(colors: [blue, peach, lilac, blue], center: .center)

    enum Radius { static let card: CGFloat = 24; static let tile: CGFloat = 20; static let row: CGFloat = 12; static let art: CGFloat = 8 }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Urbanist", size: size).weight(weight) }
    static func dot(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .custom("Doto", size: size).weight(weight) }

    /// The fonts ship in the app's Resources/Fonts (make-app.sh); during `swift run` they come from the source tree.
    static func registerFonts() {
        var dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts")]
        dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Fonts"))
        for dir in dirs.compactMap({ $0 }) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil), !files.isEmpty else { continue }
            for f in files where f.pathExtension.lowercased() == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
            return
        }
    }

    /// Source tags: MAC lilac · YOUTUBE peach · SPOTIFY light blue.
    static func color(_ s: Source) -> Color {
        switch s { case .local: return lilac; case .youtube: return peach; case .spotify: return blue }
    }

    /// The dot displays: lilac → light blue → peach by height.
    static func dotColor(_ h: Double) -> Color {
        func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
            let x = NSColor(a).usingColorSpace(.sRGB)!, y = NSColor(b).usingColorSpace(.sRGB)!
            return Color(.sRGB, red: x.redComponent + (y.redComponent - x.redComponent) * t,
                         green: x.greenComponent + (y.greenComponent - x.greenComponent) * t,
                         blue: x.blueComponent + (y.blueComponent - x.blueComponent) * t)
        }
        return h < 0.5 ? mix(lilac, blue, h * 2) : mix(blue, peach, (h - 0.5) * 2)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: - Surfaces

extension View {
    /// Frosted glass: blurred material, a faint white fill, a top-lit hairline.
    func glass(_ radius: CGFloat = W.Radius.card, tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            ZStack {
                shape.fill(.ultraThinMaterial)
                shape.fill(W.glassFill)
                if let tint { shape.fill(tint.opacity(0.10)) }
            }
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }

    func smartGlass(_ radius: CGFloat = W.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(W.smart).opacity(0.16)).overlay(shape.strokeBorder(W.smart.opacity(0.55), lineWidth: 1))
    }

    /// The iridescent rim: a thin blue → peach → lilac ring, like the widget's shell.
    func iridescentRim(_ radius: CGFloat, width: CGFloat = 1.5) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(W.iridescent, lineWidth: width))
    }
}

/// The playing song's cover, huge and blurred, behind the whole window; soft gradients with nothing playing.
struct AmbientBackground: View {
    let art: String?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            W.bg
            if let image {
                Color.clear.overlay {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).blur(radius: 90).opacity(0.42).saturation(1.3)
                }
                .clipped()
                .transition(.opacity)
            } else {
                RadialGradient(colors: [W.lilac.opacity(0.16), .clear], center: .topTrailing, startRadius: 20, endRadius: 700)
                RadialGradient(colors: [W.peach.opacity(0.08), .clear], center: .bottomLeading, startRadius: 20, endRadius: 600)
            }
            LinearGradient(colors: [W.bg.opacity(0.2), W.bg.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: image)
        .task(id: art) { image = await Images.shared.load(art, size: 160) }
    }
}

// MARK: - Type pieces

struct DotLabel: View {
    let text: String
    var color: Color = W.text2
    var size: CGFloat = 11
    init(_ text: String, color: Color = W.text2, size: CGFloat = 11) { self.text = text; self.color = color; self.size = size }
    var body: some View { Text(text.uppercased()).font(W.dot(size)).tracking(1.6).foregroundStyle(color).lineLimit(1) }
}

/// A section header: dot label, optional action on the right.
struct SectionHeader: View {
    let title: String
    var action: String?
    var onAction: (() -> Void)?
    var body: some View {
        HStack {
            DotLabel(title, size: 12)
            Spacer()
            if let action, let onAction {
                Button(action, action: onAction).buttonStyle(.plain).font(W.ui(13, .semibold)).foregroundStyle(W.text2)
            }
        }
        .padding(.top, 22).padding(.bottom, 8)
    }
}

/// The pixel-art record on its beige tile (the app icon).
struct PixelRecord: View {
    var size: CGFloat = 22
    var tile = true

    static func cell(_ x: Int, _ y: Int) -> Color? {
        let dx = Double(x) - 15.5, dy = Double(y) - 15.5
        let r = (dx * dx + dy * dy).squareRoot()
        let angle = atan2(dy, dx) * 180 / .pi
        switch r {
        case ..<1.6: return nil
        case ..<3.6: return W.lilac
        case ..<5.6: return W.peach
        case ..<6.3: return Color(hex: 0x050506)
        case ..<14.6:
            let glint = (angle > -150 && angle < -118) || (angle > 30 && angle < 62)
            let band = Int((r - 6.3) / 1.7) % 2 == 0
            if glint { return band ? Color(hex: 0x4A4A56) : Color(hex: 0x5C5C6A) }
            return band ? Color(hex: 0x15151A) : Color(hex: 0x202027)
        case ..<15.6: return Color(hex: 0x34343E)
        default: return nil
        }
    }

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width
            var inner = s, o: CGFloat = 0
            if tile {
                ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: s, height: s), cornerRadius: s * 0.225),
                         with: .linearGradient(Gradient(colors: [Color(hex: 0xF1ECE4), Color(hex: 0xDCD5CA)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: s)))
                inner = s * 0.78; o = (s - inner) / 2
            }
            let px = inner / 32
            for y in 0..<32 { for x in 0..<32 {
                guard let c = Self.cell(x, y) else { continue }
                ctx.fill(Path(CGRect(x: o + CGFloat(x) * px, y: o + CGFloat(y) * px, width: px + 0.4, height: px + 0.4)), with: .color(c))
            } }
        }
        .frame(width: size, height: size)
    }
}

/// The pixel record and WRECKBOX in Doto with the gradient.
struct Wordmark: View {
    var size: CGFloat = 26
    var body: some View {
        HStack(spacing: 10) {
            PixelRecord(size: size)
            Text("WRECKBOX").font(W.dot(size * 0.72, .black)).tracking(2).foregroundStyle(W.smart)
        }
    }
}

// MARK: - Controls

/// Capsule chip: white with a lilac dot when selected, glass otherwise.
struct Chip: View {
    let label: String
    var count: Int?
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected { Circle().fill(W.lilac).frame(width: 6, height: 6) }
                Text(label).font(W.ui(13, .semibold)).lineLimit(1)
                if let count { Text("\(count)").font(W.dot(11)).opacity(0.6) }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .fixedSize()
            .foregroundStyle(selected ? Color.black : W.text2)
            .background { if selected { Capsule().fill(.white) } else { Capsule().fill(W.glassFill).overlay(Capsule().strokeBorder(W.hairline)) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct Pill: View {
    enum Style { case glass, primary, smart }
    let label: String
    var icon: String?
    var style: Style = .glass
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(label).font(W.ui(13.5, .semibold))
            }
            .padding(.horizontal, 15).padding(.vertical, 8)
            .foregroundStyle(style == .primary ? Color.black : W.text)
            .background {
                switch style {
                case .primary: Capsule().fill(.white)
                case .smart: Capsule().fill(W.smart.opacity(0.28)).overlay(Capsule().strokeBorder(W.smart.opacity(0.7)))
                case .glass: Capsule().fill(W.glassFill).overlay(Capsule().strokeBorder(W.hairline))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

struct RoundButton: View {
    let icon: String
    var help = ""
    var size: CGFloat = 34
    var tint: Color = W.text
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(W.glassFill).overlay(Circle().strokeBorder(W.hairline)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The candy play button: the gradient with a gloss on its top half and a dark well around it.
struct CandyButton: View {
    let size: CGFloat
    let playing: Bool
    var help = "Play / pause (Space)"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(hex: 0x07060A))
                Circle().fill(LinearGradient(colors: W.smartColors, startPoint: .topLeading, endPoint: .bottomTrailing)).padding(2)
                    .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1).padding(2))
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.68, height: size * 0.42).offset(y: -size * 0.24)
                Image(systemName: playing ? "pause.fill" : "play.fill").font(.system(size: size * 0.36, weight: .heavy))
                    .foregroundStyle(Color(hex: 0x1A1622)).offset(x: playing ? 0 : size * 0.03)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Y2K readouts

/// The LCD: deep violet glass with ghost dots, scanlines and a soft glare, where the player's numbers live.
struct Lcd<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background {
                ZStack {
                    RadialGradient(colors: [Color(hex: 0x2A1F3D), Color(hex: 0x07060B)], center: .bottomTrailing, startRadius: 10, endRadius: 520)
                    Canvas { ctx, sz in
                        var y: CGFloat = 1.7
                        while y < sz.height {
                            var x: CGFloat = 1.7
                            while x < sz.width { ctx.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(.white.opacity(0.035))); x += 3.4 }
                            y += 3.4
                        }
                        y = 0
                        while y < sz.height { ctx.fill(Path(CGRect(x: 0, y: y, width: sz.width, height: 0.7)), with: .color(.black.opacity(0.10))); y += 2 }
                    }
                }
            }
            .overlay {
                GeometryReader { g in
                    Path { p in
                        let w = g.size.width, h = g.size.height
                        p.move(to: CGPoint(x: w * 0.52, y: 0)); p.addLine(to: CGPoint(x: w * 0.76, y: 0))
                        p.addLine(to: CGPoint(x: w * 0.46, y: h)); p.addLine(to: CGPoint(x: w * 0.22, y: h)); p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                }
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(W.lilac.opacity(0.25), lineWidth: 1))
    }
}

/// A glowing LCD readout (peach digits over faint "88:88" segments).
struct LcdText: View {
    let text: String
    var ghost: String?
    var size: CGFloat = 22
    var color: Color = W.peach
    var body: some View {
        ZStack(alignment: .leading) {
            if let ghost { Text(ghost).font(W.dot(size, .black)).foregroundStyle(color.opacity(0.12)) }
            Text(text).font(W.dot(size, .black)).foregroundStyle(color).shadow(color: color.opacity(0.6), radius: 7)
        }
    }
}

/// A small outlined LCD badge: "FLAC 24/96", "SHUF".
struct LcdBadge: View {
    let text: String
    var color: Color = W.lilac
    var body: some View {
        Text(text).font(W.dot(10)).tracking(1).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.55), lineWidth: 0.8))
    }
}

/// The dot spectrum: columns of dots lit by the music's REAL spectrum (Levels). Still when nothing can be measured
/// (paused, Spotify) — nothing is faked. It only listens while on screen.
struct DotSpectrum: View {
    var live: Bool
    var cols = 4
    var rows = 4
    var dot: CGFloat = 3
    var gap: CGFloat = 1.5
    @ObservedObject private var levels = Levels.shared

    var body: some View {
        Canvas { ctx, sz in
            let b = live ? levels.bands : nil
            for i in 0..<cols {
                var level: Float = 0
                if let b {
                    let from = i * Levels.count / cols, to = max(from + 1, (i + 1) * Levels.count / cols)
                    level = b[from..<min(to, b.count)].max() ?? 0
                }
                let lit = b == nil ? 1 : max(0, min(rows, Int(level * Float(rows) + 0.35)))
                for r in 0..<rows {
                    let on = r < lit
                    let c: Color = !on ? .white.opacity(0.08) : b == nil ? W.text3 : W.dotColor(Double(r) / Double(max(1, rows - 1)))
                    let rect = CGRect(x: CGFloat(i) * (dot + gap), y: sz.height - CGFloat(r + 1) * dot - CGFloat(r) * gap, width: dot, height: dot)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: dot * 0.3), with: .color(c))
                }
            }
        }
        .frame(width: dot * CGFloat(cols) + gap * CGFloat(cols - 1), height: dot * CGFloat(rows) + gap * CGFloat(rows - 1))
        .onAppear { if live { Levels.shared.want() } }
        .onDisappear { if live { Levels.shared.unwant() } }
    }
}

/// The EQ as the apps draw it: ten dot columns from −12 to +12 dB, lit from the 0 line. Drag or click to shape it.
struct EqDots: View {
    let gains: [Float]
    let on: Bool
    var onBand: ((Int, Float) -> Void)?

    var body: some View {
        GeometryReader { g in
            Canvas { ctx, sz in
                let dots = 13, half = dots / 2
                let colW = sz.width / 10, step = sz.height / CGFloat(dots - 1)
                for i in 0..<10 {
                    let x = colW * (CGFloat(i) + 0.5)
                    let level = Int((Double(gains[safe: i] ?? 0) / 12 * Double(half)).rounded())
                    for row in 0..<dots {
                        let k = half - row
                        let lit = (level > 0 && (1...level).contains(k)) || (level < 0 && k < 0 && k >= level)
                        let c: Color = k == 0 ? W.text3 : lit && on ? W.dotColor(Double(row) / Double(dots - 1)) : lit ? .white.opacity(0.35) : .white.opacity(0.07)
                        let w = colW * 0.5
                        ctx.fill(Path(roundedRect: CGRect(x: x - w / 2, y: CGFloat(row) * step - 1.5, width: w, height: 3), cornerRadius: 1), with: .color(c))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard let onBand else { return }
                let band = max(0, min(9, Int(v.location.x / g.size.width * 10)))
                let db = max(-12, min(12, (0.5 - v.location.y / g.size.height) * 24))
                onBand(band, Float((db * 2).rounded() / 2))
            })
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// "3:07" / "1:02:03".
func timeLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Snapshots (dev)

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// True when rendering off-screen for `wbplayer://dev/snapshot`: scroll views become plain stacks.
    var snapshotMode: Bool { get { self[SnapshotModeKey.self] } set { self[SnapshotModeKey.self] = newValue } }
}

/// A vertical ScrollView that renders as a clipped stack in snapshot mode (ImageRenderer can't draw scroll views).
struct Scroller<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    @ViewBuilder var content: Content
    var body: some View {
        if snapshot {
            VStack(spacing: 0) { content }.fixedSize(horizontal: false, vertical: true)
                .frame(height: 0, alignment: .top).frame(maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { content }
        }
    }
}
