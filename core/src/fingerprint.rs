//! Audio fingerprints for Identify (naming a track from its sound): Chromaprint, the same algorithm and output
//! as `fpcalc` (the Mac app's tool), so AcoustID can look it up. Only the first two minutes are used, like fpcalc.

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use rusty_chromaprint::{Configuration, FingerprintCompressor, Fingerprinter};
use serde::Serialize;
use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

const MAX_SECONDS: u64 = 120;

#[derive(Serialize)]
pub struct Fingerprint {
    /// Whole-file length in seconds (AcoustID wants it).
    pub duration: u32,
    /// Compressed, URL-safe base64 — what `fpcalc` prints.
    pub fingerprint: String,
}

pub fn fingerprint(path: &Path) -> Result<Fingerprint> {
    let file = File::open(path).with_context(|| format!("can't open {}", path.display()))?;
    let mss = MediaSourceStream::new(Box::new(file), Default::default());
    let mut hint = Hint::new();
    if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
        hint.with_extension(ext);
    }
    let probed = symphonia::default::get_probe()
        .format(&hint, mss, &FormatOptions::default(), &MetadataOptions::default())
        .context("unsupported or corrupt audio file")?;
    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| anyhow!("no audio track"))?;
    let track_id = track.id;
    let rate = track.codec_params.sample_rate.ok_or_else(|| anyhow!("unknown sample rate"))?;
    let total_frames = track.codec_params.n_frames;
    let mut decoder = symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default())?;

    let config = Configuration::preset_test2(); // fpcalc's default algorithm
    let mut printer = Fingerprinter::new(&config);
    printer.start(rate, 1).map_err(|e| anyhow!("fingerprint: {e:?}"))?;
    let limit = MAX_SECONDS * rate as u64;
    let mut frames = 0u64;
    let mut buf: Option<SampleBuffer<f32>> = None;
    let mut mono: Vec<i16> = Vec::new();

    while frames < limit {
        let packet = match format.next_packet() {
            Ok(p) => p,
            Err(SymError::IoError(e)) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
            Err(SymError::ResetRequired) => break,
            Err(e) => return Err(e.into()),
        };
        if packet.track_id() != track_id {
            continue;
        }
        let decoded = match decoder.decode(&packet) {
            Ok(d) => d,
            Err(SymError::DecodeError(_)) => continue,
            Err(e) => return Err(e.into()),
        };
        let spec = *decoded.spec();
        let channels = spec.channels.count().max(1);
        let sb = buf.get_or_insert_with(|| SampleBuffer::new(decoded.capacity() as u64, spec));
        if (sb.capacity() as usize) < decoded.capacity() * channels {
            *sb = SampleBuffer::new(decoded.capacity() as u64, spec);
        }
        sb.copy_interleaved_ref(decoded);
        mono.clear();
        for frame in sb.samples().chunks(channels) {
            if frames >= limit {
                break;
            }
            let m = frame.iter().sum::<f32>() / channels as f32;
            mono.push((m.clamp(-1.0, 1.0) * i16::MAX as f32) as i16);
            frames += 1;
        }
        printer.consume(&mono);
    }
    printer.finish();
    if printer.fingerprint().is_empty() {
        return Err(anyhow!("too short to fingerprint"));
    }
    // The real length: from the header when it's there, else count the rest of the packets' frames.
    let duration = match total_frames {
        Some(n) => n as f64 / rate as f64,
        None => {
            let mut n = frames;
            while let Ok(p) = format.next_packet() {
                if p.track_id() == track_id {
                    n += p.dur;
                }
            }
            n as f64 / rate as f64
        }
    };
    let compressed = FingerprintCompressor::from(&config).compress(printer.fingerprint());
    Ok(Fingerprint {
        duration: duration.round() as u32,
        fingerprint: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(compressed),
    })
}
