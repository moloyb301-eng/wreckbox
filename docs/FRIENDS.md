# WreckBox — getting started

## Install

**Windows:** unzip `WreckBox-…-windows-x64.zip` anywhere (e.g. `Documents\WreckBox`) and run `wreckbox.exe`.
Windows SmartScreen may say "Windows protected your PC" — click **More info → Run anyway** (the app isn't
signed with a paid certificate). When Windows asks about network access, allow **private networks** (needed to
send tracks to your phone).

**Mac (Apple Silicon):** unzip, move WreckBox to Applications, then **right-click → Open** the first time
(macOS blocks apps from unidentified developers on a normal double-click).

**Android:** open the `.apk` on your phone. Android will ask to allow installing from your browser / files app —
allow it once. Then open WreckBox and allow **All files access** (it needs it to file tracks from Download/ into
Music/WreckBox).

Your music library lives in `Music/WreckBox` (Windows: `C:\Users\<you>\Music\WreckBox`).

## One-time setup

### Spotify (required, ~2 minutes)
Spotify only lets each developer key have a few users, so you make your own (free):

1. Go to <https://developer.spotify.com/dashboard> and log in.
2. **Create app** — any name. Tick **Web API**.
3. Add both Redirect URIs, then save:
   - `http://127.0.0.1:8888/callback`
   - `wreckbox://spotify-callback`
4. Copy the **Client ID** into WreckBox → Settings → Spotify, and click **Import my playlists**.

### YouTube (optional)
1. <https://console.cloud.google.com> → new project → enable **YouTube Data API v3**.
2. **OAuth consent screen**: External; add yourself as a test user; then set publishing status to **In
   production** (otherwise Google signs you out every 7 days). The "unverified app" warning when you sign in is
   expected — it's your own app.
3. **Credentials → Create OAuth client ID → Desktop app**. Paste the Client ID and Client secret into WreckBox →
   Settings → YouTube and click **Import my YouTube playlists**.

YouTube import brings in playlists and liked music (not audio). Songs also on Spotify merge into one entry.

### Soulseek (computer, optional)
Settings → Soulseek: pick a username and password. The first login creates the account. If the name is taken,
choose another. Share your Tracks folder (on by default) — many Soulseek users only upload to people who share.

## Everyday use

- **Rescan & analyse** reads your music folders, links files to your playlists and analyses BPM / key / energy.
- **In my crate → Write tags to files** puts the Spotify title, artists, album, BPM, key and cover into the files.
  In Rekordbox, select the tracks → right-click → **Reload Tag** to see the update.
- **Download queue** decides which playlists Soulseek fetches first.
- **Phone:** downloads saved to Download/ are filed automatically. To copy tracks from your computer: computer →
  **Sync to phone → Start sharing**, phone → **Computer → Scan pairing code**, pick playlists, Download.

## Found a bug?

Use **Report a bug** (sidebar on the computer, 🐞 at the top on the phone). Describe what you did and what
happened; a screenshot of the app is attached automatically and you can add more. Put your name in Settings so
the developer knows who to ask. Updates show up in the app as a banner — click **Download**.
