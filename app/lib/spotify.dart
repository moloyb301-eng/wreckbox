// Spotify import: PKCE sign-in with the user's own client id (Spotify limits each developer app to a
// handful of users, so every WreckBox user registers their own), then Liked Songs + their playlists,
// built into library.json the same way as the Mac app.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';
import 'models.dart';
import 'settings.dart';
import 'sources.dart';

class SpotifyException implements Exception {
  final String message;
  SpotifyException(this.message);
  @override
  String toString() => message;
}

class SpotifyImport {
  static String get redirect => Platform.isAndroid || Platform.isIOS ? AppConfig.spotifyMobileRedirect : AppConfig.spotifyDesktopRedirect;

  // MARK: Auth

  static String _random(int n) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  /// Opens Spotify's sign-in page and returns an access token (stores the refresh token).
  static Future<String> signIn() async {
    final s = Settings.current;
    if (s.spotifyClientId.trim().isEmpty) throw SpotifyException('Add your Spotify client ID in Settings first.');
    final verifier = _random(64);
    final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final state = _random(16);
    final url = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': s.spotifyClientId.trim(),
      'response_type': 'code',
      'redirect_uri': redirect,
      'scope': AppConfig.spotifyScopes,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'state': state,
    });
    final Uri callback;
    if (Platform.isAndroid || Platform.isIOS) {
      callback = Uri.parse(await FlutterWebAuth2.authenticate(url: url.toString(), callbackUrlScheme: 'wreckbox'));
    } else {
      callback = await _loopback(url);
    }
    if (callback.queryParameters['state'] != state) throw SpotifyException('Sign-in was interrupted — try again.');
    final code = callback.queryParameters['code'];
    if (code == null) throw SpotifyException('Spotify said: ${callback.queryParameters['error'] ?? 'no code'}');
    return _token({'grant_type': 'authorization_code', 'code': code, 'redirect_uri': redirect, 'code_verifier': verifier});
  }

  /// Desktop: listen on 127.0.0.1:8888 for the redirect while the browser handles sign-in.
  static Future<Uri> _loopback(Uri authUrl) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8888);
    try {
      await launchUrl(authUrl, mode: LaunchMode.externalApplication);
      await for (final req in server.timeout(const Duration(minutes: 5))) {
        if (req.uri.path != '/callback') {
          req.response.statusCode = 404;
          await req.response.close();
          continue;
        }
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html><body style="font-family:sans-serif;background:#08080a;color:#eee;padding:40px">'
            '<h2>WreckBox is connected to Spotify.</h2><p>You can close this tab.</p></body></html>');
        await req.response.close();
        return req.uri;
      }
      throw SpotifyException('Sign-in timed out.');
    } finally {
      await server.close(force: true);
    }
  }

  static Future<String> _token(Map<String, String> body) async {
    final s = Settings.current;
    final res = await http.post(Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: {...body, 'client_id': s.spotifyClientId.trim()});
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200 || j['access_token'] == null) {
      throw SpotifyException('Spotify sign-in failed: ${j['error_description'] ?? j['error'] ?? res.statusCode}');
    }
    if (j['refresh_token'] != null) {
      s.spotifyRefreshToken = j['refresh_token'];
      await s.save();
    }
    return j['access_token'];
  }

  /// Access token from the saved refresh token, or a fresh sign-in.
  static Future<String> accessToken() async {
    final rt = Settings.current.spotifyRefreshToken;
    if (rt != null) {
      try {
        return await _token({'grant_type': 'refresh_token', 'refresh_token': rt});
      } catch (_) {
        // expired or revoked → sign in again
      }
    }
    return signIn();
  }

  // MARK: API

  static Future<Map<String, dynamic>> _get(String token, String pathOrUrl) async {
    final url = pathOrUrl.startsWith('http') ? Uri.parse(pathOrUrl) : Uri.parse('https://api.spotify.com/v1/$pathOrUrl');
    for (var attempt = 0; attempt < 5; attempt++) {
      final res = await http.get(url, headers: {'Authorization': 'Bearer $token'});
      if (res.statusCode == 429) {
        await Future.delayed(Duration(seconds: int.tryParse(res.headers['retry-after'] ?? '') ?? 2));
        continue;
      }
      if (res.statusCode != 200) throw SpotifyException('Spotify API ${res.statusCode} for $pathOrUrl');
      return jsonDecode(res.body);
    }
    throw SpotifyException('Spotify kept rate-limiting; try again in a minute.');
  }

  static Future<List<Map<String, dynamic>>> _pages(String token, String path) async {
    final items = <Map<String, dynamic>>[];
    String? next = path;
    while (next != null) {
      final page = await _get(token, next);
      items.addAll([for (final i in (page['items'] as List? ?? const [])) Map<String, dynamic>.from(i)]);
      next = page['next'];
    }
    return items;
  }

  static SourceTrack? _parse(Map<String, dynamic> item) => parseTrack((item['track'] ?? item['item']) as Map<String, dynamic>?, item['added_at']);

  static SourceTrack? parseTrack(Map<String, dynamic>? t, [String? addedAt]) {
    if (t == null || (t['type'] ?? 'track') != 'track') return null;
    final album = t['album'] as Map<String, dynamic>?;
    String? cover;
    final images = album?['images'] as List?;
    if (images != null && images.isNotEmpty) {
      images.sort((a, b) => ((a['width'] ?? 640) - 300).abs().compareTo(((b['width'] ?? 640) - 300).abs()));
      cover = images.first['url'];
    }
    return SourceTrack(
      spotifyID: t['id'],
      name: t['name'] ?? '',
      artists: [for (final a in (t['artists'] as List? ?? const [])) a['name'] as String],
      album: album?['name'],
      releaseDate: album?['release_date'],
      isrc: (t['external_ids'] as Map?)?['isrc'],
      durationMs: t['duration_ms'],
      isLocal: t['is_local'] ?? false,
      addedAt: addedAt,
      artworkURL: cover,
    );
  }

  /// Best Spotify match for an artist + title (used to give YouTube imports proper metadata).
  static Future<SourceTrack?> search(String token, String artist, String title) async {
    final q = artist.isEmpty ? title : 'track:$title artist:$artist';
    try {
      final j = await _get(token, 'search?type=track&limit=5&q=${Uri.encodeQueryComponent(q)}');
      final items = [for (final i in ((j['tracks'] as Map?)?['items'] as List? ?? const [])) Map<String, dynamic>.from(i)];
      final want = normalized(title);
      for (final it in items) {
        final st = parseTrack(it);
        if (st == null) continue;
        final got = normalized(st.name);
        final artistOk = artist.isEmpty || st.artists.any((a) => normalized(artist).contains(normalized(a)) || normalized(a).contains(normalized(artist)));
        if (artistOk && (got == want || got.startsWith(want) || want.startsWith(got))) return st;
      }
    } catch (_) {}
    return null;
  }

  /// Full import → library.json. `log` receives progress lines.
  static Future<Library> run(void Function(String) log) async {
    final token = await accessToken();
    final me = await _get(token, 'me');
    final userID = me['id'] ?? '';
    log('Signed in as ${me['display_name'] ?? userID}');
    log('Fetching Liked Songs…');
    final liked = (await _pages(token, 'me/tracks?limit=50')).map(_parse).whereType<SourceTrack>().toList();
    log('  ${liked.length} liked songs');
    final sources = <SourcePlaylist>[SourcePlaylist('Liked Songs', null, false, liked)];
    for (final p in await _pages(token, 'me/playlists?limit=50')) {
      final owner = p['owner'] as Map? ?? const {};
      final mine = owner['id'] == userID, collab = p['collaborative'] == true;
      if (!(mine || collab)) continue; // personal playlists only (Spotify blocks reading others' anyway)
      List<Map<String, dynamic>> items;
      try {
        items = await _pages(token, 'playlists/${p['id']}/items?limit=50');
      } catch (_) {
        try {
          items = await _pages(token, 'playlists/${p['id']}/tracks?limit=50');
        } catch (e) {
          log('  skipped ${p['name']}: $e');
          continue;
        }
      }
      final name = (p['name'] as String? ?? '').trim();
      final tracks = items.map(_parse).whereType<SourceTrack>().toList();
      log('  $name: ${tracks.length} tracks');
      sources.add(SourcePlaylist(name, p['id'] as String?, collab, tracks));
    }
    final lib = await Sources.save('spotify', userID, sources);
    log('Library: ${lib.tracks.length} unique tracks from ${lib.playlists.length} playlists');
    return lib;
  }

}
