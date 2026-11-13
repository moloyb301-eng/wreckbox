import AVFoundation
import AudioToolbox
import Foundation

/// The music on this Mac: audio files under the chosen folders (~/Music — including WreckBox's DJ Library/Tracks —
/// and ~/Downloads by default). Music only: no voice memos, GarageBand / Logic projects, ringtones, podcasts,
/// audiobooks, chat audio, or anything under a minute. Tags are read once and kept in local-index.json (re-read when
/// a file changes).
@MainActor
final class LocalMusic: ObservableObject {
    static let shared = LocalMusic()

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var scanning = false

    private struct Entry: Codable { var track: Track?; var size: Int64; var modified: Date; var quality: String? }
    private var index: [String: Entry] = [:]

    nonisolated static let audioExts: Set<String> = ["flac", "mp3", "m4a", "aac", "alac", "wav", "aif", "aiff", "opus", "ogg", "oga", "ec3", "caf"]
    /// Folders that hold recordings, projects, system sounds or downloads in progress — not music.
    nonisolated private static let skipDirs = ["garageband", "logic", "voice memos", "audio music apps", "ringtones", "podcasts", "audiobooks",
                                   "recordings", "whatsapp", "telegram", "signal", "imovie", "final cut", "sound effects", ".trash"]
    nonisolated private static let notMusicName = try! NSRegularExpression(
        pattern: #"^(aud|ptt)-\d{8}-wa\d+.*|^(recording|voice|call|rec|new recording)[ _-]*(\(\d+\)|\d+)?\S*$|^\d{6,}$"#, options: .caseInsensitive)

    private init() {
        if let saved = AppDirs.load([String: Entry].self, "local-index-2.json") {
            index = saved
            tracks = Self.sorted(saved.values.compactMap(\.track))
            for (_, e) in saved { if let t = e.track, let q = e.quality { Quality.put(t, q) } }
        }
    }

    /// Looks through the folders again: new and changed files are read, gone ones dropped.
    func rescan() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        let folders = Prefs.musicFolders
        let found = await Task.detached(priority: .utility) { Self.files(in: folders) }.value
        var next: [String: Entry] = [:]
        var toRead: [(String, Int64, Date)] = []
        for (path, size, mod) in found {
            if let e = index[path], e.size == size, e.modified == mod { next[path] = e } else { toRead.append((path, size, mod)) }
        }
        // Read tags eight at a time.
        await withTaskGroup(of: (String, Entry).self) { group in
            var it = toRead.makeIterator()
            func add() -> Bool {
                guard let (p, s, m) = it.next() else { return false }
                group.addTask { (p, await Self.read(path: p, size: s, modified: m)) }
                return true
            }
            for _ in 0..<8 where add() {}
            for await (p, e) in group {
                next[p] = e
                _ = add()
            }
        }
        index = next
        for (_, e) in next { if let t = e.track, let q = e.quality { Quality.put(t, q) } }
        tracks = Self.sorted(next.values.compactMap(\.track))
        AppDirs.save(next, "local-index-2.json")
    }

    func search(_ q: String) -> [Track] {
        let words = Search.norm(q).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return tracks.filter { t in
            let s = Search.norm("\(t.title) \(t.artist) \(t.album ?? "")")
            return words.allSatisfy { s.contains($0) }
        }
    }

    private static func sorted(_ t: [Track]) -> [Track] {
        t.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    nonisolated private static func files(in folders: [String]) -> [(String, Int64, Date)] {
        var out: [(String, Int64, Date)] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey]
        for folder in folders {
            guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                let v = try? url.resourceValues(forKeys: Set(keys))
                let name = url.lastPathComponent.lowercased()
                if v?.isDirectory == true {
                    // Projects (.band, .logicx) are packages; WreckBox's staging folders start with "_".
                    if v?.isPackage == true || name.hasPrefix("_") || skipDirs.contains(where: { name.contains($0) }) { en.skipDescendants() }
                    continue
                }
                guard audioExts.contains(url.pathExtension.lowercased()) else { continue }
                let stem = url.deletingPathExtension().lastPathComponent
                if notMusicName.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)) != nil { continue }
                let path = url.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted else { continue }
                out.append((path, Int64(v?.fileSize ?? 0), v?.contentModificationDate ?? .distantPast))
            }
        }
        return out
    }

    nonisolated private static func read(path: String, size: Int64, modified: Date) async -> Entry {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        var title = "", artist = "", album: String?
        var seconds = 0.0
        if let (meta, dur) = try? await asset.load(.metadata, .duration) {
            seconds = dur.seconds.isFinite ? dur.seconds : 0
            // FLAC / Ogg come back as Vorbis comments ("vorb/TITLE") with no common keys; MP3 / M4A have both.
            var artists: [String] = []
            for item in meta {
                let raw = (item.key as? String)?.uppercased() ?? ""
                let field: String
                switch item.commonKey {
                case .commonKeyTitle?: field = "TITLE"
                case .commonKeyArtist?: field = "ARTIST"
                case .commonKeyAlbumName?: field = "ALBUM"
                default: field = ["TITLE", "ARTIST", "ALBUM", "TIT2", "TPE1", "TALB", "©NAM", "©ART", "©ALB"].contains(raw) ? raw : ""
                }
                guard !field.isEmpty, let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                switch field {
                case "TITLE", "TIT2", "©NAM": if title.isEmpty { title = value }
                case "ARTIST", "TPE1", "©ART": if !artists.contains(value) { artists.append(value) }
                default: if album == nil { album = value }
                }
            }
            artist = artists.joined(separator: ", ")
        }
        let tech = Quality.read(url: url, size: size)
        if seconds <= 0 { seconds = tech.seconds }
        // Music only: anything under a minute is a sound, a voice note, a sample.
        guard seconds >= 60 else { return Entry(track: nil, size: size, modified: modified, quality: nil) }
        if title.isEmpty {
            // "Artist - Title.flac" when there are no tags.
            let stem = url.deletingPathExtension().lastPathComponent
            let parts = stem.components(separatedBy: " - ")
            if parts.count >= 2, artist.isEmpty { artist = parts[0]; title = parts.dropFirst().joined(separator: " - ") } else { title = stem }
        }
        // A missing album tag isn't the folder's name.
        if album?.caseInsensitiveCompare(url.deletingLastPathComponent().lastPathComponent) == .orderedSame { album = nil }
        let t = Track(source: .local, id: path, title: title, artist: artist, album: album, durationMs: Int64(seconds * 1000), art: "file:" + path)
        return Entry(track: t, size: size, modified: modified, quality: tech.label)
    }
}

/// What a song actually is: "FLAC · 24/96 · 2,612 kbps", "MP3 · 320 kbps", "OPUS · ~160 kbps".
enum Quality {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    static func cached(_ t: Track) -> String? { lock.lock(); defer { lock.unlock() }; return cache[t.key] }
    static func put(_ t: Track, _ label: String?) { guard let label else { return }; lock.lock(); cache[t.key] = label; lock.unlock() }

    /// A file's format, sample rate / bit depth (lossless) and bitrate, from Core Audio.
    static func read(url: URL, size: Int64) -> (label: String?, seconds: Double) {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let f = fileID else { return (nil, 0) }
        defer { AudioFileClose(f) }
        var asbd = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioFileGetProperty(f, kAudioFilePropertyDataFormat, &sz, &asbd)
        var bits: UInt32 = 0
        sz = 4
        AudioFileGetProperty(f, kAudioFilePropertySourceBitDepth, &sz, &bits)
        var seconds: Float64 = 0
        sz = 8
        AudioFileGetProperty(f, kAudioFilePropertyEstimatedDuration, &sz, &seconds)
        var bitRate: UInt32 = 0
        sz = 4
        AudioFileGetProperty(f, kAudioFilePropertyBitRate, &sz, &bitRate)
        let ext = url.pathExtension.lowercased()
        let format: String
        switch asbd.mFormatID {
        case kAudioFormatFLAC: format = "FLAC"
        case kAudioFormatAppleLossless: format = "ALAC"
        case kAudioFormatLinearPCM: format = ext.hasPrefix("aif") ? "AIFF" : "WAV"
        case kAudioFormatMPEGLayer3: format = "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: format = "AAC"
        case kAudioFormatOpus: format = "OPUS"
        case kAudioFormatEnhancedAC3: format = "E-AC3"
        default: format = ext.uppercased()
        }
        // Core Audio's bitrate when it has one; otherwise the file's average (size over length).
        var kbps = Int(bitRate / 1000)
        if (kbps <= 0 || ["FLAC", "ALAC", "WAV", "AIFF"].contains(format)), seconds > 0 { kbps = Int(Double(size) * 8 / seconds / 1000) }
        let lossless = ["FLAC", "ALAC", "WAV", "AIFF"].contains(format)
        let depth = bits > 0 ? Int(bits) : Int(asbd.mBitsPerChannel)
        var parts = [format]
        if lossless, asbd.mSampleRate > 0 {
            let khz = asbd.mSampleRate / 1000
            let rate = khz.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(khz)) : String(format: "%.1f", khz)
            parts.append(depth > 0 ? "\(depth)/\(rate)" : rate)
        }
        if kbps > 0 { parts.append("\(kbps.formatted(.number.grouping(.automatic))) kbps") }
        return (parts.joined(separator: " · "), seconds)
    }

    /// YouTube's audio formats (itag → what it is).
    static func youtube(_ itag: Int?) -> String? {
        switch itag {
        case 251: return "OPUS · ~160 kbps"
        case 250: return "OPUS · ~70 kbps"
        case 249: return "OPUS · ~50 kbps"
        case 774: return "OPUS · ~256 kbps"
        case 141: return "AAC · 256 kbps"
        case 140: return "AAC · 128 kbps"
        case 139: return "AAC · 48 kbps"
        case nil: return nil
        case let i?: return "itag \(i)"
        }
    }

    /// The short form for lists: "FLAC 24/96", "MP3 320".
    static func short(_ label: String?) -> String? {
        guard let label else { return nil }
        let p = label.components(separatedBy: " · ")
        guard p.count >= 2 else { return p.first }
        return "\(p[0]) \(p[1].replacingOccurrences(of: "~", with: "").replacingOccurrences(of: " kbps", with: "").replacingOccurrences(of: ",", with: ""))"
    }
}
