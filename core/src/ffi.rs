//! C ABI for the apps (Dart FFI). Every function takes / returns UTF-8 JSON strings; the caller frees
//! returned strings with `wb_free`. Errors come back as {"error": "..."} rather than crashing the app.

use crate::{analyze_file, tags};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::Path;

fn arg(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

fn ret(v: Value) -> *mut c_char {
    CString::new(v.to_string()).unwrap_or_default().into_raw()
}

/// Panics must never cross the FFI boundary.
fn guarded(f: impl FnOnce() -> Value + std::panic::UnwindSafe) -> *mut c_char {
    ret(std::panic::catch_unwind(f).unwrap_or_else(|_| json!({"error": "internal error in the analysis engine"})))
}

/// Analyse an audio file: {"bpm", "bpmConfidence", "bpmAlternate", "key", "camelot", "keyStrength", "keyAgreement", "energy", "loudnessLufs", "durationSec"}
#[no_mangle]
pub extern "C" fn wb_analyze(path: *const c_char) -> *mut c_char {
    let path = arg(path);
    guarded(move || match analyze_file(Path::new(&path)) {
        Ok(a) => serde_json::to_value(a).unwrap_or_default(),
        Err(e) => json!({"error": e.to_string()}),
    })
}

/// Read a file's tags: {"title", "artists", "album", "year", "genre", "bpm", "key", "isrc", "hasCover"}
#[no_mangle]
pub extern "C" fn wb_read_tags(path: *const c_char) -> *mut c_char {
    let path = arg(path);
    guarded(move || match tags::read(Path::new(&path)) {
        Ok(t) => serde_json::to_value(t).unwrap_or_default(),
        Err(e) => json!({"error": e.to_string()}),
    })
}

/// Write tags: input {"path", "title", "artists", "album", "year", "genre", "bpm", "key", "isrc", "cover"} → {"ok": true} or {"error"}
#[no_mangle]
pub extern "C" fn wb_write_tags(job: *const c_char) -> *mut c_char {
    let job = arg(job);
    guarded(move || {
        let v: Value = match serde_json::from_str(&job) {
            Ok(v) => v,
            Err(e) => return json!({"error": format!("bad job: {e}")}),
        };
        let path = v["path"].as_str().unwrap_or_default().to_string();
        let t: tags::TrackTags = serde_json::from_value(v).unwrap_or_default();
        match tags::write(Path::new(&path), &t) {
            Ok(()) => json!({"ok": true}),
            Err(e) => json!({"error": e.to_string()}),
        }
    })
}

/// Engine version, so the apps can show it in bug reports.
#[no_mangle]
pub extern "C" fn wb_version() -> *mut c_char {
    ret(json!({"version": env!("CARGO_PKG_VERSION")}))
}

#[no_mangle]
pub extern "C" fn wb_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}
