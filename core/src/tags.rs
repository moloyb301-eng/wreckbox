//! Reading and writing track tags (title, artists, album, year, genre, BPM, key, ISRC, cover) with Lofty.
//! Mirrors the Mac app's tagger.py: ID3v2.3 for MP3/AIFF/WAV (best Rekordbox compatibility), Vorbis
//! comments for FLAC, MP4 atoms for M4A. Unmanaged tags are kept; files are tagged as a copy and
//! swapped in, so a crash can't leave a half-written track.

use anyhow::{anyhow, Context, Result};
use lofty::config::WriteOptions;
use lofty::picture::{MimeType, Picture, PictureType};
use lofty::prelude::*;
use lofty::probe::Probe;
use lofty::tag::{ItemValue, Tag, TagItem, TagType};
use serde::{Deserialize, Serialize};
use std::path::Path;

#[derive(Deserialize, Serialize, Default, Debug, Clone)]
#[serde(rename_all = "camelCase")]
pub struct TrackTags {
    pub title: Option<String>,
    #[serde(default)]
    pub artists: Vec<String>,
    pub album: Option<String>,
    pub year: Option<String>,
    pub genre: Option<String>,
    pub bpm: Option<f64>,
    /// Musical key as the analyser names it ("A minor") or short form ("Am").
    pub key: Option<String>,
    pub isrc: Option<String>,
    /// Local path to a cover image (JPEG / PNG). Not read back.
    pub cover: Option<String>,
    /// Read back only: whether the file has front-cover art.
    #[serde(default)]
    pub has_cover: bool,
}

/// "A minor" → "Am", "F# major" → "F#" (the form ID3 TKEY and Rekordbox use).
pub fn short_key(k: &str) -> String {
    let mut parts = k.split_whitespace();
    let tonic = parts.next().unwrap_or_default();
    let minor = parts.next().map(|m| m.to_lowercase().starts_with("min")).unwrap_or(false);
    if k.ends_with('m') && !k.contains(' ') { k.to_string() } else { format!("{tonic}{}", if minor { "m" } else { "" }) }
}

pub fn read(path: &Path) -> Result<TrackTags> {
    let tagged = Probe::open(path)?.read().with_context(|| format!("can't read tags of {}", path.display()))?;
    let mut t = TrackTags::default();
    let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) else { return Ok(t) };
    t.title = tag.title().map(|s| s.to_string());
    t.artists = tag.get_strings(&ItemKey::TrackArtist).map(|s| s.to_string()).collect();
    t.album = tag.album().map(|s| s.to_string());
    t.year = tag.get_string(&ItemKey::RecordingDate).or_else(|| tag.get_string(&ItemKey::Year)).map(|s| s.to_string());
    t.genre = tag.genre().map(|s| s.to_string());
    t.bpm = tag.get_string(&ItemKey::Bpm).or_else(|| tag.get_string(&ItemKey::IntegerBpm)).and_then(|s| s.trim().parse().ok());
    t.key = tag.get_string(&ItemKey::InitialKey).map(|s| s.to_string());
    t.isrc = tag.get_string(&ItemKey::Isrc).map(|s| s.to_string());
    t.has_cover = tag.pictures().iter().any(|p| p.pic_type() == PictureType::CoverFront) || !tag.pictures().is_empty();
    Ok(t)
}

fn set_text(tag: &mut Tag, key: ItemKey, value: &Option<String>) {
    if let Some(v) = value.as_ref().filter(|v| !v.trim().is_empty()) {
        tag.insert_text(key, v.trim().to_string());
    }
}

fn apply(tag: &mut Tag, t: &TrackTags, cover: Option<Vec<u8>>) {
    set_text(tag, ItemKey::TrackTitle, &t.title);
    if !t.artists.is_empty() {
        tag.remove_key(&ItemKey::TrackArtist);
        match tag.tag_type() {
            // Vorbis comments hold one ARTIST per artist; ID3v2.3 / MP4 use a single joined value.
            TagType::VorbisComments => {
                for a in &t.artists {
                    tag.push(TagItem::new(ItemKey::TrackArtist, ItemValue::Text(a.clone())));
                }
            }
            TagType::Id3v2 => {
                tag.insert_text(ItemKey::TrackArtist, t.artists.join(" / "));
            }
            _ => {
                tag.insert_text(ItemKey::TrackArtist, t.artists.join(", "));
            }
        }
        tag.insert_text(ItemKey::AlbumArtist, t.artists[0].clone());
    }
    set_text(tag, ItemKey::AlbumTitle, &t.album);
    set_text(tag, ItemKey::RecordingDate, &t.year);
    set_text(tag, ItemKey::Genre, &t.genre);
    if let Some(b) = t.bpm.filter(|b| *b > 0.0) {
        // ID3 TBPM and MP4 tmpo are the "integer BPM" item; Vorbis BPM is the plain one. A tag type
        // silently ignores the key it doesn't support, so set both.
        let v = format!("{}", b.round() as i64);
        tag.insert_text(ItemKey::IntegerBpm, v.clone());
        tag.insert_text(ItemKey::Bpm, v);
    }
    if let Some(k) = t.key.as_ref().filter(|k| !k.is_empty()) {
        tag.insert_text(ItemKey::InitialKey, short_key(k));
    }
    set_text(tag, ItemKey::Isrc, &t.isrc);
    if let Some(data) = cover {
        let mime = if data.starts_with(&[0x89, b'P', b'N', b'G']) { MimeType::Png } else { MimeType::Jpeg };
        tag.remove_picture_type(PictureType::CoverFront);
        tag.push_picture(Picture::new_unchecked(PictureType::CoverFront, Some(mime), Some("Cover".into()), data));
    }
}

fn set_mp4_tempo(path: &Path, bpm: i32) -> Result<()> {
    use lofty::mp4::{Atom, AtomData, AtomIdent, Mp4File};
    use lofty::prelude::AudioFile;
    let mut file = std::fs::OpenOptions::new().read(true).write(true).open(path)?;
    let mut mp4 = Mp4File::read_from(&mut file, lofty::config::ParseOptions::new())?;
    let ilst = match mp4.ilst_mut() {
        Some(i) => i,
        None => return Ok(()),
    };
    ilst.replace_atom(Atom::new(AtomIdent::Fourcc(*b"tmpo"), AtomData::SignedInteger(bpm)));
    drop(file);
    mp4.save_to_path(path, WriteOptions::default())?;
    Ok(())
}

/// Writes `t` into the file at `path` (atomically, via a temporary copy in the same folder).
pub fn write(path: &Path, t: &TrackTags) -> Result<()> {
    let cover = match &t.cover {
        Some(c) if !c.is_empty() => Some(std::fs::read(c).with_context(|| format!("can't read cover {c}"))?),
        _ => None,
    };
    let dir = path.parent().ok_or_else(|| anyhow!("no parent folder"))?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("track");
    let tmp = dir.join(format!(".wreckbox-{}-{}", std::process::id(), name));
    std::fs::copy(path, &tmp).context("can't copy the file for tagging")?;
    let result = (|| -> Result<()> {
        let mut tagged = Probe::open(&tmp)?.read()?;
        let tag_type = tagged.primary_tag_type();
        if tagged.tag(tag_type).is_none() {
            tagged.insert_tag(Tag::new(tag_type));
        }
        let tag = tagged.tag_mut(tag_type).ok_or_else(|| anyhow!("can't create a tag"))?;
        apply(tag, t, cover);
        tag.save_to_path(&tmp, WriteOptions::default().use_id3v23(true))?;
        // MP4 stores BPM as a binary integer atom (tmpo), which the generic tag can't express.
        if tag_type == TagType::Mp4Ilst {
            if let Some(b) = t.bpm.filter(|b| *b > 0.0) {
                set_mp4_tempo(&tmp, b.round() as i32)?;
            }
        }
        // Make sure the result still opens as audio before replacing the original.
        Probe::open(&tmp)?.read().context("file unreadable after tagging")?;
        Ok(())
    })();
    match result {
        Ok(()) => std::fs::rename(&tmp, path).context("can't replace the original file"),
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::short_key;

    #[test]
    fn keys() {
        assert_eq!(short_key("A minor"), "Am");
        assert_eq!(short_key("F# major"), "F#");
        assert_eq!(short_key("Ebm"), "Ebm");
    }
}
