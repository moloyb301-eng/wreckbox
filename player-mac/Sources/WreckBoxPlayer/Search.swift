import Foundation

/// One search across this Mac, YouTube Music and Spotify, merged into the nearest results.
///  - YouTube Music: its own web API (the one music.youtube.com uses — no key). It also matches lyrics.
///  - Spotify: the Web API with your own Spotify developer app (Settings → Accounts).
///  - Mac: the music files LocalMusic knows about.
enum Search {
    struct Found { var tracks: [Track]; var failed: [String] }

    @MainActor
    static func all(_ q: String) async -> Found {
        let local = LocalMusic.shared.search(q)
        let spotifyOn = SpotifyAPI.shared.connected
        async let yt: [Track]? = try? youtube(q)
        async let sp: [Track]? = spotifyOn ? (try? SpotifyAPI.shared.search(q)) : nil
        let (y, s) = await (yt, sp)
        var failed: [String] = []
        if y == nil { failed.append("YouTube Music") }
        if spotifyOn && s == nil { failed.append("Spotify") }
        return Found(tracks: rank(q, local + (y ?? []) + (s ?? [])), failed: failed)
    }

    /// Words that mark something other than the original song — skipped unless the search asks for them.
    private static let noise = ["cover", "karaoke", "instrumental", "8 bit", "dance", "choreography", "tutorial", "reaction",
                                "slowed", "reverb", "sped up", "nightcore", "originally performed", "tribute", "lesson", "piano version", "status"]

    /// Nearest first: every typed word should be in the title or artist; the artist matching counts extra; covers,
    /// karaoke and slowed/sped-up versions drop unless asked for; titles with lots of extra words drop a little.
    static func rank(_ q: String, _ list: [Track]) -> [Track] {
        let nq = norm(q)
        let words = nq.split(separator: " ").map(String.init)
        func score(_ t: Track) -> Double {
            let title = norm(t.title), artist = norm(t.artist)
            let all = "\(title) \(artist) \(norm(t.album ?? ""))"
            let tw = title.split(separator: " ").map(String.init)
            let matched = words.filter { all.contains($0) }.count
            var s = Double(matched) / Double(max(1, words.count))
            if words.contains(where: { $0.count > 2 && artist.contains($0) }) { s += 0.6 }
            let allInTitle = words.allSatisfy { title.contains($0) }
            if title == nq || (allInTitle && tw.count <= words.count + 1) { s += 0.5 }
            let extra = tw.filter { w in !words.contains(where: { w.contains($0) }) }.count
            s -= 0.4 * Double(extra) / Double(max(1, tw.count))
            if noise.contains(where: { all.contains($0) && !nq.contains($0) }) { s -= 1 }
            if t.source == .local { s += 0.2 }
            return s
        }
        let scored: [(index: Int, track: Track, score: Double)] = list.enumerated().map { ($0.offset, $0.element, score($0.element)) }
        let ordered = scored.sorted { (a, b) -> Bool in a.score != b.score ? a.score > b.score : a.index < b.index }
        return ordered.map { $0.track }
    }

    static func norm(_ s: String) -> String {
        let folded = s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }

    // MARK: YouTube Music

    private static let songs = "EgWKAQIIAWoMEA4QChADEAQQCRAF"
    private static let videos = "EgWKAQIQAWoMEA4QChADEAQQCRAF"

    static func youtube(_ q: String) async throws -> [Track] {
        async let s = innertube("search", ["query": q, "params": songs], key: "musicResponsiveListItemRenderer", item: searchItem)
        async let v = innertube("search", ["query": q, "params": videos], key: "musicResponsiveListItemRenderer", item: searchItem)
        let all = try await s + (try await v).prefix(5)
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// POSTs to YouTube Music's own API and collects every `key` renderer in the answer.
    static func innertube(_ endpoint: String, _ body: [String: Any], key: String, item: @escaping ([String: Any]) -> Track?) async throws -> [Track] {
        var payload = body
        payload["context"] = ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20251001.01.00", "hl": "en"]]
        var req = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue(YouTubeEngine.userAgent, forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var out: [Track] = []
        walk(try JSONSerialization.jsonObject(with: data), key) { if let t = item($0) { out.append(t) } }
        return out
    }

    private static func walk(_ v: Any, _ key: String, _ f: ([String: Any]) -> Void) {
        if let o = v as? [String: Any] {
            if let r = o[key] as? [String: Any] { f(r); return }
            for (_, x) in o { walk(x, key, f) }
        } else if let a = v as? [Any] {
            for x in a { walk(x, key, f) }
        }
    }

    /// "Artist / Album" from a run's browse endpoint.
    static func pageType(_ run: [String: Any]) -> String? {
        ((((run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseEndpointContextSupportedConfigs"]
            as? [String: Any])?["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"] as? String
    }

    static func ms(_ text: String) -> Int64? {
        guard text.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil else { return nil }
        return text.split(separator: ":").reduce(Int64(0)) { $0 * 60 + (Int64($1) ?? 0) } * 1000
    }

    static func bigArt(_ thumbs: [[String: Any]]?) -> String? {
        (thumbs?.last?["url"] as? String)?.replacingOccurrences(of: #"=w\d+-h\d+"#, with: "=w544-h544", options: .regularExpression)
    }

    private static func searchItem(_ r: [String: Any]) -> Track? {
        guard let cols = r["flexColumns"] as? [[String: Any]] else { return nil }
        func runs(_ i: Int) -> [[String: Any]]? {
            guard i < cols.count else { return nil }
            return ((cols[i]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any])?["text"] as? [String: Any])?["runs"] as? [[String: Any]]
        }
        guard let first = runs(0)?.first, let title = first["text"] as? String else { return nil }
        let id = ((r["playlistItemData"] as? [String: Any])?["videoId"] as? String)
            ?? (((first["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"] as? String)
        guard let id, !id.isEmpty else { return nil }
        var artists: [String] = [], album: String?, duration: Int64 = 0
        let meta = runs(1) ?? []
        for run in meta {
            let text = run["text"] as? String ?? ""
            switch pageType(run) {
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL": artists.append(text)
            case "MUSIC_PAGE_TYPE_ALBUM": album = text
            default: if let m = ms(text) { duration = m }
            }
        }
        if artists.isEmpty, let a = meta.first?["text"] as? String, a != "Song", a != "Video" { artists.append(a) }
        let thumbs = (((r["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any])?["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        return Track(source: .youtube, id: id, title: title, artist: artists.joined(separator: ", "), album: album, durationMs: duration, art: bigArt(thumbs))
    }
}

/// Song radio, the way YouTube Music does it: every song has a radio mix ("RDAMVM" + its video id) that YouTube's
/// recommender fills with similar music. No key, no account. A Spotify or Mac song is first found on YouTube Music to
/// seed it; songs from the mix that are on this Mac play from the file.
enum Radio {
    @MainActor
    static func similar(to seed: Track, excluding exclude: Set<String>, max: Int = 25) async -> [Track] {
        let id: String
        if seed.source == .youtube { id = seed.id } else if let found = await findOnYouTube(seed) { id = found } else { return [] }
        let mix = ((try? await Search.innertube("next", ["videoId": id, "playlistId": "RDAMVM\(id)", "params": "wAEB", "isAudioOnly": true],
                                                key: "playlistPanelVideoRenderer", item: panelItem)) ?? []).filter { $0.id != id }
        var local: [String: Track] = [:]
        for t in LocalMusic.shared.tracks { local[name(t)] = t }
        var seen = exclude
        seen.insert(name(seed))
        var out: [Track] = []
        for t in mix {
            let n = name(t)
            if seen.contains(t.key) || seen.contains(n) { continue }
            seen.insert(n)
            out.append(local[n] ?? t)
            if out.count >= max { break }
        }
        return out
    }

    /// "title|first artist", normalised — the same song across sources.
    static func name(_ t: Track) -> String {
        let title = t.title.components(separatedBy: " (feat").first!.components(separatedBy: " - ").first!
        var artist = t.artist
        for sep in [",", "&", " x ", " feat"] { artist = artist.components(separatedBy: sep).first ?? artist }
        return Search.norm(title) + "|" + Search.norm(artist)
    }

    private static func findOnYouTube(_ t: Track) async -> String? {
        let q = "\(t.title) \(t.artist)"
        let hits = (try? await Search.youtube(q)) ?? []
        return (hits.first { name($0) == name(t) } ?? Search.rank(q, hits).first)?.id
    }

    /// One song of the radio panel; fan uploads ("… views") are skipped.
    private static func panelItem(_ r: [String: Any]) -> Track? {
        guard let id = r["videoId"] as? String, !id.isEmpty,
              let title = ((r["title"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String else { return nil }
        let runs = ((r["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []
        if runs.contains(where: { ($0["text"] as? String)?.hasSuffix(" views") == true }) { return nil }
        var artists: [String] = [], album: String?
        for p in runs {
            switch Search.pageType(p) {
            case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL": artists.append(p["text"] as? String ?? "")
            case "MUSIC_PAGE_TYPE_ALBUM": album = p["text"] as? String
            default: break
            }
        }
        if artists.isEmpty, let a = runs.first?["text"] as? String { artists.append(a) }
        let length = (((r["lengthText"] as? [String: Any])?["runs"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let thumbs = (r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        return Track(source: .youtube, id: id, title: title, artist: artists.joined(separator: ", "), album: album,
                     durationMs: Search.ms(length) ?? 0, art: Search.bigArt(thumbs))
    }
}
