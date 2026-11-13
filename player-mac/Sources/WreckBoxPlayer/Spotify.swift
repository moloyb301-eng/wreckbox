import AppKit
import CryptoKit
import Foundation
import Network

/// Spotify search through the official Web API, with YOUR OWN Spotify developer app (its Client ID; the same one
/// WreckBox uses is filled in when WreckBox has one). Sign-in is PKCE in the browser with a loopback redirect
/// (http://127.0.0.1:8888/callback — add it to the developer app's Redirect URIs). The refresh token stays in
/// ~/Library/Application Support/WreckBox Player/spotify.json (owner-only).
@MainActor
final class SpotifyAPI: ObservableObject {
    static let shared = SpotifyAPI()
    static let redirectURI = "http://127.0.0.1:8888/callback"

    struct Config: Codable { var clientID: String; var refreshToken: String? }

    @Published private(set) var config: Config?
    @Published var status: String?
    private var access: (token: String, until: Date)?

    var connected: Bool { config?.refreshToken != nil }

    private init() {
        config = AppDirs.load(Config.self, "spotify.json")
        if config == nil, let d = try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DJLibrary/spotify.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let id = j["clientID"] as? String {
            config = Config(clientID: id, refreshToken: nil) // WreckBox's Client ID; the Player signs in for itself
        }
    }

    func setClientID(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        config = Config(clientID: id, refreshToken: nil)
        access = nil
        save()
    }

    func signOut() {
        guard let id = config?.clientID else { return }
        config = Config(clientID: id, refreshToken: nil)
        access = nil
        save()
    }

    /// Opens Spotify's sign-in page in the browser and waits for it to come back to 127.0.0.1:8888.
    func connect() async {
        guard let clientID = config?.clientID, !clientID.isEmpty else { status = "Enter your Spotify Client ID first"; return }
        let verifier = Self.random(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.random(16)
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirectURI), .init(name: "scope", value: "user-library-read playlist-read-private"),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge), .init(name: "state", value: state),
        ]
        status = "Waiting for the browser…"
        do {
            let wait = Task { try await Self.waitForCallback(state: state) }
            NSWorkspace.shared.open(c.url!)
            let code = try await wait.value
            let t = try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI,
                                     "client_id": clientID, "code_verifier": verifier])
            config?.refreshToken = t.refresh
            save()
            status = nil
        } catch {
            status = "Spotify sign-in failed: \(error.localizedDescription)"
        }
    }

    func search(_ q: String) async throws -> [Track] {
        var c = URLComponents(string: "https://api.spotify.com/v1/search")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "type", value: "track"), .init(name: "limit", value: "20")]
        let j = try await get(c.url!)
        let items = (j["tracks"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.compactMap(Self.track)
    }

    static func track(_ o: [String: Any]) -> Track? {
        guard let id = o["id"] as? String, let name = o["name"] as? String else { return nil }
        let artists = (o["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        let album = o["album"] as? [String: Any]
        let images = album?["images"] as? [[String: Any]] ?? []
        // The 300 px cover when there is one.
        let art = (images.first { ($0["width"] as? Int) == 300 } ?? images.first)?["url"] as? String
        return Track(source: .spotify, id: id, title: name, artist: artists, album: album?["name"] as? String,
                     durationMs: Int64(o["duration_ms"] as? Int ?? 0), art: art)
    }

    private func get(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func accessToken() async throws -> String {
        if let a = access, a.until > Date() { return a.token }
        guard let cfg = config, let rt = cfg.refreshToken else { throw URLError(.userAuthenticationRequired) }
        let t = try await token(["grant_type": "refresh_token", "refresh_token": rt, "client_id": cfg.clientID])
        if let r = t.refresh { config?.refreshToken = r; save() } // PKCE refresh tokens rotate
        return t.access
    }

    private func token(_ form: [String: String]) async throws -> (access: String, refresh: String?) {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = c.percentEncodedQuery?.data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let a = j["access_token"] as? String else {
            throw NSError(domain: "Spotify", code: 1, userInfo: [NSLocalizedDescriptionKey: j["error_description"] as? String ?? "token request failed"])
        }
        access = (a, Date().addingTimeInterval(Double(j["expires_in"] as? Int ?? 3600) - 60))
        return (a, j["refresh_token"] as? String)
    }

    private func save() {
        guard let config else { return }
        AppDirs.save(config, "spotify.json")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppDirs.support.appendingPathComponent("spotify.json").path)
    }

    private static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    /// A one-shot HTTP server on 127.0.0.1:8888 that catches ?code= from the redirect.
    nonisolated private static func waitForCallback(state: String) async throws -> String {
        let listener = try NWListener(using: .tcp, on: 8888)
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            listener.newConnectionHandler = { conn in
                conn.start(queue: .main)
                conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    let line = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                    let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let q = URLComponents(string: "http://x\(path)")?.queryItems ?? []
                    let code = q.first { $0.name == "code" }?.value
                    let ok = code != nil && q.first { $0.name == "state" }?.value == state
                    let body = ok ? "Spotify connected to WreckBox Player. You can close this tab." : "Sign-in failed: \(q.first { $0.name == "error" }?.value ?? "unexpected request")"
                    let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n\(body)"
                    conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
                    guard path.hasPrefix("/callback"), !done else { return }
                    done = true
                    listener.cancel()
                    if ok { cont.resume(returning: code!) } else { cont.resume(throwing: NSError(domain: "Spotify", code: 2, userInfo: [NSLocalizedDescriptionKey: body])) }
                }
            }
            listener.start(queue: .main)
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Spotify songs play in the Spotify app, driven through its AppleScript interface (the Mac's web views can't play
/// Spotify's protected audio). It's started hidden; the Player keeps the queue: when Spotify moves on to a song of its
/// own, that's the end of ours, and Spotify is paused.
final class SpotifyApp: @unchecked Sendable {
    struct State { var playing: Bool; var position: Double; var trackID: String?; var duration: Double; var running: Bool }

    private let queue = DispatchQueue(label: "spotify-app")
    private var timer: DispatchSourceTimer?
    var onState: (@MainActor (State) -> Void)?

    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil }

    func play(_ id: String) {
        launchHidden {
            self.run("tell application \"Spotify\" to play track \"spotify:track:\(id)\"")
        }
        poll(true)
    }

    func resume() { queue.async { self.run("tell application \"Spotify\" to play") }; poll(true) }
    func pause() { queue.async { self.run("if application \"Spotify\" is running then tell application \"Spotify\" to pause") } }
    func stop() { pause(); poll(false) }
    func seek(_ s: Double) { queue.async { self.run("tell application \"Spotify\" to set player position to \(String(format: "%.2f", s))") } }

    /// Reads the app's state every half second while one of our songs is in it.
    func poll(_ on: Bool) {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            guard on else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.5, repeating: 0.5)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    private func tick() {
        let script = """
        if application "Spotify" is running then
          tell application "Spotify"
            set st to player state as string
            set p to round ((player position) * 1000)
            try
              set i to id of current track
              set d to duration of current track
            on error
              set i to ""
              set d to 0
            end try
            return st & "|" & p & "|" & i & "|" & d
          end tell
        else
          return "stopped|0||0"
        end if
        """
        guard let out = run(script) else { return }
        let parts = out.components(separatedBy: "|")
        guard parts.count == 4 else { return }
        let s = State(playing: parts[0] == "playing", position: (Double(parts[1]) ?? 0) / 1000,
                      trackID: parts[2].components(separatedBy: ":").last.flatMap { $0.isEmpty ? nil : $0 },
                      duration: (Double(parts[3]) ?? 0) / 1000, running: !(parts[0] == "stopped" && parts[2].isEmpty))
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onState?(s) } }
    }

    private func launchHidden(then: @escaping @Sendable () -> Void) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            cfg.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
                // Its scripting answers a few seconds after launch.
                self.queue.asyncAfter(deadline: .now() + 4) { then() }
            }
        } else {
            queue.async { then() }
        }
    }

    @discardableResult
    private func run(_ source: String) -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: source)?.executeAndReturnError(&err)
        return err == nil ? r?.stringValue : nil
    }
}
