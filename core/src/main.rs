//! `wbcore` — command-line access to the WreckBox engine.
//!
//!   wbcore analyze FILE…             one JSON line per file
//!   wbcore tags FILE…                read tags as JSON
//!   wbcore fingerprint FILE…         Chromaprint fingerprint as JSON (same as fpcalc -json)
//!   wbcore write-tags < jobs.json    [{"path": …, title, artists, …}] → one JSON result per job
//!   wbcore compare analysis.json     agreement with the Mac app's Essentia results (cache file)

use serde_json::{json, Value};
use std::io::Read;
use std::path::Path;
use wreckbox_core::{analyze_file, fingerprint, tags};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("analyze") => {
            for p in &args[1..] {
                let out = match analyze_file(Path::new(p)) {
                    Ok(a) => json!({"path": p, "result": a}),
                    Err(e) => json!({"path": p, "error": e.to_string()}),
                };
                println!("{out}");
            }
        }
        Some("fingerprint") => {
            for p in &args[1..] {
                let out = match fingerprint::fingerprint(Path::new(p)) {
                    Ok(f) => json!({"path": p, "duration": f.duration, "fingerprint": f.fingerprint}),
                    Err(e) => json!({"path": p, "error": e.to_string()}),
                };
                println!("{out}");
            }
        }
        Some("tags") => {
            for p in &args[1..] {
                let out = match tags::read(Path::new(p)) {
                    Ok(t) => json!({"path": p, "tags": t}),
                    Err(e) => json!({"path": p, "error": e.to_string()}),
                };
                println!("{out}");
            }
        }
        Some("write-tags") => {
            let mut input = String::new();
            std::io::stdin().read_to_string(&mut input).expect("stdin");
            let jobs: Vec<Value> = serde_json::from_str(&input).expect("a JSON array of jobs");
            for job in jobs {
                let path = job["path"].as_str().unwrap_or_default().to_string();
                let t: tags::TrackTags = serde_json::from_value(job).unwrap_or_default();
                let out = match tags::write(Path::new(&path), &t) {
                    Ok(()) => json!({"path": path, "ok": true}),
                    Err(e) => json!({"path": path, "ok": false, "error": e.to_string()}),
                };
                println!("{out}");
            }
        }
        Some("compare") => compare(args.get(1).map(String::as_str).unwrap_or("analysis.json"), args.get(2).and_then(|n| n.parse().ok())),
        _ => eprintln!("usage: wbcore analyze|tags FILE… | write-tags < jobs.json | compare analysis.json [limit]"),
    }
}

/// Compares this engine with the Essentia results stored in the Mac app's analysis cache.
fn compare(cache: &str, limit: Option<usize>) {
    let text = std::fs::read_to_string(cache).expect("analysis cache");
    let map: serde_json::Map<String, Value> = serde_json::from_str(&text).expect("JSON object");
    let mut rows: Vec<(&String, &Value)> = map
        .iter()
        .filter(|(p, v)| v["engine"] == "essentia" && v["durationSec"].as_f64().unwrap_or(0.0) > 60.0 && Path::new(p).exists())
        .collect();
    rows.sort_by_key(|r| r.0.clone());
    if let Some(n) = limit {
        rows.truncate(n);
    }
    let (mut n, mut bpm_ok, mut bpm_oct, mut key_exact, mut key_close) = (0, 0, 0, 0, 0);
    for (path, ess) in rows {
        let Ok(ours) = analyze_file(Path::new(path)) else { continue };
        n += 1;
        let (eb, ob) = (ess["bpm"].as_f64().unwrap_or(0.0), ours.bpm.unwrap_or(0.0));
        let close = |a: f64, b: f64| (a - b).abs() / a.max(1.0) < 0.02;
        if close(eb, ob) {
            bpm_ok += 1;
        } else if close(eb, ob * 2.0) || close(eb, ob / 2.0) {
            bpm_oct += 1;
        }
        let (ek, ok) = (ess["camelot"].as_str().unwrap_or(""), ours.camelot.clone().unwrap_or_default());
        if ek == ok {
            key_exact += 1;
        } else if neighbours(ek, &ok) {
            key_close += 1;
        }
        println!("{:>6.1} {:>6.1}  {:>4} {:>4}  {}", eb, ob, ek, ok, Path::new(path).file_name().unwrap().to_string_lossy());
    }
    let pct = |x: i32| if n == 0 { 0.0 } else { 100.0 * x as f64 / n as f64 };
    println!("\n{n} tracks — BPM same: {:.0}%  (+ half/double: {:.0}%) | key same: {:.0}%  (+ adjacent/relative: {:.0}%)",
             pct(bpm_ok), pct(bpm_ok + bpm_oct), pct(key_exact), pct(key_exact + key_close));
}

/// Same number ±1 with the same letter, or the relative major/minor.
fn neighbours(a: &str, b: &str) -> bool {
    let parse = |c: &str| -> Option<(i32, char)> { Some((c[..c.len() - 1].parse().ok()?, c.chars().last()?)) };
    let (Some((n1, l1)), Some((n2, l2))) = (parse(a), parse(b)) else { return false };
    (l1 == l2 && ((n1 - n2).rem_euclid(12) == 1 || (n2 - n1).rem_euclid(12) == 1)) || (n1 == n2 && l1 != l2)
}
