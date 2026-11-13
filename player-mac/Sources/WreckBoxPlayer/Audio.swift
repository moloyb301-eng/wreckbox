import Accelerate
import AVFoundation
import Combine
import CoreAudio

/// This Mac's files: AVAudioEngine playing one file at a time through the 10-band EQ, with a spectrum tap for the dot
/// displays (installed only while one is on screen). Core Audio reads FLAC, ALAC/AAC, MP3, WAV/AIFF, Opus, OGG and
/// Dolby E-AC-3, so nothing is converted. (The same engine as WreckBox's MacAudio.)
@MainActor
final class LocalAudio {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    let eqUnit = AVAudioUnitEQ(numberOfBands: EQ.frequencies.count)
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var pausedAt: Double = 0
    private var token = 0
    var onEnd: (() -> Void)?

    init() {
        engine.attach(node)
        engine.attach(eqUnit)
        engine.connect(eqUnit, to: engine.mainMixerNode, format: nil)
        EQ.shared.attach(eqUnit)
        // Headphones plugged in / output changed: the engine stops; pick up where it was.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recover() }
        }
    }

    var hasFile: Bool { file != nil }
    var isPlaying: Bool { node.isPlaying && engine.isRunning }
    var duration: Double { file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0 }

    var position: Double {
        guard let f = file else { return 0 }
        guard node.isPlaying, let nt = node.lastRenderTime, let pt = node.playerTime(forNodeTime: nt) else { return pausedAt }
        return min(duration, Double(startFrame + pt.sampleTime) / f.processingFormat.sampleRate)
    }

    func load(_ path: String) throws {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        token += 1
        node.stop()
        let wasRunning = engine.isRunning
        if wasRunning { engine.pause() }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eqUnit)
        engine.connect(node, to: eqUnit, format: f.processingFormat)
        engine.connect(eqUnit, to: engine.mainMixerNode, format: f.processingFormat)
        if wasRunning { try? engine.start() }
        file = f
        pausedAt = 0
        schedule(from: 0)
    }

    func play() {
        guard file != nil else { return }
        if !engine.isRunning { try? engine.start() }
        node.play()
    }

    func pause() {
        pausedAt = position
        node.pause()
    }

    func stop() {
        token += 1
        node.stop()
        file = nil
        pausedAt = 0
        engine.pause()
    }

    func seek(_ seconds: Double) {
        guard let f = file else { return }
        let was = isPlaying
        let frame = AVAudioFramePosition(max(0, min(seconds, duration)) * f.processingFormat.sampleRate)
        pausedAt = Double(frame) / f.processingFormat.sampleRate
        schedule(from: frame)
        if was { play() }
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let f = file else { return }
        token += 1
        let t = token
        node.stop()
        startFrame = frame
        let count = AVAudioFrameCount(max(0, f.length - frame))
        guard count > 0 else { return }
        node.scheduleSegment(f, startingFrame: frame, frameCount: count, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.token == t { self?.onEnd?() } } }
        }
    }

    private func recover() {
        guard file != nil else { return }
        let at = position, was = node.isPlaying
        try? engine.start()
        seek(at)
        if was { play() }
    }

    // MARK: spectrum (only while a display is on screen)

    private var tapping = false
    func spectrum(_ on: Bool) {
        guard on != tapping else { return }
        tapping = on
        let mixer = engine.mainMixerNode
        if on {
            let levels = Levels.shared
            mixer.installTap(onBus: 0, bufferSize: 2048, format: mixer.outputFormat(forBus: 0)) { buffer, _ in levels.feed(buffer) }
        } else {
            mixer.removeTap(onBus: 0)
        }
    }
}

// MARK: - EQ

/// The 10-band EQ (±12 dB) and 8 presets shared by every WreckBox app. Mac files go through AVAudioUnitEQ; YouTube
/// Music through filters inside its page; Spotify (its own app) can't be reached, so it plays flat.
@MainActor
final class EQ: ObservableObject {
    static let shared = EQ()
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let presets: [(String, [Float])] = [
        ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        ("Bass boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        ("Club", [4, 3, 2, 0, -1, -1, 0, 2, 3, 3]),
        ("Hip-hop", [5, 4, 1, 2, -1, -1, 1, 0, 2, 3]),
        ("Electronic", [4, 3, 1, 0, -2, 1, 0, 1, 3, 4]),
        ("Vocal", [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        ("Treble", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        ("Loudness", [5, 3, 0, 0, -1, 0, -1, 0, 3, 4]),
    ]

    @Published private(set) var gains: [Float]
    @Published private(set) var on: Bool
    @Published private(set) var preset: String
    private weak var unit: AVAudioUnitEQ?
    /// The player passes changes on to the YouTube page.
    var onChange: (([Float]) -> Void)?

    /// The gains actually applied: flat when off.
    var effective: [Float] { on ? gains : Array(repeating: 0, count: 10) }

    private init() {
        let d = UserDefaults.standard
        let saved = d.array(forKey: "eqGains") as? [Float]
        gains = saved?.count == 10 ? saved! : Array(repeating: 0, count: 10)
        on = d.object(forKey: "eqOn") as? Bool ?? true
        preset = d.string(forKey: "eqPreset") ?? "Flat"
    }

    func attach(_ eq: AVAudioUnitEQ) {
        unit = eq
        eq.globalGain = 0
        for (i, b) in eq.bands.enumerated() {
            b.filterType = i == 0 ? .lowShelf : i == eq.bands.count - 1 ? .highShelf : .parametric
            b.frequency = Self.frequencies[i]
            b.bandwidth = 1.0
            b.bypass = false
        }
        apply()
    }

    func setOn(_ v: Bool) { on = v; changed() }

    func choose(_ name: String) {
        guard let p = Self.presets.first(where: { $0.0 == name }) else { return }
        gains = p.1; preset = name; on = true
        changed()
    }

    func setBand(_ i: Int, _ db: Float) {
        guard gains.indices.contains(i) else { return }
        gains[i] = max(-12, min(12, db)); preset = "Custom"; on = true
        changed()
    }

    private func changed() {
        let d = UserDefaults.standard
        d.set(gains, forKey: "eqGains"); d.set(on, forKey: "eqOn"); d.set(preset, forKey: "eqPreset")
        apply()
        onChange?(effective)
        WidgetBridge.shared.changed()
    }

    private func apply() {
        guard let eq = unit else { return }
        // Only in the path when it changes the sound.
        eq.bypass = !on || gains.allSatisfy { $0 == 0 }
        for (i, b) in eq.bands.enumerated() { b.gain = gains[i] }
    }
}

// MARK: - Levels

/// The music's real spectrum for the dot displays: 8 log-spaced bands (60 Hz – 16 kHz), 0…1. Measured from the Mac
/// file's audio (an engine tap) or from YouTube Music's page (its Web Audio analyser). Spotify can't be measured, so the
/// displays stay still. Only measured while some display wants it.
@MainActor
final class Levels: ObservableObject {
    static let shared = Levels()
    static let count = 8
    @Published private(set) var bands: [Float]?
    private var users = 0
    var onWantedChanged: ((Bool) -> Void)?
    var wanted: Bool { users > 0 }

    func want() { users += 1; if users == 1 { onWantedChanged?(true) } }
    func unwant() { users = max(0, users - 1); if users == 0 { onWantedChanged?(false); bands = nil } }
    func clear() { bands = nil }
    func set(_ b: [Float]) { if wanted, b.count == Self.count { bands = b } }

    // From the audio thread.
    private nonisolated(unsafe) var smooth = [Float](repeating: 0, count: 8)
    private nonisolated(unsafe) var last = Date.distantPast
    private nonisolated let n = 2048
    private nonisolated let fft = vDSP.FFT(log2n: 11, radix: .radix2, ofType: DSPSplitComplex.self)
    private nonisolated let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: 2048, isHalfWindow: false)

    nonisolated func feed(_ buffer: AVAudioPCMBuffer) {
        // ~10 a second is plenty for dots and light on the CPU.
        let now = Date()
        guard now.timeIntervalSince(last) > 0.1, let ch = buffer.floatChannelData, buffer.frameLength > 0, let fft else { return }
        last = now
        var mono = [Float](repeating: 0, count: n)
        let len = min(Int(buffer.frameLength), n)
        for c in 0..<min(Int(buffer.format.channelCount), 2) { for i in 0..<len { mono[i] += ch[c][i] } }
        mono = vDSP.multiply(mono, window)
        var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2), mags = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                mono.withUnsafeBufferPointer { mp in
                    mp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) }
                }
                fft.forward(input: split, output: &split)
                vDSP.absolute(split, result: &mags)
            }
        }
        let binHz = Float(buffer.format.sampleRate) / Float(n)
        for b in 0..<8 {
            let lo = 60 * pow(16000 / 60, Float(b) / 8), hi = 60 * pow(16000 / 60, Float(b + 1) / 8)
            let i0 = max(1, Int(lo / binHz)), i1 = max(i0 + 1, min(n / 2, Int(hi / binHz)))
            let db = 20 * log10(max((mags[i0..<i1].max() ?? 0) / Float(n), 1e-7))
            let v = max(0, min(1, (db + 70) / 60))
            smooth[b] = v > smooth[b] ? v : smooth[b] * 0.6 + v * 0.4
        }
        let snap = smooth
        DispatchQueue.main.async { MainActor.assumeIsolated { Levels.shared.set(snap) } }
    }
}

// MARK: - The Mac's volume

/// The default output device's volume (what the volume keys change), 0…1 — the widget's VOL keys use it, like the
/// phone's media volume on Android.
enum SystemVolume {
    private static func device() -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    private static var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static var value: Float {
        get {
            guard let d = device() else { return 0.5 }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            var a = address
            return AudioObjectGetPropertyData(d, &a, 0, nil, &size, &v) == noErr ? v : 0.5
        }
        set {
            guard let d = device() else { return }
            var v = Float32(max(0, min(1, newValue)))
            var a = address
            AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    /// One step = 1/16, like the volume keys.
    static func step(_ up: Bool) { value = (value * 16 + (up ? 1 : -1)).rounded() / 16 }
}
