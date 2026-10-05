# WreckBox

DJ library manager: your Spotify and YouTube playlists become one library; tracks are found, analysed
(BPM, key, energy), tagged and filed so Rekordbox and other DJ software see the right data.

| | Windows / Mac | Android (companion) |
|---|---|---|
| Spotify + YouTube playlist import | ✓ | ✓ |
| BPM / key / energy analysis | ✓ | ✓ |
| Writes title, artists, album, BPM, key, ISRC, cover into the files | ✓ | ✓ |
| Organises downloads into `Music/WreckBox/Tracks` ("Artist - Title.ext") | ✓ | ✓ (watches Download/) |
| Soulseek sync with download queue, retries, results | ✓ | – |
| Send tracks computer → phone over Wi-Fi (QR pairing) | ✓ (shares) | ✓ (receives) |
| Dropbox import | – | ✓ |
| In-app bug reports with screenshots | ✓ | ✓ |
| Update check | ✓ | ✓ |

## Layout

```
core/      Rust engine (decoding, analysis, tag writing) — shared by every platform, C ABI for Dart
app/       Flutter app (Windows, macOS, Android)
sidecar/   slsk_sync.py — the Soulseek downloader (bundled with an embedded Python on desktop)
relay/     Cloudflare Worker: bug reports → GitHub issues (→ email)
docs/      Friend guide and release guide
.github/   CI: tests, Windows / Mac / Android builds, releases to the public releases repo
```

See [docs/RELEASING.md](docs/RELEASING.md) to publish an update and [docs/FRIENDS.md](docs/FRIENDS.md) for the user guide.

## Development

```sh
cargo test --release --manifest-path core/Cargo.toml          # engine tests
cargo build --release --manifest-path core/Cargo.toml
core/target/release/wbcore compare "$HOME/Music/WreckBox/_cache/analysis.json"   # vs. Essentia results

cd app
WRECKBOX_CORE_LIB=../core/target/release/libwreckbox_core.dylib \
WRECKBOX_TEST_LIBRARY="$HOME/Music/DJ Library" flutter test   # tests run on a COPY of the library
../scripts/build-android-core.sh && flutter build apk --release
```
