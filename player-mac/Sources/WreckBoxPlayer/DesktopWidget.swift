import AppKit
import Shared
import SwiftUI

// The desktop widget: the Android Player's home-screen widget on the Mac — a Y2K player shell (smoked violet plastic
// with granite flecks, a bevel and the iridescent rim), an LCD with ghost segments and glare, a round Sonique-style
// dial (previous, next, VOL +/−, the candy play button), and tabs that pull out one drawer at a time: Equaliser,
// Queue, Options. It sits on the desktop (under windows, on every Space) or floats above them.

/// The point grid — the same numbers as the Android widget (wb_widget.xml / PlayerWidget.Geo).
private enum Geo {
    static let width: CGFloat = 400
    static let G: CGFloat = 14
    static let bodyH: CGFloat = 204
    static let R: CGFloat = 28
    static let dial: CGFloat = 124
    static let top: CGFloat = 44
    static let lcdH: CGFloat = 104
    static let seekT: CGFloat = 158
    static let seekH: CGFloat = 6
    static let tabGap: CGFloat = 6
    static let drawerH: CGFloat = 176
    static let dialEnd: CGFloat = 22
    static let lcdRight: CGFloat = 170
    static let slabT: CGFloat = 36
    static let slabB: CGFloat = 178
    static let podR: CGFloat = 80
    static var dialCY: CGFloat { top + dial / 2 }
    static var dialCX: CGFloat { width - dialEnd - dial / 2 }
    static let tabs: [CGFloat] = [88, 76, 84]
    static var tabsEnd: CGFloat { G + tabs.reduce(0, +) + 2 * tabGap }
    static let drawerColor = Color(hex: 0x131218)
}

@MainActor
final class DesktopWidget {
    static let shared = DesktopWidget()
    private var window: NSPanel?
    let model = DesktopWidgetModel()

    var isOpen: Bool { window?.isVisible == true }

    /// Desktop level (under other windows, on every Space) or floating above them.
    var onDesktop: Bool {
        get { UserDefaults.standard.object(forKey: "widgetOnDesktop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "widgetOnDesktop"); applyLevel(); model.objectWillChange.send() }
    }

    func toggle() { isOpen ? close() : open() }

    func open() {
        UserDefaults.standard.set(true, forKey: "widgetOpen")
        if let w = window { w.orderFrontRegardless(); return }
        // Non-activating: its buttons work on the first click without bringing the Player's window forward.
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Geo.width, height: Geo.bodyH), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: DesktopWidgetView(model: model))
        if let saved = UserDefaults.standard.string(forKey: "widgetFrame") {
            w.setFrameTopLeftPoint(NSPointFromString(saved))
        } else if let s = NSScreen.main?.visibleFrame {
            w.setFrameTopLeftPoint(NSPoint(x: s.maxX - Geo.width - 40, y: s.maxY - 40))
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { _ in
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: w.frame.minX, y: w.frame.maxY)), forKey: "widgetFrame")
        }
        window = w
        applyLevel()
        resize()
        w.orderFrontRegardless()
    }

    func close() {
        UserDefaults.standard.set(false, forKey: "widgetOpen")
        window?.orderOut(nil)
    }

    func refresh() { if isOpen { model.objectWillChange.send() } }

    /// A drawer open makes it taller; the top edge stays put.
    func resize() {
        guard let w = window else { return }
        let h = Geo.bodyH + (model.drawer == nil ? 0 : Geo.drawerH - 2) + 10
        var f = w.frame
        f.origin.y = f.maxY - h
        f.size.height = h
        w.setFrame(f, display: true, animate: false)
    }

    private func applyLevel() {
        guard let w = window else { return }
        if onDesktop {
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        } else {
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }
}

@MainActor
final class DesktopWidgetModel: ObservableObject {
    enum Drawer: Int { case eq, queue, options }
    @Published var drawer: Drawer? { didSet { DesktopWidget.shared.resize() } }
}

// MARK: - View

struct DesktopWidgetView: View {
    @ObservedObject var model: DesktopWidgetModel
    @ObservedObject private var player = Player.shared
    @ObservedObject private var eq = EQ.shared
    @ObservedObject private var library = Library.shared
    @State private var hover = false

    var body: some View {
        VStack(spacing: -2) {
            bodyView.frame(width: Geo.width, height: Geo.bodyH).zIndex(1)
            if let d = model.drawer {
                drawer(d).frame(width: Geo.width, height: Geo.drawerH)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(width: Geo.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hover = h } }
    }

    // MARK: body

    private var bodyView: some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: ShellArt.body).resizable().frame(width: Geo.width, height: Geo.bodyH)
            // Logo bump: the tile + WRECKBOX glowing in the gradient.
            HStack(spacing: 9) {
                PixelRecord(size: 20)
                Text("WRECKBOX").font(W.dot(13.5, .black)).tracking(2.2).foregroundStyle(W.smart)
                    .shadow(color: W.lilac.opacity(0.8), radius: 4)
            }
            .offset(x: Geo.G, y: (4 + Geo.top - 2) / 2 - 10)
            // Status light on the slab, left of the pod (as on Android).
            Circle().fill(player.playing ? W.peach : .white.opacity(0.2)).frame(width: 5, height: 5)
                .shadow(color: player.playing ? W.peach : .clear, radius: 4)
                .offset(x: Geo.width - Geo.lcdRight - 8.5, y: Geo.slabT + 4.5)
            // Pin and close: in the clear corner above the pod, while the pointer is over the widget.
            HStack(spacing: 5) {
                tiny(DesktopWidget.shared.onDesktop ? "pin.fill" : "pin.slash",
                     DesktopWidget.shared.onDesktop ? "On the desktop — click to float above windows" : "Floating — click to keep it on the desktop") {
                    DesktopWidget.shared.onDesktop.toggle()
                }
                tiny("xmark", "Close the widget (⌥⌘W brings it back)") { DesktopWidget.shared.close() }
            }
            .opacity(hover ? 1 : 0)
            .offset(x: Geo.width - 42, y: 4)
            lcd.frame(width: Geo.width - Geo.lcdRight - Geo.G, height: Geo.lcdH).offset(x: Geo.G, y: Geo.top)
            seekBar.frame(width: Geo.width - Geo.lcdRight - Geo.G, height: Geo.seekH).offset(x: Geo.G, y: Geo.seekT)
            dial.frame(width: Geo.dial, height: Geo.dial).offset(x: Geo.width - Geo.dialEnd - Geo.dial, y: Geo.top)
            tabsRow.offset(x: Geo.G, y: Geo.slabB - 2)
        }
    }

    private func tiny(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 7.5, weight: .heavy)).foregroundStyle(W.text2).frame(width: 16, height: 13)
                .background(Capsule().fill(Color(hex: 0x1A1822))).overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.6))
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: LCD

    private var lcd: some View {
        let t = player.current
        let snap = WidgetSnapshot(quality: player.quality)
        return TimelineView(.periodic(from: .now, by: player.playing ? 0.5 : 60)) { _ in
            ZStack(alignment: .topLeading) {
                Image(nsImage: ShellArt.lcd).resizable()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        clock
                        Spacer()
                        DotSpectrum(live: player.playing && t?.source != .spotify, cols: 8, rows: 6, dot: 6.2, gap: 1.6)
                            .padding(.top, 3)
                    }
                    .frame(height: 30)
                    HStack(spacing: 4) {
                        Text(t == nil ? "TRK ---/---" : "TRK \(player.index + 1)/\(player.queue.count)").font(W.dot(8.5)).tracking(1.3)
                            .foregroundStyle(W.lilac.opacity(0.6))
                        Spacer(minLength: 2)
                        ForEach([t.map { WidgetSnapshot(source: $0.source.rawValue).sourceBadge } ?? "", snap.format,
                                 player.shuffle ? "SHUF" : "", "VOL \(Int((SystemVolume.value * 100).rounded()))"].filter { !$0.isEmpty }, id: \.self) { b in
                            Text(b).font(W.dot(7.5)).tracking(0.8).foregroundStyle(W.lilac).lineLimit(1)
                                .padding(.horizontal, 4).padding(.vertical, 0.5)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(W.lilac.opacity(0.55), lineWidth: 0.8))
                        }
                    }
                    .padding(.top, 6)
                    Rectangle().fill(W.lilac.opacity(0.16)).frame(height: 0.8).padding(.top, 4)
                    Text(t?.title ?? "Nothing playing").font(W.ui(14.5, .bold)).foregroundStyle(W.text).lineLimit(1)
                        .shadow(color: W.lilac.opacity(0.5), radius: 3).padding(.top, 5)
                    Text(t?.artist ?? "Press play to pick up where you left off").font(W.ui(11.5, .medium)).foregroundStyle(W.text2).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.top, 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { WidgetBridge.shared.run(.open) }
            .help("Open WreckBox Player")
        }
    }

    /// Peach Doto digits over faint "88:88" segments, the state mark before them.
    private var clock: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: player.current == nil ? "stop.fill" : player.playing ? "play.fill" : "pause.fill")
                .font(.system(size: 8, weight: .heavy)).foregroundStyle(W.peach.opacity(0.9))
            LcdText(text: timeLabel(player.position), ghost: "88:88", size: 22)
        }
    }

    private var seekBar: some View {
        GeometryReader { g in
            TimelineView(.periodic(from: .now, by: player.playing ? 1 : 60)) { _ in
                let f = player.duration > 0 ? min(1, player.position / player.duration) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.6))
                    Capsule().fill(LinearGradient(colors: W.smartColors, startPoint: .leading, endPoint: .trailing)).frame(width: max(4, g.size.width * f))
                        .shadow(color: W.peach.opacity(0.6), radius: 3)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                player.seek(max(0, min(1, v.location.x / g.size.width)) * player.duration)
            })
        }
    }

    // MARK: dial

    private var dial: some View {
        let mid = (36 + 55) / 2.0
        return ZStack {
            Image(nsImage: ShellArt.dial).resizable()
            key("plus", "Volume up") { WidgetBridge.shared.run(.volUp) }.offset(y: -mid)
            key("minus", "Volume down") { WidgetBridge.shared.run(.volDown) }.offset(y: mid)
            key("backward.end.fill", "Previous (restarts the song if more than 3 s in)") { player.previous() }.offset(x: -mid)
            key("forward.end.fill", "Next") { player.next() }.offset(x: mid)
            CandyButton(size: 60, playing: player.playing) { player.toggle() }
        }
    }

    private func key(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 9, weight: .heavy)).foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black, radius: 0.6, y: 0.8)
                .frame(width: 30, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: tabs + drawers

    private var tabsRow: some View {
        HStack(spacing: Geo.tabGap) {
            ForEach(Array(["Equaliser", "Queue", "Options"].enumerated()), id: \.offset) { i, name in
                let open = model.drawer?.rawValue == i
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { model.drawer = open ? nil : DesktopWidgetModel.Drawer(rawValue: i) }
                } label: {
                    Text(name.uppercased()).font(W.dot(8.5)).tracking(1.2).foregroundStyle(open ? W.peach : W.text2)
                        .frame(width: Geo.tabs[i], height: 24)
                        .background(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                            .fill(open ? Geo.drawerColor : Color(hex: 0x1D1A25)))
                        .overlay(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                            .strokeBorder(open ? W.lilac.opacity(0.0) : .white.opacity(0.12), lineWidth: 0.8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func drawer(_ d: DesktopWidgetModel.Drawer) -> some View {
        ZStack(alignment: .topLeading) {
            Image(nsImage: ShellArt.drawer).resizable()
            Group {
                switch d {
                case .eq: eqDrawer
                case .queue: queueDrawer
                case .options: optionsDrawer
                }
            }
            .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 16)
        }
    }

    private var eqDrawer: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    DotLabel("Equaliser", color: W.text3, size: 8.5)
                    Spacer()
                    Text(player.current?.source == .spotify ? "Spotify plays flat" : eq.on ? eq.preset : "Off")
                        .font(W.ui(10.5, .semibold)).foregroundStyle(eq.on ? W.lilac : W.text3)
                }
                EqDots(gains: eq.gains, on: eq.on) { i, db in eq.setBand(i, db) }
                HStack(spacing: 0) { ForEach(EQ.labels, id: \.self) { Text($0).font(W.dot(6)).foregroundStyle(W.text3).frame(maxWidth: .infinity) } }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: 0x120F1A), Color(hex: 0x07060A)], startPoint: .top, endPoint: .bottom)))
            .frame(width: 206)
            VStack(alignment: .leading, spacing: 5) {
                led(eq.on ? "On" : "Off", lit: eq.on, width: 144) { eq.setOn(!eq.on) }
                let names = ["Flat", "Bass", "Club", "Hip-hop", "Electro", "Vocal", "Treble", "Loud"]
                LazyVGrid(columns: [GridItem(.fixed(70), spacing: 4), GridItem(.fixed(70))], spacing: 4) {
                    ForEach(Array(EQ.presets.enumerated()), id: \.offset) { i, p in
                        led(names[i], lit: eq.on && eq.preset == p.0, width: 70) { eq.choose(p.0) }
                    }
                }
            }
        }
    }

    private var queueDrawer: some View {
        VStack(alignment: .leading, spacing: 3) {
            DotLabel("Up next", color: W.text3, size: 8.5).padding(.bottom, 4)
            let up = Array(player.queue.enumerated().dropFirst(player.index + 1).prefix(5))
            if up.isEmpty { Text("Nothing up next").font(W.ui(11.5)).foregroundStyle(W.text3) }
            ForEach(up, id: \.offset) { i, t in
                Button { player.jump(to: i) } label: {
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", i + 1)).font(W.dot(10)).foregroundStyle(W.lilac).frame(width: 20, alignment: .leading)
                        Text(t.title).font(W.ui(12, .semibold)).foregroundStyle(W.text).lineLimit(1)
                        Text(t.artist).font(W.ui(11)).foregroundStyle(W.text3).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var optionsDrawer: some View {
        let liked = player.current.map(library.isLiked) ?? false
        return VStack(alignment: .leading, spacing: 8) {
            DotLabel("Options", color: W.text3, size: 8.5)
            Text(player.quality ?? (player.current?.source == .spotify ? "Spotify stream" : "—")).font(W.dot(10)).foregroundStyle(W.peach)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                led("−10 s", lit: false, width: 84) { player.skip(-10) }
                led("+10 s", lit: false, width: 84) { player.skip(10) }
                led("Shuffle", lit: player.shuffle, width: 84) { player.setShuffle(!player.shuffle) }
                led(player.repeatMode == .one ? "Repeat 1" : "Repeat", lit: player.repeatMode != .off, width: 84) { player.cycleRepeat() }
                led(liked ? "♥ Liked" : "♡ Like", lit: liked, width: 84) { if let t = player.current { library.toggleLike(t) } }
                led("Open app", lit: false, width: 84) { WidgetBridge.shared.run(.open) }
            }
        }
    }

    /// An LED key: a small dark key with a light that glows when on.
    private func led(_ label: String, lit: Bool, width: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(lit ? W.peach : .white.opacity(0.14)).frame(width: 5, height: 5).shadow(color: lit ? W.peach : .clear, radius: 3)
                Text(label).font(W.ui(10.5, .semibold)).foregroundStyle(lit ? W.text : W.text2).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(width: width, height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(LinearGradient(colors: [Color(hex: 0x2C2837), Color(hex: 0x16141C)], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(lit ? 0.22 : 0.1), lineWidth: 0.8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The casing, drawn once

/// The shell, LCD glass, dial and drawer tray: drawn once (they don't change) as images at 2× and reused.
@MainActor
enum ShellArt {
    static let body = render(Geo.width, Geo.bodyH) { ctx in
        shell(ctx, Geo.width, Geo.bodyH, bodyOutline(), base: nil)
        // The pod: a raised round plate under the dial, screwed down at the diagonals.
        plateCircle(ctx, Geo.dialCX, Geo.dialCY, Geo.podR - 7)
        for a in [45.0, 135, 225, 315] {
            screw(ctx, Geo.dialCX + (Geo.podR - 12) * cos(a * .pi / 180), Geo.dialCY + (Geo.podR - 12) * sin(a * .pi / 180))
        }
        bed(ctx, CGRect(x: Geo.G, y: Geo.top, width: Geo.width - Geo.lcdRight - Geo.G, height: Geo.lcdH), 12)
        bed(ctx, CGRect(x: Geo.G, y: Geo.seekT, width: Geo.width - Geo.lcdRight - Geo.G, height: Geo.seekH), 3)
        screw(ctx, 11, Geo.slabB - 11)
    }

    static let drawer = render(Geo.width, Geo.drawerH) { ctx in
        shell(ctx, Geo.width, Geo.drawerH, drawerOutline(Geo.width, Geo.drawerH), base: Geo.drawerColor)
        screw(ctx, 11, Geo.drawerH - 11)
        screw(ctx, Geo.width - 11, Geo.drawerH - 11)
    }

    /// Deep violet glass with Sonique's ripple rings (in lilac), ghost dots, scanlines and a glare.
    static let lcd = render(Geo.width - Geo.lcdRight - Geo.G, Geo.lcdH) { ctx in
        let w = Geo.width - Geo.lcdRight - Geo.G, h = Geo.lcdH
        let shape = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 12)
        ctx.clip(to: shape)
        ctx.fill(shape, with: .radialGradient(Gradient(colors: [Color(hex: 0x2A1F3D), Color(hex: 0x07060B)]), center: CGPoint(x: w * 0.88, y: h * 1.1), startRadius: 0, endRadius: w))
        for i in 1...26 {
            let r = CGFloat(i) * 8
            ctx.stroke(Path(ellipseIn: CGRect(x: w * 0.88 - r, y: h * 1.1 - r, width: 2 * r, height: 2 * r)),
                       with: .color(W.lilac.opacity(Double(max(6, 46 - i * 2)) / 255)), lineWidth: 2.2)
        }
        var y: CGFloat = 3
        while y < h { var x: CGFloat = 3; while x < w { ctx.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(.white.opacity(9 / 255))); x += 3.4 }; y += 3.4 }
        y = 0
        while y < h { ctx.fill(Path(CGRect(x: 0, y: y, width: w, height: 0.7)), with: .color(.black.opacity(0.1))); y += 2 }
        var glare = Path()
        glare.move(to: CGPoint(x: w * 0.52, y: 0)); glare.addLine(to: CGPoint(x: w * 0.76, y: 0))
        glare.addLine(to: CGPoint(x: w * 0.46, y: h)); glare.addLine(to: CGPoint(x: w * 0.22, y: h)); glare.closeSubpath()
        ctx.fill(glare, with: .linearGradient(Gradient(colors: [.white.opacity(20 / 255), .white.opacity(2 / 255)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        ctx.stroke(Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1), cornerRadius: 12), with: .color(W.lilac.opacity(60 / 255)), lineWidth: 1)
    }

    /// A graphite jog ring with the iridescent rim, four glossy raised keys and a well for the candy button.
    static let dial = render(Geo.dial, Geo.dial) { ctx in
        let d = Geo.dial, c = d / 2, outer = d / 2 - 1.5
        let ring = Path(ellipseIn: CGRect(x: c - outer, y: c - outer, width: 2 * outer, height: 2 * outer))
        ctx.fill(ring, with: .radialGradient(Gradient(colors: [Color(hex: 0x4A4558), Color(hex: 0x100E15)]), center: CGPoint(x: c - 20, y: c - 24), startRadius: 0, endRadius: outer * 1.5))
        ctx.stroke(Path(ellipseIn: CGRect(x: c - outer + 2, y: c - outer + 2, width: 2 * outer - 4, height: 2 * outer - 4)),
                   with: .linearGradient(Gradient(colors: [.white.opacity(90 / 255), .black.opacity(130 / 255)]), startPoint: .zero, endPoint: CGPoint(x: d, y: d)), lineWidth: 3.5)
        ctx.stroke(ring, with: .conicGradient(Gradient(colors: [W.blue, W.peach, W.lilac, W.blue]), center: CGPoint(x: c, y: c)), lineWidth: 1.6)
        let rIn: CGFloat = 36, rOut: CGFloat = 55
        for k in 0..<4 {
            let start = -90.0 + Double(k) * 90 - 42
            var p = Path()
            p.addArc(center: CGPoint(x: c, y: c), radius: rOut, startAngle: .degrees(start), endAngle: .degrees(start + 84), clockwise: false)
            p.addArc(center: CGPoint(x: c, y: c), radius: rIn, startAngle: .degrees(start + 84), endAngle: .degrees(start), clockwise: true)
            p.closeSubpath()
            ctx.fill(p.offsetBy(dx: 0.8, dy: 1.6), with: .color(.black.opacity(150 / 255)))
            ctx.fill(p, with: .linearGradient(Gradient(colors: [Color(hex: 0x3D3949), Color(hex: 0x1A1822)]), startPoint: .zero, endPoint: CGPoint(x: d, y: d)))
            var gloss = ctx
            gloss.clip(to: p)
            gloss.fill(Path(ellipseIn: CGRect(x: c - 14 - rOut, y: c - 18 - rOut, width: 2 * rOut, height: 2 * rOut)),
                       with: .radialGradient(Gradient(colors: [.white.opacity(60 / 255), .clear]), center: CGPoint(x: c - 14, y: c - 18), startRadius: 0, endRadius: rOut))
            ctx.stroke(p, with: .color(.white.opacity(70 / 255)), lineWidth: 0.8)
        }
        let mid = (rIn + rOut) / 2
        for (txt, yy) in [("VOL", c - mid + 9.5), ("VOL", c + mid - 9.5)] {
            ctx.draw(Text(txt).font(W.dot(5.5)).foregroundColor(W.lilac.opacity(0.67)), at: CGPoint(x: c, y: yy))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: c - 33, y: c - 33, width: 66, height: 66)), with: .color(Color(hex: 0x07060A)))
        ctx.stroke(Path(ellipseIn: CGRect(x: c - 33, y: c - 33, width: 66, height: 66)),
                   with: .linearGradient(Gradient(colors: [.black.opacity(0.55), .white.opacity(0.24)]), startPoint: CGPoint(x: 0, y: c - 33), endPoint: CGPoint(x: 0, y: c + 33)), lineWidth: 1)
    }

    private static func render(_ w: CGFloat, _ h: CGFloat, _ draw: @escaping (inout GraphicsContext) -> Void) -> NSImage {
        let r = ImageRenderer(content: Canvas { ctx, _ in var c = ctx; draw(&c) }.frame(width: w, height: h))
        r.scale = 2
        return r.nsImage ?? NSImage(size: NSSize(width: w, height: h))
    }

    /// A small seeded random generator, so the flecks are the same every time.
    private struct Rnd { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    /// The casing: violet graphite with granite flecks, faint swirls, a sheen and specular line on top, a bevel and
    /// the iridescent rim.
    private static func shell(_ ctx: GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ path: Path, base: Color?) {
        if let base {
            ctx.fill(path, with: .linearGradient(Gradient(colors: [base, Color(hex: 0x0E0D13)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        } else {
            ctx.fill(path, with: .linearGradient(Gradient(stops: [.init(color: Color(hex: 0x34303F), location: 0), .init(color: Color(hex: 0x1F1C27), location: 0.55),
                                                                  .init(color: Color(hex: 0x1C1A23), location: 1)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
        }
        var c = ctx
        c.clip(to: path)
        var rnd = Rnd(s: base == nil ? 7 : 31)
        for _ in 0..<Int(w * h / 7) {
            let white = rnd.next() < 0.5
            let a = white ? (10 + rnd.next() * 24) / 255 : (30 + rnd.next() * 50) / 255
            let x = rnd.next() * w, y = rnd.next() * h, r = rnd.next() * 0.75 + 0.2
            c.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(white ? .white.opacity(a) : .black.opacity(a)))
        }
        for i in 0..<16 {
            let r = 70 + CGFloat(i) * 12
            c.stroke(Path(ellipseIn: CGRect(x: w * 0.2 - r, y: h + 60 - r, width: 2 * r, height: 2 * r)), with: .color(W.lilac.opacity(14 / 255)), lineWidth: 0.6)
        }
        c.fill(Path(CGRect(x: 0, y: 0, width: w, height: h * 0.4)), with: .linearGradient(Gradient(colors: [.white.opacity(26 / 255), .clear]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h * 0.4)))
        c.fill(Path(roundedRect: CGRect(x: Geo.R, y: 2.4, width: w - 2 * Geo.R, height: 1), cornerRadius: 0.5),
               with: .linearGradient(Gradient(colors: [.clear, .white.opacity(90 / 255), .clear]), startPoint: CGPoint(x: Geo.R, y: 0), endPoint: CGPoint(x: w - Geo.R, y: 0)))
        c.stroke(path, with: .linearGradient(Gradient(colors: [.white.opacity(70 / 255), .black.opacity(110 / 255)]), startPoint: .zero, endPoint: CGPoint(x: w * 0.4, y: h)), lineWidth: 4.5)
        ctx.stroke(path, with: .linearGradient(Gradient(colors: W.smartColors.map { $0.opacity(200 / 255) }), startPoint: .zero, endPoint: CGPoint(x: w, y: 0)), lineWidth: 1.6)
    }

    private static func screw(_ ctx: GraphicsContext, _ x: CGFloat, _ y: CGFloat) {
        let r = CGRect(x: x - 3.8, y: y - 3.8, width: 7.6, height: 7.6)
        ctx.fill(Path(ellipseIn: r), with: .radialGradient(Gradient(colors: [Color(hex: 0xB5B1BF), Color(hex: 0x2A2733)]), center: CGPoint(x: x - 1.3, y: y - 1.3), startRadius: 0, endRadius: 4.6))
        ctx.stroke(Path(ellipseIn: r), with: .color(.black), lineWidth: 0.6)
        var slot = Path()
        slot.move(to: CGPoint(x: x - 2.3, y: y + 1)); slot.addLine(to: CGPoint(x: x + 2.3, y: y - 1))
        ctx.stroke(slot, with: .color(Color(hex: 0x141218)), lineWidth: 1)
    }

    private static func plateCircle(_ ctx: GraphicsContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
        let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
        ctx.fill(Path(ellipseIn: rect.offsetBy(dx: 1.5, dy: 3)), with: .color(.black.opacity(150 / 255)))
        let p = Path(ellipseIn: rect)
        ctx.fill(p, with: .linearGradient(Gradient(colors: [Color(hex: 0x3E3A4B), Color(hex: 0x15131B)]), startPoint: CGPoint(x: 0, y: cy - r), endPoint: CGPoint(x: 0, y: cy + r)))
        var c = ctx
        c.clip(to: p)
        var rnd = Rnd(s: 11)
        for _ in 0..<Int(r * r * 4 / 7) {
            let white = rnd.next() < 0.5
            let a = white ? (10 + rnd.next() * 24) / 255 : (30 + rnd.next() * 50) / 255
            let x = cx - r + rnd.next() * 2 * r, y = cy - r + rnd.next() * 2 * r, s = rnd.next() * 0.75 + 0.2
            c.fill(Path(ellipseIn: CGRect(x: x - s, y: y - s, width: 2 * s, height: 2 * s)), with: .color(white ? .white.opacity(a) : .black.opacity(a)))
        }
        c.stroke(p, with: .linearGradient(Gradient(colors: [.white.opacity(90 / 255), .black.opacity(130 / 255)]), startPoint: CGPoint(x: cx - r, y: cy - r), endPoint: CGPoint(x: cx + r, y: cy + r)), lineWidth: 4)
        ctx.stroke(p, with: .color(.black), lineWidth: 0.8)
    }

    private static func bed(_ ctx: GraphicsContext, _ r: CGRect, _ radius: CGFloat) {
        ctx.fill(Path(roundedRect: r.insetBy(dx: -2, dy: -2), cornerRadius: radius + 2),
                 with: .linearGradient(Gradient(colors: [Color(hex: 0x020203), .white.opacity(0.2)]), startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
    }

    /// One smooth shape: the logo bump flowing into the slab through an S-curve, the slab filleted into the round pod,
    /// the pod swelling past the slab top and bottom.
    private static func bodyOutline() -> Path {
        let l: CGFloat = 1.5, t = Geo.slabT, bt = Geo.slabB
        let cx = Geo.dialCX, cy = Geo.dialCY, r = Geo.podR
        let xt = cx - sqrt(r * r - (cy - t) * (cy - t)), xb = cx - sqrt(r * r - (bt - cy) * (bt - cy))
        let bumpEnd = min(186, xt - 28), bumpStart = bumpEnd - 36
        let aTop = atan2(t - cy, xt - cx) * 180 / .pi + 12, aBot = atan2(bt - cy, xb - cx) * 180 / .pi - 12
        func on(_ a: Double) -> CGPoint { CGPoint(x: cx + r * cos(a * .pi / 180), y: cy + r * sin(a * .pi / 180)) }
        let p1 = on(aTop), p2 = on(aBot)
        let t1 = CGPoint(x: -sin(aTop * .pi / 180), y: cos(aTop * .pi / 180)), t2 = CGPoint(x: -sin(aBot * .pi / 180), y: cos(aBot * .pi / 180))
        let r1: CGFloat = 18, r2: CGFloat = 24
        var p = Path()
        p.move(to: CGPoint(x: l + r1, y: 4))
        p.addLine(to: CGPoint(x: bumpStart, y: 4))
        p.addCurve(to: CGPoint(x: bumpEnd, y: t), control1: CGPoint(x: bumpStart + 20, y: 4), control2: CGPoint(x: bumpEnd - 20, y: t))
        p.addLine(to: CGPoint(x: xt - 20, y: t))
        p.addCurve(to: p1, control1: CGPoint(x: xt - 6, y: t), control2: CGPoint(x: p1.x - t1.x * 12, y: p1.y - t1.y * 12))
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(aTop), endAngle: .degrees(aBot), clockwise: false)
        p.addCurve(to: CGPoint(x: xb - 20, y: bt), control1: CGPoint(x: p2.x + t2.x * 12, y: p2.y + t2.y * 12), control2: CGPoint(x: xb - 6, y: bt))
        p.addLine(to: CGPoint(x: l + r2, y: bt))
        p.addQuadCurve(to: CGPoint(x: l, y: bt - r2), control: CGPoint(x: l, y: bt))
        p.addLine(to: CGPoint(x: l, y: 4 + r1))
        p.addQuadCurve(to: CGPoint(x: l + r1, y: 4), control: CGPoint(x: l, y: 4))
        p.closeSubpath()
        return p
    }

    /// A tray whose top steps down past the tabs with an S-curve (the tabs plug into it).
    private static func drawerOutline(_ w: CGFloat, _ h: CGFloat) -> Path {
        let l: CGFloat = 1.5, drop: CGFloat = 12, r: CGFloat = 26, te = Geo.tabsEnd
        var p = Path()
        p.move(to: CGPoint(x: l, y: 12))
        p.addQuadCurve(to: CGPoint(x: l + 12, y: 0), control: CGPoint(x: l, y: 0))
        p.addLine(to: CGPoint(x: te + 10, y: 0))
        p.addCurve(to: CGPoint(x: te + 42, y: drop), control1: CGPoint(x: te + 26, y: 0), control2: CGPoint(x: te + 26, y: drop))
        p.addLine(to: CGPoint(x: w - l - 18, y: drop))
        p.addQuadCurve(to: CGPoint(x: w - l, y: drop + 18), control: CGPoint(x: w - l, y: drop))
        p.addLine(to: CGPoint(x: w - l, y: h - l - r))
        p.addQuadCurve(to: CGPoint(x: w - l - r, y: h - l), control: CGPoint(x: w - l, y: h - l))
        p.addLine(to: CGPoint(x: l + r, y: h - l))
        p.addQuadCurve(to: CGPoint(x: l, y: h - l - r), control: CGPoint(x: l, y: h - l))
        p.closeSubpath()
        return p
    }
}
