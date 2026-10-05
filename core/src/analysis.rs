//! BPM, key, energy and loudness analysis — the cross-platform counterpart of the Mac app's Essentia
//! script, tuned to agree with it (see `wbcore compare`).
//!
//! Tempo: spectral-flux onset envelope → autocorrelation with harmonic reinforcement → parabolic peak,
//! folded into a DJ range (70–180) with the half / double tempo reported when it's a judgement call.
//! Key: harmonic pitch-class profile from spectral peaks, Pearson-correlated with the EDMA key profiles
//! (Faraldo et al. 2016, as used by Essentia's KeyExtractor), cross-checked with two other profiles.

use crate::decode::Audio;
use rustfft::{num_complex::Complex32, FftPlanner};
use serde::Serialize;

#[derive(Serialize, Default, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Analysis {
    pub bpm: Option<f64>,
    pub bpm_confidence: Option<f64>,
    pub bpm_alternate: Option<f64>,
    /// Other plausible tempos (strongest first), so an app can reconcile with a catalogue BPM.
    pub bpm_candidates: Vec<f64>,
    pub key: Option<String>,
    pub camelot: Option<String>,
    pub key_strength: Option<f64>,
    pub key_agreement: Option<u8>,
    pub energy: Option<f64>,
    pub loudness_lufs: Option<f64>,
    pub duration_sec: f64,
}

pub fn analyze(audio: &Audio) -> Analysis {
    let mut a = Analysis { duration_sec: (audio.duration * 10.0).round() / 10.0, ..Default::default() };
    let x = &audio.samples;
    if x.len() < audio.rate as usize * 5 {
        return a;
    }
    // Tempo from the body of the track (skip intro / outro), like the Mac app.
    let body = if audio.duration > 60.0 { &x[x.len() / 10..x.len() * 9 / 10] } else { &x[..] };
    if let Some((bpm, conf, cands)) = tempo(body, audio.rate) {
        a.bpm_candidates = cands.iter().map(|c| (fold_bpm(*c).0 * 10.0).round() / 10.0).collect();
        let (bpm, alt) = fold_bpm(bpm);
        a.bpm = Some((bpm * 10.0).round() / 10.0);
        a.bpm_confidence = Some((conf * 100.0).round() / 100.0);
        a.bpm_alternate = alt.map(|v| (v * 10.0).round() / 10.0);
    }
    if let Some(k) = key(x, audio.rate) {
        a.key = Some(k.name);
        a.camelot = Some(k.camelot);
        a.key_strength = Some((k.strength * 100.0).round() / 100.0);
        a.key_agreement = Some(k.agreement);
    }
    let rms = (x.iter().map(|v| (*v as f64) * (*v as f64)).sum::<f64>() / x.len() as f64).sqrt();
    let db = 20.0 * (rms + 1e-9).log10();
    a.energy = Some((((db + 30.0) / 24.0).clamp(0.0, 1.0) * 100.0).round() / 100.0);
    a.loudness_lufs = Some(((db - 0.7) * 10.0).round() / 10.0); // RMS-based approximation of integrated loudness
    a
}

// MARK: - Tempo

fn hann(n: usize) -> Vec<f32> {
    (0..n).map(|i| 0.5 - 0.5 * (2.0 * std::f32::consts::PI * i as f32 / n as f32).cos()).collect()
}

/// Magnitude spectra of successive frames.
fn stft(x: &[f32], n: usize, hop: usize) -> Vec<Vec<f32>> {
    let mut planner = FftPlanner::<f32>::new();
    let fft = planner.plan_fft_forward(n);
    let w = hann(n);
    let mut frames = Vec::new();
    let mut buf = vec![Complex32::new(0.0, 0.0); n];
    let mut start = 0;
    while start + n <= x.len() {
        for i in 0..n {
            buf[i] = Complex32::new(x[start + i] * w[i], 0.0);
        }
        fft.process(&mut buf);
        frames.push(buf[..n / 2].iter().map(|c| c.norm()).collect());
        start += hop;
    }
    frames
}

/// Returns (bpm, confidence 0–1, runner-up tempos).
fn tempo(x: &[f32], rate: u32) -> Option<(f64, f64, Vec<f64>)> {
    let (n, hop) = (1024usize, 256usize);
    let spec = stft(x, n, hop);
    if spec.len() < 64 {
        return None;
    }
    // Onset envelope: log-compressed spectral flux (half-wave rectified), up to ~8 kHz.
    let bin_hz = rate as f32 / n as f32;
    let max_bin = (8000.0 / bin_hz) as usize;
    let (low_lo, low_hi) = ((40.0 / bin_hz) as usize, (150.0 / bin_hz) as usize);
    let band = std::env::var("WB_BAND").unwrap_or_else(|_| "mix".into());
    let (w_full, w_low) = match band.as_str() { "full" => (1.0, 0.0), "low" => (0.0, 1.0), _ => (1.0, 1.0) };
    let mut full_env: Vec<f64> = vec![0.0];
    let mut low_env: Vec<f64> = vec![0.0];
    for t in 1..spec.len() {
        let (mut flux, mut low) = (0.0f64, 0.0f64);
        for b in 1..max_bin.min(n / 2) {
            let d = (1.0 + 100.0 * spec[t][b]).ln() - (1.0 + 100.0 * spec[t - 1][b]).ln();
            if d > 0.0 {
                flux += d as f64;
                if (low_lo.max(1)..=low_hi).contains(&b) { low += d as f64; }
            }
        }
        full_env.push(flux);
        low_env.push(low);
    }
    // Normalise each band so the kick band can count as much as the whole spectrum.
    let norm = |v: &Vec<f64>| { let m = v.iter().sum::<f64>() / v.len() as f64; v.iter().map(|x| x / m.max(1e-9)).collect::<Vec<f64>>() };
    let (full_env, low_env) = (norm(&full_env), norm(&low_env));
    let env: Vec<f64> = full_env.iter().zip(&low_env).map(|(f, l)| w_full * f + w_low * l).collect();
    // Remove the slow trend (local mean over ~1 s) and rectify.
    let fps = rate as f64 / hop as f64;
    let win = fps as usize;
    let mut prefix = vec![0.0f64; env.len() + 1];
    for (i, v) in env.iter().enumerate() {
        prefix[i + 1] = prefix[i] + v;
    }
    let env: Vec<f64> = (0..env.len())
        .map(|i| {
            let (lo, hi) = (i.saturating_sub(win / 2), (i + win / 2).min(env.len()));
            (env[i] - (prefix[hi] - prefix[lo]) / (hi - lo) as f64).max(0.0)
        })
        .collect();

    // Autocorrelation over lags for 50–220 BPM, reinforced by multiples of the lag (beat structure).
    let lag_of = |bpm: f64| fps * 60.0 / bpm;
    let (min_lag, max_lag) = (lag_of(220.0).floor() as usize, lag_of(50.0).ceil() as usize);
    let ac = |lag: usize| -> f64 {
        if lag >= env.len() {
            return 0.0;
        }
        env[lag..].iter().zip(&env[..env.len() - lag]).map(|(a, b)| a * b).sum::<f64>() / (env.len() - lag) as f64
    };
    let raw: Vec<f64> = (0..=max_lag * 4 + 2).map(ac).collect();
    let score = |lag: usize| raw[lag] + 0.5 * raw[lag * 2] + 0.25 * raw[(lag * 4).min(raw.len() - 1)];
    let scores: Vec<(usize, f64)> = (min_lag..=max_lag).map(|l| (l, score(l))).collect();
    let mean = scores.iter().map(|s| s.1).sum::<f64>() / scores.len() as f64;

    // Candidates: the strongest autocorrelation peaks and their metrical relatives. Syncopated genres
    // (jersey, baile, afro house) make 2/3, 4/5 and half-tempo periodicities strong, so each candidate
    // is re-ranked by how well a beat grid at that tempo lands on onsets rather than between them.
    let mut peaks: Vec<(usize, f64)> = scores
        .windows(3)
        .filter(|w| w[1].1 >= w[0].1 && w[1].1 >= w[2].1)
        .map(|w| w[1])
        .collect();
    peaks.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    let refine = |lag: usize| -> f64 {
        let (y0, y1, y2) = (score(lag - 1), score(lag), score(lag + 1));
        let d = y0 - 2.0 * y1 + y2;
        lag as f64 + if d.abs() > 1e-12 { (0.5 * (y0 - y2) / d).clamp(-0.5, 0.5) } else { 0.0 }
    };
    let mut candidates: Vec<f64> = Vec::new();
    for &(lag, _) in peaks.iter().take(5) {
        let bpm = fps * 60.0 / refine(lag);
        let rel: &[f64] = if std::env::var("WB_CAND").as_deref() == Ok("all") { &[1.0, 2.0, 0.5, 1.5, 2.0 / 3.0, 4.0 / 3.0, 0.75, 1.25, 0.8] } else { &[1.0, 2.0, 0.5] };
        for &r in rel {
            let c = bpm * r;
            if (68.0..=185.0).contains(&c) {
                candidates.push(c);
            }
        }
    }
    let grid = |bpm: f64| -> f64 {
        // Best phase: mean onset strength on the beats minus halfway between them.
        let period = fps * 60.0 / bpm;
        let steps = 16;
        let mut best = f64::MIN;
        for s in 0..steps {
            let phase = period * s as f64 / steps as f64;
            let (mut on, mut off, mut n) = (0.0, 0.0, 0usize);
            let mut t = phase;
            while t + period / 2.0 + 1.0 < env.len() as f64 {
                let at = |x: f64| { let i = x.round() as usize; env[i.saturating_sub(1)].max(env[i]).max(env[(i + 1).min(env.len() - 1)]) };
                on += at(t);
                off += at(t + period / 2.0);
                n += 1;
                t += period;
            }
            if n > 0 && on + off > 0.0 {
                // Scale-free contrast, so slower grids (which only hit the biggest kicks) aren't favoured.
                best = best.max((on - off) / (on + off));
            }
        }
        best
    };
    if std::env::var("WB_DEBUG_TEMPO").is_ok() {
        let mut dbg: Vec<(f64, f64, f64)> = candidates.iter().map(|&c| (c, grid(c), score((fps * 60.0 / c).round() as usize) / mean)).collect();
        dbg.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
        dbg.dedup_by(|a, b| (a.0 - b.0).abs() < 0.5);
        for (c, g, a) in dbg { eprintln!("  cand {c:6.1}  grid {g:6.3}  ac/mean {a:5.2}"); }
    }
    // Choose by periodicity strength (interpolated at the candidate's exact lag) with a gentle prior around
    // typical DJ tempos; the beat-grid contrast only settles half- vs double-time.
    let ac_at = |bpm: f64| -> f64 {
        let lag = fps * 60.0 / bpm;
        let (i, f) = (lag.floor() as usize, lag - lag.floor());
        if i + 1 >= raw.len() / 4 { return 0.0; }
        score(i) * (1.0 - f) + score(i + 1) * f
    };
    let prior = |bpm: f64| (-0.5 * ((bpm / 122.0).log2() / 1.0).powi(2)).exp();
    let mut bpm = candidates.iter().cloned().max_by(|a, b| (ac_at(*a) * prior(*a)).partial_cmp(&(ac_at(*b) * prior(*b))).unwrap())?;
    for alt in [bpm * 2.0, bpm / 2.0] {
        if (68.0..=185.0).contains(&alt) && ac_at(alt) >= 0.5 * ac_at(bpm) && grid(alt) > grid(bpm) + 0.05 {
            bpm = alt;
            break;
        }
    }
    let conf = ((peaks.first().map(|p| p.1).unwrap_or(0.0) / mean.max(1e-12) - 1.0) / 3.0).clamp(0.0, 1.0);
    let mut ranked = candidates.clone();
    ranked.sort_by(|a, b| (ac_at(*b) * prior(*b)).partial_cmp(&(ac_at(*a) * prior(*a))).unwrap());
    let mut others: Vec<f64> = Vec::new();
    for c in ranked {
        if (c - bpm).abs() / bpm > 0.03 && others.iter().all(|o| (o - c).abs() / c > 0.03) {
            others.push(c);
        }
        if others.len() == 3 { break; }
    }
    Some((bpm, conf, others))
}

/// Fold into 70–180; report the half / double tempo when both are plausible for DJ use.
pub fn fold_bpm(mut bpm: f64) -> (f64, Option<f64>) {
    if bpm <= 0.0 {
        return (bpm, None);
    }
    while bpm < 70.0 {
        bpm *= 2.0;
    }
    while bpm > 180.0 {
        bpm /= 2.0;
    }
    let alt = if bpm < 95.0 { Some(bpm * 2.0) } else if bpm > 150.0 { Some(bpm / 2.0) } else { None };
    (bpm, alt)
}

// MARK: - Key

const EDMA_MAJOR: [f64; 12] = [1.00, 0.29, 0.50, 0.40, 0.60, 0.56, 0.32, 0.80, 0.31, 0.45, 0.42, 0.39];
const EDMA_MINOR: [f64; 12] = [1.00, 0.31, 0.44, 0.58, 0.33, 0.49, 0.29, 0.78, 0.43, 0.29, 0.53, 0.32];
const BGATE_MAJOR: [f64; 12] = [1.00, 0.00, 0.42, 0.00, 0.53, 0.37, 0.00, 0.77, 0.00, 0.38, 0.21, 0.30];
const BGATE_MINOR: [f64; 12] = [1.00, 0.00, 0.36, 0.39, 0.00, 0.38, 0.00, 0.74, 0.27, 0.00, 0.42, 0.23];
const TEMPERLEY_MAJOR: [f64; 12] = [5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0];
const TEMPERLEY_MINOR: [f64; 12] = [5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 1.5, 4.0];

pub const NOTE_NAMES: [&str; 12] = ["A", "Bb", "B", "C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab"];

pub struct KeyResult {
    pub name: String,
    pub camelot: String,
    pub strength: f64,
    pub agreement: u8,
}

/// Pitch-class profile indexed from A (0 = A, 1 = Bb, …), from spectral peaks and their harmonics.
pub fn pitch_profile(x: &[f32], rate: u32) -> Option<[f64; 12]> {
    let envf = |k: &str, d: f64| std::env::var(k).ok().and_then(|v| v.parse::<f64>().ok()).unwrap_or(d);
    let n = envf("WB_KEY_N", 8192.0) as usize;
    let hop = n / 2;
    let max_peaks = envf("WB_KEY_PEAKS", 1e9) as usize;
    let power = envf("WB_KEY_POW", 2.0) as i32;
    let win = envf("WB_KEY_WIN", 4.0 / 3.0);
    let fmin = envf("WB_KEY_FMIN", 60.0);
    let spec = stft(x, n, hop);
    if spec.is_empty() {
        return None;
    }
    let bin_hz = rate as f64 / n as f64;
    let (lo, hi) = (((fmin / bin_hz) as usize).max(1), ((3500.0 / bin_hz) as usize).min(n / 2 - 2));
    let mut pcp = [0.0f64; 12];
    for frame in &spec {
        let mut fp = [0.0f64; 12];
        let peak = frame[lo..hi].iter().cloned().fold(0.0f32, f32::max) as f64;
        if peak <= 0.0 {
            continue;
        }
        let mut peaks: Vec<usize> = (lo..hi)
            .filter(|&b| frame[b] >= frame[b - 1] && frame[b] >= frame[b + 1] && (frame[b] as f64) >= peak * 1e-3)
            .collect();
        if peaks.len() > max_peaks {
            peaks.sort_by(|a, b| frame[*b].partial_cmp(&frame[*a]).unwrap());
            peaks.truncate(max_peaks);
        }
        for b in peaks {
            let m = frame[b] as f64;
            // Quadratic interpolation of the peak frequency.
            let (a, c) = (frame[b - 1] as f64, frame[b + 1] as f64);
            let d = a - 2.0 * m + c;
            let off = if d.abs() > 1e-12 { 0.5 * (a - c) / d } else { 0.0 };
            let f = (b as f64 + off) * bin_hz;
            // The peak and its sub-harmonics (it may be the 2nd–4th harmonic of a lower note).
            for h in 1..=4 {
                let f0 = f / h as f64;
                if f0 < 50.0 {
                    break;
                }
                let semis = 12.0 * (f0 / 440.0).log2();
                let nearest = semis.round();
                let dist = (semis - nearest).abs(); // 0 … 0.5 semitones
                if dist > 0.5 {
                    continue;
                }
                if dist > win / 2.0 { continue; }
                let w = (std::f64::consts::PI * dist / win).cos().powi(2); // HPCP-style window
                let pc = ((nearest as i64 % 12) + 12) % 12;
                fp[pc as usize] += m.powi(power) * w * 0.6f64.powi(h - 1);
            }
        }
        let mx = fp.iter().cloned().fold(0.0, f64::max);
        if mx > 0.0 {
            for i in 0..12 {
                pcp[i] += fp[i] / mx; // each frame votes equally
            }
        }
    }
    if pcp.iter().sum::<f64>() <= 0.0 {
        None
    } else {
        Some(pcp)
    }
}

fn pearson(x: &[f64; 12], y: &[f64; 12]) -> f64 {
    let (mx, my) = (x.iter().sum::<f64>() / 12.0, y.iter().sum::<f64>() / 12.0);
    let (mut num, mut dx, mut dy) = (0.0, 0.0, 0.0);
    for i in 0..12 {
        num += (x[i] - mx) * (y[i] - my);
        dx += (x[i] - mx).powi(2);
        dy += (y[i] - my).powi(2);
    }
    num / (dx * dy).sqrt().max(1e-12)
}

/// Best (tonic index from A, minor?, correlation) for one pair of profiles.
fn best_key(pcp: &[f64; 12], major: &[f64; 12], minor: &[f64; 12]) -> (usize, bool, f64) {
    let mut best = (0usize, false, f64::MIN);
    for tonic in 0..12 {
        let rotated: [f64; 12] = std::array::from_fn(|i| pcp[(i + tonic) % 12]);
        for (minor_mode, profile) in [(false, major), (true, minor)] {
            let r = pearson(&rotated, profile);
            if r > best.2 {
                best = (tonic, minor_mode, r);
            }
        }
    }
    best
}

pub fn key(x: &[f32], rate: u32) -> Option<KeyResult> {
    let pcp = pitch_profile(x, rate)?;
    let (tonic, minor, strength) = best_key(&pcp, &EDMA_MAJOR, &EDMA_MINOR);
    let others = [best_key(&pcp, &BGATE_MAJOR, &BGATE_MINOR), best_key(&pcp, &TEMPERLEY_MAJOR, &TEMPERLEY_MINOR)];
    let agreement = 1 + others.iter().filter(|o| o.0 == tonic && o.1 == minor).count() as u8;
    Some(KeyResult {
        name: format!("{} {}", NOTE_NAMES[tonic], if minor { "minor" } else { "major" }),
        camelot: camelot(tonic, minor),
        strength,
        agreement,
    })
}

/// Camelot code for a tonic indexed from A. C major = 8B, A minor = 8A; each fifth up adds 1.
pub fn camelot(tonic_from_a: usize, minor: bool) -> String {
    let from_c = (tonic_from_a + 9) % 12; // A=0 → C-based index
    let major_tonic = if minor { (from_c + 3) % 12 } else { from_c };
    let n = ((7 * major_tonic) % 12 + 7) % 12 + 1;
    format!("{}{}", n, if minor { "A" } else { "B" })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn camelot_codes() {
        assert_eq!(camelot(3, false), "8B"); // C major
        assert_eq!(camelot(0, true), "8A"); // A minor
        assert_eq!(camelot(7, true), "9A"); // E minor
        assert_eq!(camelot(8, true), "4A"); // F minor
        assert_eq!(camelot(7, false), "12B"); // E major
    }

    #[test]
    fn folding() {
        assert_eq!(fold_bpm(87.0), (87.0, Some(174.0)));
        assert_eq!(fold_bpm(256.0), (128.0, None));
        assert_eq!(fold_bpm(160.0), (160.0, Some(80.0)));
    }

    #[test]
    fn click_track_tempo() {
        // 128 BPM clicks for 30 s.
        let rate = 22_050u32;
        let mut x = vec![0.0f32; rate as usize * 30];
        let period = (rate as f64 * 60.0 / 128.0) as usize;
        let mut i = 0;
        while i + 200 < x.len() {
            for k in 0..200 {
                x[i + k] = (k as f32 * 0.3).sin() * (1.0 - k as f32 / 200.0);
            }
            i += period;
        }
        let (bpm, _, _) = tempo(&x, rate).unwrap();
        let (bpm, _) = fold_bpm(bpm);
        assert!((bpm - 128.0).abs() < 1.0, "got {bpm}");
    }

    #[test]
    fn a_minor_chord_key() {
        // Sustained A minor triad (A3, C4, E4) with a few harmonics.
        let rate = 22_050u32;
        let notes = [220.0f32, 261.63, 329.63];
        let x: Vec<f32> = (0..rate as usize * 10)
            .map(|i| {
                let t = i as f32 / rate as f32;
                notes.iter().map(|f| (2.0 * std::f32::consts::PI * f * t).sin() + 0.3 * (4.0 * std::f32::consts::PI * f * t).sin()).sum::<f32>()
            })
            .collect();
        let k = key(&x, rate).unwrap();
        assert_eq!(k.camelot, "8A", "got {}", k.name);
    }
}
