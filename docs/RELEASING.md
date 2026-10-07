# Releasing WreckBox

## One-time setup

1. **Repos**
   - `wreckbox` (public): this code.
   - `wreckbox-bugs` (private): bug reports from the apps (issues + screenshots), so friends' details stay private.
   - `wreckbox-releases` (public): only release files. The apps check its latest release for updates.
2. **App config** — `app/lib/config.dart`: set `releasesRepo`, `bugRelayUrl`, `bugRelayKey`.
3. **GitHub Actions secrets / variables** (private repo → Settings → Secrets and variables → Actions):
   - `ANDROID_KEYSTORE_B64`: `base64 -i secrets/wreckbox-release.jks | pbcopy`
   - `ANDROID_KEY_PASSWORD`: the password in `app/android/key.properties`
   - `RELEASES_TOKEN`: fine-grained token, repository `wreckbox-releases`, Contents: read & write
   - variable `RELEASES_REPO`: `yourname/wreckbox-releases`
4. **Bug-report relay** (Cloudflare, free):
   ```sh
   cd relay
   npx wrangler login
   # set GITHUB_REPO in wrangler.toml to yourname/wreckbox-bugs
   npx wrangler secret put GITHUB_TOKEN   # fine-grained token, repo wreckbox-bugs: Issues + Contents read & write
   npx wrangler secret put APP_KEY        # any random string; same value as bugRelayKey in config.dart
   npx wrangler deploy                    # prints https://wreckbox-bug-relay.<you>.workers.dev
   ```
   GitHub emails you about new issues (Settings → Notifications → "Issues" on for watched repos; watch the repo).

**Back up `secrets/wreckbox-release.jks` and `app/android/key.properties`** somewhere safe (password manager,
encrypted drive). If they're lost, phones can't install updates over the existing app — everyone would have to
uninstall (losing settings) and reinstall.

## Publishing an update

1. Bump `version:` in `app/pubspec.yaml` (e.g. `0.2.0+2` — the number after `+` must go up for Android).
2. Commit, then tag and push:
   ```sh
   git tag v0.2.0 && git push origin main v0.2.0
   ```
3. GitHub Actions runs the tests, builds Android and Windows and publishes release vX.Y.Z to `wreckbox-releases`.
   Phones see "WreckBox X.Y.Z is available" when the app opens.

**Mac updates ship separately** (only when the Mac app changed), from the `wreckbox-mac` repo:
`scripts/release-mac.sh 0.6.1` packages the app, tags `mac-v0.6.1` and publishes it to `wreckbox-releases` (not
marked "latest", so phones aren't affected). Macs see the update within 30 minutes. When both changed, do both.

**The one link for friends:** https://wreckbox-api.moloyb301.workers.dev/download — always shows the newest Mac
and newest Android download, wherever each was released (refreshes every 5 minutes).

Building locally instead: `scripts/build-android-core.sh && (cd app && flutter build apk --release)`; Windows and
Mac builds need those systems (or CI).

## Why not the Play Store / auto-installing updates?

Sideloaded APKs + an in-app update banner keep things free and simple for a group of friends. If the group grows,
the Play Store (one-time $25) gives automatic updates; Windows builds could be code-signed (~$100/yr) to remove
the SmartScreen warning.
