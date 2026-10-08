//! WreckBox core: the platform-independent engine used by the Windows, Android (and later Mac / iPad)
//! apps through Flutter, and by the `wbcore` command-line tool.

pub mod analysis;
pub mod decode;
pub mod fingerprint;
pub mod tags;
pub mod ffi;

use std::path::Path;

/// Decode and analyse one file (BPM, key, energy, loudness).
pub fn analyze_file(path: &Path) -> anyhow::Result<analysis::Analysis> {
    let audio = decode::decode_mono(path)?;
    Ok(analysis::analyze(&audio))
}
