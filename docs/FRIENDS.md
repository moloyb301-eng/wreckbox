# WreckBox — getting started

Download from **https://github.com/moloyb301-eng/wreckbox-releases/releases/latest** — pick the file for your device.

## Install

**Android:** open the `.apk` on your phone. Android asks to allow installs from your browser / Files app — allow it
once. If Play Protect warns about an unknown app: **More details → Install anyway**. Then open WreckBox and tap
**Allow** for file access (it files tracks from Download/ into Music/WreckBox so Rekordbox can find them).

**Windows:** unzip `WreckBox-…-windows-x64.zip` anywhere (e.g. `Documents\WreckBox`) and run `wreckbox.exe`.
If SmartScreen says "Windows protected your PC": **More info → Run anyway**. Allow **private networks** when asked
(needed to send tracks to your phone).

**Mac (Apple Silicon):** unzip, move WreckBox to Applications, then **right-click → Open** the first time.

Your music lives in `Music/WreckBox` (Windows: `C:\Users\<you>\Music\WreckBox`).

## Import your playlists (no accounts or keys needed)

1. **Spotify:** go to **exportify.net**, log in with Spotify, click **Export All** (or export single playlists).
   You get one CSV file per playlist.
2. **YouTube / YouTube Music:** **takeout.google.com** → *Deselect all* → tick **YouTube and YouTube Music** →
   "All YouTube data included" → keep only **playlists** → export. Or use **tunemymusic.com** → pick YouTube →
   **Export to file**.
3. In WreckBox: **Settings → Import playlists → Choose CSV files**, select them all.

Each song is looked up in free music catalogues for its ISRC and cover. A big first import takes a while (about a
song per second); re-importing later is instant, and a playlist with the same name is replaced.

## Everyday use

- **Player:** tap a song's cover to play it. Next / previous follow the list you started from.
- **Phone — Organise:** songs you save to Download/ that are in your playlists are analysed (BPM, key, energy),
  tagged with the right title, artists, album and cover, renamed "Artist - Title" and moved to Music/WreckBox/Tracks.
- **Computer → phone:** on the computer **Sync to phone → Start sharing**; on the phone **Computer → Scan pairing
  code** (or **Enter pairing link**). Pick playlists → Download. Songs that are only on the computer show a Wi-Fi
  icon on the phone — tap the cover to stream them from the computer.
- **Computer — Soulseek:** Settings → Soulseek: pick a username and password (the first login creates the account).
  **Download queue** decides which playlists are fetched first; **Sync results** shows what wasn't found, with retry.
- **Rekordbox:** WreckBox writes BPM, key, ISRC and cover into the files. In Rekordbox select the tracks →
  right-click → **Reload Tag** to see updates.

## Updates

When a new version is out, WreckBox shows **"WreckBox x.y.z is available" → Download**. Install it over the old one —
your library and settings stay.

## Found a bug?

Tap **🐞 / Report a bug**. Say what you did and what happened; a screenshot of the app is attached automatically
and you can add more. Put your name in Settings so the developer knows who to ask.

## Optional: direct Spotify import

Instead of CSV files you can import straight from Spotify, but Spotify only allows this for a developer key whose
owner has **Premium**, and each key works for **up to 5 people** (the owner adds their Spotify emails under the
app's *User Management* on developer.spotify.com). Ask whoever in the group set one up to add you, then paste
that key's Client ID under **Settings → Spotify — direct**.
