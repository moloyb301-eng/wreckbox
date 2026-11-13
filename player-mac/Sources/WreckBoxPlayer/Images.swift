import AppKit
import AVFoundation
import AudioToolbox

/// Covers: a file's embedded artwork ("file:<path>") or a web image (YouTube / Spotify), decoded at the size asked
/// for and kept in a small memory cache.
actor Images {
    static let shared = Images()
    private let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 48 << 20; return c }()

    func load(_ art: String?, size: CGFloat) async -> NSImage? {
        guard let art, !art.isEmpty else { return nil }
        let px = size <= 64 ? 128 : size <= 160 ? 320 : 768
        let key = "\(art)#\(px)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var data: Data?
        if art.hasPrefix("file:") {
            data = await Self.embedded(String(art.dropFirst(5)))
        } else if let url = URL(string: Self.sized(art, px)) {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data, let img = Self.downscale(data, px) else { return nil }
        cache.setObject(img, forKey: key, cost: px * px * 4)
        return img
    }

    /// The JPEG/PNG for the widget (raw bytes, ~600 px).
    func data(_ art: String?) async -> Data? {
        guard let img = await load(art, size: 300), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// YouTube covers come in any size (=wN-hN).
    private static func sized(_ url: String, _ px: Int) -> String {
        url.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w\(px)-h\(px)", options: .regularExpression)
    }

    private static func embedded(_ path: String) async -> Data? {
        // Core Audio reads the picture of every format it plays (FLAC's PICTURE block, ID3 APIC, MP4 covr).
        var fileID: AudioFileID?
        if AudioFileOpenURL(URL(fileURLWithPath: path) as CFURL, .readPermission, 0, &fileID) == noErr, let f = fileID {
            defer { AudioFileClose(f) }
            var art: Unmanaged<CFData>?
            var size = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
            if AudioFileGetProperty(f, kAudioFilePropertyAlbumArtwork, &size, &art) == noErr, let d = art?.takeRetainedValue() { return d as Data }
        }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let meta = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierArtwork) {
            if let d = try? await item.load(.dataValue) { return d }
        }
        // Next to the file: cover.jpg / folder.jpg.
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        for name in ["cover.jpg", "folder.jpg", "cover.png", "Cover.jpg", "Folder.jpg"] {
            if let d = try? Data(contentsOf: dir.appendingPathComponent(name)) { return d }
        }
        return nil
    }

    private static func downscale(_ data: Data, _ px: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: px,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
