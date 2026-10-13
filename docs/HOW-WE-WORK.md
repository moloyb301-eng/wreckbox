# How we work on WreckBox

A short guide for the owner (not a coder) and anyone helping. Claude follows it too.

## The repos

| Repo | Public? | What's in it |
|---|---|---|
| `wreckbox` (this one) | public | Engine (`core/`), WreckBox app for Windows / macOS / Android (`app/`), WreckBox Player (`player/`), account server (`api/`), bug relay (`relay/`), Soulseek downloader (`sidecar/`) |
| `wreckbox-mac` | public | The Mac app (Swift) |
| `wreckbox-releases` | public | Download files only — the apps check it for updates. Its `windows-native` branch holds the native Windows app, worked on separately; leave it alone. |
| `wreckbox-home`, `wreckbox-car` | private | Raspberry Pi players |
| `wreckbox-bugs` | private | Bug reports sent from the apps |

## Branches: `main` is always the released, working version

Never change `main` directly. Every change goes like this:

1. **A branch per change**, named by what it is:
   - `fix/…` something broken — `fix/duplicate-track-files`
   - `feature/…` something new — `feature/playlist-folders`
   - `optimise/…` faster or cleaner, same behaviour — `optimise/rescan-speed`
   - `chore/…` housekeeping — `chore/repo-setup`
2. **A pull request** (PR) from that branch into `main`. The PR page shows exactly what changed and runs the
   tests. This is also what code reviews (`/code-review`, and `/code-review ultra`) look at.
3. **Merge** when the tests pass and the review is fine. Then delete the branch (GitHub offers a button).

One branch = one topic. Small PRs get better reviews than huge ones.

## Issues and the roadmap

Every bug, idea and improvement is an **issue** in the repo it belongs to. Labels say what and where:

- **What:** `bug`, `feature`, `optimisation`, `security`, `documentation`
- **Where:** `area: engine`, `area: desktop`, `area: android`, `area: player`, `area: server`, `area: soulseek`,
  `area: sync` (and `area: mac` in `wreckbox-mac`)

A PR that fixes an issue says `Fixes #12` in its description, so merging it closes the issue.

Security problems in public repos are **not** filed as public issues: they go to the repo's
Security → Advisories (private drafts only the owner sees) until they're fixed.

## Versions and releases

Each app has its own version and its own tag prefix. Tags are made on the commit that was released, in the code
repo, and the release with the same tag is published in `wreckbox-releases`:

| App | Version lives in | Tag | Released how |
|---|---|---|---|
| WreckBox (Windows + Android) | `app/pubspec.yaml` | `v0.6.2` | push the tag → GitHub Actions builds and publishes (see [RELEASING.md](RELEASING.md)) |
| WreckBox for Mac | `wreckbox-mac` | `mac-v0.6.2` | `scripts/release-mac.sh` in `wreckbox-mac` |
| WreckBox Player | `player/app/build.gradle.kts` (`versionName`, and `versionCode` +1) | `player-v0.3.1` | built and published by hand / Claude |
| WreckBox Home (Pi) | `wreckbox-home` | `home-v…` | its own signed update channel |

Version numbers: `MAJOR.MINOR.PATCH` — bump PATCH for fixes (0.6.**2**), MINOR for new features (0.**7**.0).

**Don't rename existing tags or the prefixes** — the apps' update checks rely on them.

## Licence

The code is MIT-licensed ([LICENSE](../LICENSE)): anyone may use or change it as long as they keep the copyright
notice.
