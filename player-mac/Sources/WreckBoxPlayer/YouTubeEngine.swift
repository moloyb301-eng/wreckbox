import AppKit
import WebKit

/// What YouTube Music's page is doing, reported every half second.
struct WebState {
    var hasMedia = false
    var paused = true
    var position: Double = 0
    var duration: Double = 0
    var ended = false
    var ad = false
    var url = ""
    var at = Date()
    var itag: Int?
}

/// YouTube Music's web player in a web view nobody sees (only the sign-in window ever shows the site). A script
/// injected before the page's own code keeps it believing it's on screen, catches the media element it plays,
/// reports state, fires `ended` the moment a song finishes (so YouTube's autoplay never takes over), routes the audio
/// through the EQ and an analyser (only when needed), and — with Block ads on — skips ads and blocks ad hosts.
/// The same page script as the Android Player's WebEngine (YouTube parts).
@MainActor
final class YouTubeEngine: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    nonisolated static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    static let signIn = URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F")!

    private(set) var last = WebState()
    var onState: ((WebState) -> Void)?
    var onEnded: ((String) -> Void)?

    private var view: WKWebView?
    private var window: NSWindow?
    private var levelsOn = false

    /// The page, made on first use: a real desktop-sized page (1280×800) in a borderless window parked off screen.
    private func page() -> WKWebView {
        if let view { return view }
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default() // shares the sign-in window's cookies
        let uc = cfg.userContentController
        uc.add(self, name: "wb")
        uc.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: cfg)
        v.customUserAgent = Self.userAgent
        v.navigationDelegate = self
        Self.applyAdBlock(to: uc)
        let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.contentView = v
        w.orderBack(nil)
        view = v
        window = w
        return v
    }

    func playTrack(_ id: String) {
        last = WebState()
        page().load(URLRequest(url: URL(string: "https://music.youtube.com/watch?v=\(id)")!))
        // The page's script starts the track once it's loaded.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            self.js("WBC.start()")
            self.eq(EQ.shared.effective)
            if self.levelsOn { self.js("WBC.levels(true)") }
        }
    }

    func play() { js("WBC.play()") }
    func pause() { js("WBC.pause()") }
    func stop() { js("WBC.stop()") }

    func seek(_ s: Double) {
        js("WBC.seek(\(s))")
        // It may not report again while paused: show the new position at once.
        last.position = s
        last.at = Date()
    }

    func eq(_ g: [Float]) { js("WBC.eq([\(g.map { String($0) }.joined(separator: ","))])") }

    func levels(_ on: Bool) {
        guard on != levelsOn else { return }
        levelsOn = on
        js("WBC.levels(\(on))")
    }

    /// Unloads the page (frees memory and timers); the next YouTube song loads it again.
    func park() {
        last = WebState()
        levelsOn = false
        view?.load(URLRequest(url: URL(string: "about:blank")!))
    }

    private func js(_ code: String) { view?.evaluateJavaScript("window.WBC && \(code)", completionHandler: nil) }

    // MARK: the page reports

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let o = m.body as? [String: Any], let k = o["k"] as? String else { return }
        switch k {
        case "state":
            guard let s = o["v"] as? String, let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return }
            func d(_ key: String) -> Double { let v = (j[key] as? NSNumber)?.doubleValue ?? 0; return v.isFinite ? v : 0 }
            last = WebState(hasMedia: j["has"] as? Bool ?? false, paused: j["paused"] as? Bool ?? true, position: d("pos"), duration: d("dur"),
                            ended: j["ended"] as? Bool ?? false, ad: j["ad"] as? Bool ?? false, url: j["url"] as? String ?? "", at: Date(),
                            itag: (j["itag"] as? NSNumber).map(\.intValue).flatMap { $0 > 0 ? $0 : nil })
            onState?(last)
        case "ended": onEnded?(o["v"] as? String ?? "ended")
        case "levels":
            if let csv = o["v"] as? String { Levels.shared.set(csv.split(separator: ",").compactMap { Float($0) }) }
        default: break
        }
    }

    // MARK: ad blocking

    /// Known ad and tracking hosts never load in the page (YouTube's in-video ads come from the same servers as the
    /// music, so the page script mutes and skips those instead). Off in Settings → Block ads.
    private static func applyAdBlock(to uc: WKUserContentController) {
        guard Prefs.blockAds else { return }
        let hosts = ["doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com", "googletagmanager.com",
                     "googletagservices.com", "adservice.google.com", "imasdk.googleapis.com", "scorecardresearch.com", "moatads.com", "adnxs.com"]
        var rules = hosts.map { #"{"trigger":{"url-filter":"^https?://([^/]+\.)?\#($0.replacingOccurrences(of: ".", with: "\\\\."))/"},"action":{"type":"block"}}"# }
        for p in ["/pagead/", "/ptracking", "/api/stats/ads", "/get_midroll_", "/api/stats/atr"] {
            rules.append(#"{"trigger":{"url-filter":"youtube\\.com\#(p)"},"action":{"type":"block"}}"#)
        }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "wb-adblock", encodedContentRuleList: "[\(rules.joined(separator: ","))]") { list, _ in
            if let list { uc.add(list) }
        }
    }

    // MARK: the page script

    static let pageScript = """
    (function () {
      if (window.WBC) return;
      var post = function (k, v) { try { window.webkit.messageHandlers.wb.postMessage({ k: k, v: v }); } catch (e) {} };
      var WB = { state: function (j) { post('state', j); }, ended: function (w) { post('ended', w); }, levels: function (c) { post('levels', c); } };
      var BLOCK_ADS = \(Prefs.blockAds ? "true" : "false");
      try {
        Object.defineProperty(document, 'visibilityState', { get: function () { return 'visible'; } });
        Object.defineProperty(document, 'hidden', { get: function () { return false; } });
        document.addEventListener('visibilitychange', function (e) { e.stopImmediatePropagation(); }, true);
        window.addEventListener('blur', function (e) { e.stopImmediatePropagation(); }, true);
      } catch (e) {}
      var last = null;
      function hook(m) {
        if (m.__wb) return; m.__wb = 1;
        m.addEventListener('ended', function () { if (isAd()) return; m.pause(); WB.ended('media ended'); });
      }
      var eqG = null, actx = null, an = null, lv = null, wired = [], FREQ = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
      function shaped() { return !!eqG && eqG.some(function (g) { return g !== 0; }); }
      function eqWire(m) {
        if (m.__wbeq) return;
        if (!lv && !shaped()) return;
        try {
          actx = actx || new AudioContext({ latencyHint: 'playback' });
          an = an || actx.createAnalyser(); an.fftSize = 2048; an.smoothingTimeConstant = 0.5;
          var src = actx.createMediaElementSource(m), fs = [], g0 = eqG || [0,0,0,0,0,0,0,0,0,0];
          FREQ.forEach(function (f, i) {
            var b = actx.createBiquadFilter();
            b.type = i === 0 ? 'lowshelf' : i === 9 ? 'highshelf' : 'peaking';
            b.frequency.value = f; b.Q.value = 1.1; b.gain.value = g0[i];
            if (i > 0) fs[i - 1].connect(b);
            fs.push(b);
          });
          var w = { src: src, fs: fs, mode: '' };
          m.__wbeq = w; wired.push(w);
          route();
        } catch (e) {}
      }
      function route() {
        var mode = shaped() ? 'eq' : lv ? 'an' : 'direct';
        wired.forEach(function (w) {
          if (w.mode === mode) return;
          w.src.disconnect(); w.fs[9].disconnect();
          if (mode === 'eq') { w.src.connect(w.fs[0]); w.fs[9].connect(actx.destination); w.fs[9].connect(an); }
          else { w.src.connect(actx.destination); if (mode === 'an') w.src.connect(an); }
          w.mode = mode;
        });
      }
      var origPlay = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        last = this; hook(this); eqWire(this);
        if (window.WBC && window.WBC.hold) return Promise.resolve();
        return origPlay.apply(this, arguments);
      };
      var scanAt = 0, scanned = null;
      function media() {
        if (last && !last.paused) return last;
        var now = Date.now();
        if (now - scanAt > 2000) {
          scanAt = now; scanned = null;
          var all = document.getElementsByTagName('video');
          for (var i = 0; i < all.length && !scanned; i++) if (!all[i].paused) scanned = all[i];
          if (!scanned && !last) scanned = document.querySelector('video,audio');
        }
        return scanned || last;
      }
      function q(sel) { return document.querySelector(sel); }
      function click(sel) { var b = q(sel); if (b) { b.click(); return true; } return false; }
      var mpEl = null, barEl = null;
      function isAd() {
        if (!mpEl || !mpEl.isConnected) mpEl = document.getElementById('movie_player');
        if (!barEl || !barEl.isConnected) barEl = document.querySelector('ytmusic-player-bar');
        return !!((mpEl && (mpEl.classList.contains('ad-showing') || mpEl.classList.contains('ad-interrupting'))) || (barEl && barEl.hasAttribute('is-ad')));
      }
      window.WBC = {
        hold: false, startedAt: 0,
        play: function () {
          WBC.hold = false; WBC.startedAt = Date.now();
          var m = media();
          if (m && m.src) { m.play(); return; }
          click('#play-pause-button');
        },
        pause: function () { var m = media(); if (m) m.pause(); },
        stop: function () { WBC.hold = true; WBC.pause(); },
        seek: function (sec) { var m = media(); if (m) m.currentTime = sec; },
        eq: function (g) {
          eqG = g;
          wired.forEach(function (w) { w.fs.forEach(function (b, i) { b.gain.value = g[i]; }); });
          route();
          var m = media(); if (m) eqWire(m);
        },
        levels: function (on) {
          if (!on) { if (lv) clearInterval(lv); lv = null; route(); return; }
          if (lv) return;
          lv = setInterval(function () {
            var m = media(); if (!m || m.paused || isAd()) return;
            eqWire(m); if (!an) return;
            if (actx.state === 'suspended') actx.resume();
            var d = new Uint8Array(an.frequencyBinCount); an.getByteFrequencyData(d);
            var hz = actx.sampleRate / an.fftSize, out = [];
            for (var b = 0; b < 8; b++) {
              var lo = Math.max(1, Math.floor(60 * Math.pow(16000 / 60, b / 8) / hz)), hi = Math.max(lo + 1, Math.floor(60 * Math.pow(16000 / 60, (b + 1) / 8) / hz)), p = 0;
              for (var k = lo; k < hi && k < d.length; k++) p = Math.max(p, d[k]);
              out.push((p / 255).toFixed(2));
            }
            WB.levels(out.join(','));
          }, 100);
          route();
        },
        start: function () {
          WBC.hold = false; WBC.startedAt = Date.now();
          var tries = 0, t = setInterval(function () {
            tries++;
            var m = media();
            if ((m && !m.paused) || tries > 25) { clearInterval(t); return; }
            click('#play-pause-button') || (m && m.play && m.play());
          }, 800);
        }
      };
      (function tick() {
        var m = media(), ad = isAd();
        if (ad && m && BLOCK_ADS) {
          m.muted = true;
          if (isFinite(m.duration) && m.duration > 0) m.currentTime = m.duration;
          click('.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button');
        } else if (m && m.muted) m.muted = false;
        if (actx && actx.state === 'suspended' && m && !m.paused) actx.resume();
        var itag = WBC.itag || 0;
        if (!itag || WBC.itagFor !== location.href) try {
          var mp = document.getElementById('movie_player'), sn = mp && mp.getStatsForNerds && mp.getStatsForNerds();
          var mt = sn && sn.codecs && sn.codecs.match(/\\((\\d+)\\)[^()]*$/); if (mt) { itag = +mt[1]; WBC.itag = itag; WBC.itagFor = location.href; }
        } catch (e) {}
        WB.state(JSON.stringify({ itag: itag,
          has: !!(m && (m.currentSrc || m.src || m.readyState > 0 || m.currentTime > 0)), paused: m ? m.paused : true,
          pos: m ? m.currentTime : 0, dur: m ? m.duration : 0, ended: m ? m.ended : false, ad: ad, url: location.href }));
        var busy = (m && !m.paused) || Date.now() - WBC.startedAt < 15000;
        setTimeout(tick, busy ? 500 : 2000);
      })();
    })();
    """
}

/// The YouTube Music sign-in window (Settings → Accounts). It shares the hidden page's cookies and closes itself once
/// music.youtube.com is reached signed in.
@MainActor
final class SignInWindow: NSObject, WKNavigationDelegate {
    static let shared = SignInWindow()
    private var window: NSWindow?
    var onDone: (() -> Void)?

    func open(_ url: URL) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: cfg)
        v.customUserAgent = YouTubeEngine.userAgent
        v.navigationDelegate = self
        v.load(URLRequest(url: url))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Sign in to YouTube Music"
        w.isReleasedWhenClosed = false
        w.contentView = v
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView.url?.host == "music.youtube.com" else { return }
        Task { @MainActor in
            if await YouTubeAccount.signedIn() { self.window?.close(); self.window = nil; self.onDone?() }
        }
    }
}

enum YouTubeAccount {
    /// Signed in = Google's session cookie for youtube.com is in the shared store.
    @MainActor
    static func signedIn() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.contains { $0.domain.hasSuffix("youtube.com") && ($0.name == "SAPISID" || $0.name == "__Secure-3PAPISID") }
    }

    @MainActor
    static func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let google = records.filter { $0.displayName.contains("youtube") || $0.displayName.contains("google") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: google)
    }
}
