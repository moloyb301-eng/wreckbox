import Foundation
import Combine

/// Where a track plays from.
enum Source: String, Codable, CaseIterable {
    case local = "LOCAL", youtube = "YOUTUBE", spotify = "SPOTIFY"
    var label: String { switch self { case .local: return "Mac"; case .youtube: return "YouTube"; case .spotify: return "Spotify" } }
    var tag: String { switch self { case .local: return "MAC"; case .youtube: return "YOUTUBE"; case .spotify: return "SPOTIFY" } }
}

/// A song from any source. `id` is the source's own id: a file path, a YouTube video id, a Spotify track id.
struct Track: Codable, Hashable, Identifiable {
    var source: Source
    var id: String
    var title: String
    var artist: String
    var album: String?
    var durationMs: Int64 = 0
    var art: String?

    var key: String { "\(source.rawValue):\(id)" }
    var duration: Double { Double(durationMs) / 1000 }
}

struct Playlist: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var tracks: [Track]
    var updatedAt: Date
}

enum AppDirs {
    /// ~/Library/Application Support/WreckBox Player
    static let support: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WreckBox Player")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// Writes through a temp file so a crash mid-write never leaves a half file.
    static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = support.appendingPathComponent(name)
        guard let data = try? JSONEncoder.iso.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let d = try? Data(contentsOf: support.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder.iso.decode(type, from: d)
    }
}

extension JSONEncoder { static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }() }
extension JSONDecoder { static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }() }

/// This Mac's own library: liked songs, playlists, recently played (library.json). Works with nothing else installed.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    struct Data: Codable { var likes: [Track] = []; var playlists: [Playlist] = []; var recent: [Track] = [] }
    @Published private(set) var data = Data()

    private init() {
        // A damaged file must never stop the app from opening.
        if let d = AppDirs.load(Data.self, "library.json") { data = d }
    }

    func isLiked(_ t: Track) -> Bool { data.likes.contains { $0.key == t.key } }

    func toggleLike(_ t: Track) {
        update { d in
            if d.likes.contains(where: { $0.key == t.key }) { d.likes.removeAll { $0.key == t.key } } else { d.likes.insert(t, at: 0) }
        }
    }

    func clearRecent() { update { $0.recent = [] } }

    func played(_ t: Track) {
        update { d in
            d.recent.removeAll { $0.key == t.key }
            d.recent.insert(t, at: 0)
            if d.recent.count > 50 { d.recent.removeLast(d.recent.count - 50) }
        }
    }

    @discardableResult
    func createPlaylist(_ name: String, tracks: [Track] = []) -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let p = Playlist(id: UUID().uuidString, name: trimmed.isEmpty ? "New playlist" : trimmed, tracks: tracks, updatedAt: Date())
        update { $0.playlists.append(p) }
        return p
    }

    func renamePlaylist(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        edit(id) { $0.name = n }
    }

    func deletePlaylist(_ id: String) { update { $0.playlists.removeAll { $0.id == id } } }

    /// False when the song was already in it.
    @discardableResult
    func add(_ t: Track, to id: String) -> Bool {
        guard let p = data.playlists.first(where: { $0.id == id }), !p.tracks.contains(where: { $0.key == t.key }) else { return false }
        edit(id) { $0.tracks.append(t) }
        return true
    }

    func remove(at i: Int, from id: String) { edit(id) { p in if p.tracks.indices.contains(i) { p.tracks.remove(at: i) } } }

    func move(_ from: Int, _ to: Int, in id: String) {
        edit(id) { p in
            guard p.tracks.indices.contains(from), p.tracks.indices.contains(to) else { return }
            p.tracks.insert(p.tracks.remove(at: from), at: to)
        }
    }

    func playlist(_ id: String) -> Playlist? { data.playlists.first { $0.id == id } }

    private func edit(_ id: String, _ f: (inout Playlist) -> Void) {
        update { d in
            guard let i = d.playlists.firstIndex(where: { $0.id == id }) else { return }
            f(&d.playlists[i])
            d.playlists[i].updatedAt = Date()
        }
    }

    private func update(_ f: (inout Data) -> Void) {
        var d = data
        f(&d)
        data = d
        AppDirs.save(d, "library.json")
        WidgetBridge.shared.changed()
    }
}

/// Settings, kept in UserDefaults.
enum Prefs {
    static var autoplay: Bool {
        get { UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoplay") }
    }
    static var blockAds: Bool {
        get { UserDefaults.standard.object(forKey: "blockAds") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "blockAds") }
    }
    /// Folders scanned for music on this Mac.
    static var musicFolders: [String] {
        get {
            UserDefaults.standard.stringArray(forKey: "musicFolders") ?? {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return ["\(home)/Music", "\(home)/Downloads"]
            }()
        }
        set { UserDefaults.standard.set(newValue, forKey: "musicFolders") }
    }
}
