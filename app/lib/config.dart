// App-wide constants. Values the owner fills in before a release are marked SET-BEFORE-RELEASE.

class AppConfig {
  static const appName = 'WreckBox';

  /// Public repo the apps check for updates (GitHub Releases). SET-BEFORE-RELEASE.
  static const releasesRepo = 'moloyb301-eng/wreckbox-releases';

  /// Bug-report relay (Cloudflare Worker, see relay/README.md). SET-BEFORE-RELEASE.
  static const bugRelayUrl = 'https://wreckbox-bug-relay.OWNER.workers.dev';

  /// Shared key the relay expects in X-WreckBox-Key (deters casual spam; not a secret). SET-BEFORE-RELEASE.
  static const bugRelayKey = 'CHANGE-ME';

  /// Spotify redirect URIs each user registers in their own Spotify developer app.
  static const spotifyDesktopRedirect = 'http://127.0.0.1:8888/callback';
  static const spotifyMobileRedirect = 'wreckbox://spotify-callback';
  static const spotifyScopes = 'playlist-read-private playlist-read-collaborative user-library-read';

  /// Dropbox redirect for the phone app (registered in the user's Dropbox app).
  static const dropboxRedirect = 'wreckbox://dropbox-callback';

  /// Port the desktop app serves the library to paired phones on.
  static const phoneSyncPort = 47390;
}
