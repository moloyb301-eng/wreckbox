//! Audio decoding (MP3, FLAC, AAC/ALAC/M4A, WAV, AIFF, OGG) to mono f32 at a fixed rate, via Symphonia.

use anyhow::{anyhow, Context, Result};
use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;

/// Analysis sample rate. 22.05 kHz keeps everything up to ~11 kHz, plenty for tempo and key.
pub const RATE: u32 = 22_050;

pub struct Audio {
    pub samples: Vec<f32>,
    pub rate: u32,
    /// Length of the original file in seconds.
    pub duration: f64,
}

/// Decodes the whole file to mono at `RATE` (simple averaging resampler; fine for analysis).
pub fn decode_mono(path: &Path) -> Result<Audio> {
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
    let src_rate = track.codec_params.sample_rate.ok_or_else(|| anyhow!("unknown sample rate"))?;
    let mut decoder = symphonia::default::get_codecs().make(&track.codec_params, &DecoderOptions::default())?;

    let ratio = src_rate as f64 / RATE as f64;
    let mut out: Vec<f32> = Vec::new();
    let mut acc = 0.0f64; // resampler state: sum and count of source samples for the current output slot
    let mut count = 0usize;
    let mut pos = 0.0f64; // position in source samples of the next output boundary
    let mut src_index = 0u64;
    let mut buf: Option<SampleBuffer<f32>> = None;

    loop {
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
            Err(SymError::DecodeError(_)) => continue, // skip a corrupt frame, keep going
            Err(e) => return Err(e.into()),
        };
        let spec = *decoded.spec();
        let channels = spec.channels.count().max(1);
        let sb = buf.get_or_insert_with(|| SampleBuffer::new(decoded.capacity() as u64, spec));
        if (sb.capacity() as usize) < decoded.capacity() * channels {
            *sb = SampleBuffer::new(decoded.capacity() as u64, spec);
        }
        sb.copy_interleaved_ref(decoded);
        for frame in sb.samples().chunks(channels) {
            let mono = frame.iter().sum::<f32>() / channels as f32;
            acc += mono as f64;
            count += 1;
            src_index += 1;
            if src_index as f64 >= pos + ratio {
                out.push((acc / count as f64) as f32);
                acc = 0.0;
                count = 0;
                pos += ratio;
            }
        }
    }
    if out.is_empty() {
        return Err(anyhow!("no audio decoded"));
    }
    let duration = src_index as f64 / src_rate as f64;
    Ok(Audio { samples: out, rate: RATE, duration })
}
