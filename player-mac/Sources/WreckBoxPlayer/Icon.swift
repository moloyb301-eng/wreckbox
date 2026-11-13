import AppKit
import SwiftUI

/// `WreckBoxPlayer make-icon <dir.iconset>`: the app icon — the pixel record on its beige tile, at every macOS size.
@MainActor
enum IconMaker {
    static func run(_ out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = CGFloat(base * scale)
                let view = PixelRecord(size: px * 0.82)
                    .shadow(color: .black.opacity(0.4), radius: px * 0.03, y: px * 0.015)
                    .frame(width: px, height: px)
                let r = ImageRenderer(content: view)
                r.scale = 1
                guard let cg = r.cgImage else { continue }
                let name = "icon_\(base)x\(base)" + (scale == 2 ? "@2x" : "") + ".png"
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name))
            }
        }
    }
}
