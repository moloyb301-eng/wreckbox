import SwiftUI

// The Y2K pieces as vector shapes. A widget extension gets ~30 MB, and every picture (the old ShellArt PNGs) or
// Canvas / shadow is a bitmap the renderer decodes or draws offscreen at 3×, all again on every reload (each button
// press) — that ran it out of memory and the tile went blank. Shapes cost next to nothing: many sub-paths are put
// into one Shape so each piece is a single draw.

private let Q = { (x: CGFloat, y: CGFloat) in CGPoint(x: x, y: y) }

// MARK: - Casing

/// The tile: violet graphite, a sheen on top, faint swirls, the bevel and the iridescent rim.
struct CasingView: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: [.init(color: Color(hex: 0x34303F), location: 0), .init(color: Color(hex: 0x1F1C27), location: 0.55),
                                   .init(color: Color(hex: 0x1C1A23), location: 1)], startPoint: .top, endPoint: .bottom)
            Rings(cx: 0.2, cy: 1.15, from: 70, step: 12, count: 16).stroke(Y2K.lilac.opacity(14 / 255), lineWidth: 0.6)
            LinearGradient(colors: [.white.opacity(26 / 255), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4))
            ContainerRelativeShape().inset(by: 1.5)
                .strokeBorder(LinearGradient(colors: [.white.opacity(70 / 255), .black.opacity(110 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 4.5)
            ContainerRelativeShape()
                .strokeBorder(LinearGradient(colors: Y2K.smartColors.map { $0.opacity(200 / 255) }, startPoint: .leading, endPoint: .trailing), lineWidth: 1.8)
        }
    }
}

/// Concentric circles round a point given as a fraction of the rect (one shape).
struct Rings: Shape {
    let cx: CGFloat, cy: CGFloat
    let from: CGFloat, step: CGFloat
    let count: Int
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = Q(r.minX + r.width * cx, r.minY + r.height * cy)
        for i in 0..<count {
            let rad = from + CGFloat(i) * step
            p.addEllipse(in: CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad))
        }
        return p
    }
}

// MARK: - LCD glass

/// Deep violet glass with lilac ripple rings, a glare and a thin rim, its corners concentric with the tile (the old
/// picture's dot grid and scanlines were thousands of paths; left out).
struct LcdGlass: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x2A1F3D), Color(hex: 0x07060B)], center: UnitPoint(x: 0.88, y: 1.1), startRadius: 0, endRadius: 230)
            Rings(cx: 0.88, cy: 1.1, from: 8, step: 8, count: 10).stroke(Y2K.lilac.opacity(36 / 255), lineWidth: 2.2)
            Rings(cx: 0.88, cy: 1.1, from: 88, step: 8, count: 16).stroke(Y2K.lilac.opacity(12 / 255), lineWidth: 2.2)
            Glare().fill(LinearGradient(colors: [.white.opacity(20 / 255), .white.opacity(2 / 255)], startPoint: .top, endPoint: .bottom))
            ContainerRelativeShape().strokeBorder(Y2K.lilac.opacity(60 / 255), lineWidth: 1)
        }
        .clipShape(ContainerRelativeShape())
    }

    private struct Glare: Shape {
        func path(in r: CGRect) -> Path {
            let w = r.width, h = r.height
            var p = Path()
            p.move(to: Q(w * 0.52, 0)); p.addLine(to: Q(w * 0.76, 0)); p.addLine(to: Q(w * 0.46, h)); p.addLine(to: Q(w * 0.22, h)); p.closeSubpath()
            return p
        }
    }
}

// MARK: - The record and glyphs

/// The WreckBox record (the app's pixel record, as rings): grooves, peach and lilac label, the hole; on its beige
/// tile if `tile`.
struct Disc: View {
    let size: CGFloat
    var tile = false
    var body: some View {
        let inner = tile ? size * 0.78 : size
        ZStack {
            if tile {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xF1ECE4), Color(hex: 0xDCD5CA)], startPoint: .top, endPoint: .bottom))
            }
            Circle().fill(Color(hex: 0x34343E)).frame(width: inner, height: inner)
            Circle().fill(Color(hex: 0x15151A)).frame(width: inner * 14.6 / 15.6, height: inner * 14.6 / 15.6)
            Rings(cx: 0.5, cy: 0.5, from: inner * 7.5 / 31.2, step: inner * 3.4 / 31.2, count: 3).stroke(Color(hex: 0x2A2A33), lineWidth: max(0.5, inner / 32))
                .frame(width: inner, height: inner)
            Circle().fill(Y2K.peach).frame(width: inner * 5.6 / 15.6, height: inner * 5.6 / 15.6)
            Circle().fill(Y2K.lilac).frame(width: inner * 3.6 / 15.6, height: inner * 3.6 / 15.6)
            Circle().fill(Color(hex: 0x050506)).frame(width: inner * 1.6 / 15.6, height: inner * 1.6 / 15.6)
        }
        .frame(width: size, height: size)
    }
}

/// Play (a triangle on Material's 24 grid) or pause (two bars).
struct PlayPauseGlyph: Shape {
    let playing: Bool
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        if playing {
            p.addRoundedRect(in: CGRect(x: w * 0.22, y: h * 0.18, width: w * 0.2, height: h * 0.64), cornerSize: CGSize(width: 1, height: 1))
            p.addRoundedRect(in: CGRect(x: w * 0.58, y: h * 0.18, width: w * 0.2, height: h * 0.64), cornerSize: CGSize(width: 1, height: 1))
        } else {
            p.move(to: Q(w * 8 / 24, h * 5 / 24)); p.addLine(to: Q(w * 8 / 24, h * 19 / 24)); p.addLine(to: Q(w * 19 / 24, h * 12 / 24)); p.closeSubpath()
        }
        return p
    }
}

/// ▶ playing (2), ❚❚ paused (1), ■ stopped (0).
struct StateMark: Shape {
    let state: Int
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        switch state {
        case 2: p.move(to: .zero); p.addLine(to: Q(w, h / 2)); p.addLine(to: Q(0, h)); p.closeSubpath()
        case 1: p.addRect(CGRect(x: 0, y: 0, width: w * 0.34, height: h)); p.addRect(CGRect(x: w * 0.66, y: 0, width: w * 0.34, height: h))
        default: p.addRect(CGRect(x: 0, y: h * 0.1, width: w, height: h * 0.8))
        }
        return p
    }
}

/// Dots of a grid (cols × rows, filling the rect) for which `lit(col, row)` holds — row 0 at the top. One shape per
/// colour keeps a dot display at a handful of draws.
struct DotGrid: Shape {
    let cols: Int, rows: Int
    var gap: CGFloat = 1.6
    var dotH: CGFloat?           // nil: fill the row
    var radius: CGFloat = 0.9
    let lit: (Int, Int) -> Bool

    func path(in r: CGRect) -> Path {
        let dw = (r.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
        let rowH = (r.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
        let dh = dotH ?? rowH
        var p = Path()
        for c in 0..<cols { for row in 0..<rows where lit(c, row) {
            let y = r.minY + CGFloat(row) * (rowH + gap) + (rowH - dh) / 2
            p.addRoundedRect(in: CGRect(x: r.minX + CGFloat(c) * (dw + gap), y: y, width: dw, height: dh), cornerSize: CGSize(width: radius, height: radius))
        } }
        return p
    }
}
