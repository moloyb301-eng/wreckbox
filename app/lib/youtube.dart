// YouTube import: the user's YouTube / YouTube Music playlists and liked music videos become library
// playlists ("YT: …"). Video titles are cleaned into artist + title and, when Spotify is connected, matched to
// the Spotify track for proper metadata (ISRC, album, cover) so they merge with the same song from Spotify.
//
// This imports playlist *metadata* only. Audio for missing tracks comes from the usual places (Soulseek on
// the computer, your own downloads, Dropbox, the computer → phone sync).
//
// Each user creates a Google Cloud OAuth client of type "Desktop app" with the YouTube Data API v3 enabled
// (read-only scope). The app signs in through the system browser with a loopback redirect + PKCE.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';
import 'settings.dart';
import 'sources.dart';
import 'spotify.dart';

class YouTubeImport {
  static const scope = 'https://www.googleapis.com/auth/youtube.readonly';

  static String _random(int n) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  // MARK: Auth

  static Future<String> _signIn() async {
    final s = Settings.current;
    if (s.googleClientId.trim().isEmpty) throw Exception('Add your Google client ID in Settings first.');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirect = 'http://127.0.0.1:${server.port}';
    final verifier = _random(64), state = _random(16);
    final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': s.googleClientId.trim(),
      'redirect_uri': redirect,
      'response_type': 'code',
      'scope': scope,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': 'consent',
      'state': state,
    });
    Uri? callback;
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      await for (final req in server.timeout(const Duration(minutes: 5))) {
        if (!req.uri.queryParameters.containsKey('code') && !req.uri.queryParameters.containsKey('error')) {
          req.response.statusCode = 404;
          await req.response.close();
          continue;
        }
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html><body style="font-family:sans-serif;background:#08080a;color:#eee;padding:40px">'
            '<h2>WreckBox is connected to YouTube.</h2><p>You can close this tab and go back to the app.</p></body></html>');
        await req.response.close();
        callback = req.uri;
        break;
      }
    } finally {
      await server.close(force: true);
    }
    if (callback == null) throw Exception('Google sign-in timed out.');
    if (callback.queryParameters['state'] != state) throw Exception('Sign-in was interrupted — try again.');
    final code = callback.queryParameters['code'];
    if (code == null) throw Exception('Google said: ${callback.queryParameters['error']}');
    return _token({'grant_type': 'authorization_code', 'code': code, 'redirect_uri': redirect, 'code_verifier': verifier});
  }

  static Future<String> _token(Map<String, String> body) async {
    final s = Settings.current;
    final res = await http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: {
      ...body,
      'client_id': s.googleClientId.trim(),
      // Google's "Desktop app" clients come with a secret that isn't confidential (Google's own wording);
      // it's still required by the token endpoint.
      if (s.googleClientSecret.trim().isNotEmpty) 'client_secret': s.googleClientSecret.trim(),
    });
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (j['access_token'] == null) throw Exception('Google sign-in failed: ${j['error_description'] ?? j['error'] ?? res.statusCode}');
    if (j['refresh_token'] != null) {
      s.googleRefreshToken = j['refresh_token'];
      await s.save();
    }
    return j['access_token'];
  }

  static Future<String> _access() async {
    final rt = Settings.current.googleRefreshToken;
    if (rt != null) {
      try {
        return await _token({'grant_type': 'refresh_token', 'refresh_token': rt});
      } catch (_) {}
    }
    return _signIn();
  }

  // MARK: API

  static Future<Map<String, dynamic>> _get(String token, String path, Map<String, String> q) async {
    final res = await http.get(Uri.https('www.googleapis.com', '/youtube/v3/$path', q), headers: {'Authorization': 'Bearer $token'});
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      final msg = ((j['error'] as Map?)?['message'] ?? res.statusCode).toString();
      throw Exception(msg.contains('quota') ? 'YouTube daily quota used up — try again tomorrow.' : 'YouTube: $msg');
    }
    return j;
  }

  static Future<List<Map<String, dynamic>>> _pages(String token, String path, Map<String, String> q) async {
    final out = <Map<String, dynamic>>[];
    String? page;
    do {
      final j = await _get(token, path, {...q, 'maxResults': '50', if (page != null) 'pageToken': page});
      out.addAll([for (final i in (j['items'] as List? ?? const [])) Map<String, dynamic>.from(i)]);
      page = j['nextPageToken'];
    } while (page != null);
    return out;
  }

  /// Duration and category for up to 50 videos per request.
  static Future<Map<String, (int?, String?)>> _details(String token, List<String> ids) async {
    final out = <String, (int?, String?)>{};
    for (var i = 0; i < ids.length; i += 50) {
      final batch = ids.sublist(i, min(i + 50, ids.length));
      final j = await _get(token, 'videos', {'part': 'contentDetails,snippet', 'id': batch.join(',')});
      for (final v in (j['items'] as List? ?? const [])) {
        out[v['id']] = (parseIsoDuration(v['contentDetails']?['duration'] ?? ''), v['snippet']?['categoryId']);
      }
    }
    return out;
  }

  // MARK: Title cleanup

  static int? parseIsoDuration(String s) {
    final m = RegExp(r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$').firstMatch(s);
    if (m == null) return null;
    final h = int.tryParse(m.group(1) ?? '') ?? 0, mi = int.tryParse(m.group(2) ?? '') ?? 0, se = int.tryParse(m.group(3) ?? '') ?? 0;
    return ((h * 60 + mi) * 60 + se) * 1000;
  }

  static final _noise = RegExp(
      r'\s*[\(\[\{][^\)\]\}]*(official|video|audio|lyric|visuali[sz]er|music video|mv|hd|4k|hq|explicit|clean|full song|out now|free d(ownload|l)|premiere)[^\)\]\}]*[\)\]\}]',
      caseSensitive: false);

  /// "Artist - Title (Official Video)" / YouTube Music "Artist - Topic" channels → (artists, title).
  static (List<String>, String) parseTitle(String videoTitle, String channel) {
    var title = videoTitle.replaceAll(_noise, '').replaceAll(RegExp(r'\s*\|.*$'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    String artist;
    if (channel.endsWith(' - Topic')) {
      artist = channel.substring(0, channel.length - 8);
    } else {
      final m = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(title);
      if (m != null) {
        artist = m.group(1)!;
        title = m.group(2)!;
      } else {
        artist = channel.replaceAll(RegExp(r'\s*(VEVO|Official|Music)$', caseSensitive: false), '').trim();
      }
    }
    title = title.replaceAll(RegExp(r'^["“]|["”]$'), '').trim();
    final artists = artist.split(RegExp(r'\s*(,|&| x | X | feat\.? | ft\.? )\s*')).map((a) => a.trim()).where((a) => a.isNotEmpty).toList();
    return (artists.isEmpty ? [artist] : artists, title);
  }

  // MARK: Import

  /// Imports playlists + liked music. `log` gets progress lines. Returns the rebuilt library.
  static Future<Library> run(void Function(String) log) async {
    final token = await _access();
    String? spotify;
    if (Settings.current.spotifyRefreshToken != null) {
      try {
        spotify = await SpotifyImport.accessToken();
      } catch (_) {}
    }
    log('Fetching your YouTube playlists…');
    final lists = await _pages(token, 'playlists', {'part': 'snippet', 'mine': 'true'});
    final sources = <SourcePlaylist>[];

    Future<List<SourceTrack>> toTracks(List<(String, String, String, String?)> videos, {bool musicOnly = false}) async {
      // videos: (id, title, channel, addedAt)
      final details = await _details(token, [for (final v in videos) v.$1]);
      final out = <SourceTrack>[];
      for (final (id, title, channel, added) in videos) {
        final (dur, cat) = details[id] ?? (null, null);
        if (title == 'Deleted video' || title == 'Private video') continue;
        if (musicOnly && cat != '10') continue; // category 10 = Music
        final (artists, name) = parseTitle(title, channel);
        SourceTrack? sp;
        if (spotify != null) sp = await SpotifyImport.search(spotify, artists.first, name);
        out.add(sp == null
            ? SourceTrack(youtubeID: id, name: name, artists: artists, durationMs: dur, addedAt: added, artworkURL: 'https://i.ytimg.com/vi/$id/hqdefault.jpg')
            : SourceTrack(
                youtubeID: id, spotifyID: sp.spotifyID, name: sp.name, artists: sp.artists, album: sp.album, releaseDate: sp.releaseDate,
                isrc: sp.isrc, durationMs: sp.durationMs, addedAt: added, artworkURL: sp.artworkURL));
      }
      return out;
    }

    for (final pl in lists) {
      final name = 'YT: ${pl['snippet']?['title'] ?? 'Untitled'}';
      final items = await _pages(token, 'playlistItems', {'part': 'snippet,contentDetails', 'playlistId': pl['id']});
      final videos = [
        for (final i in items)
          (
            (i['contentDetails']?['videoId'] ?? '') as String,
            (i['snippet']?['title'] ?? '') as String,
            (i['snippet']?['videoOwnerChannelTitle'] ?? '') as String,
            i['snippet']?['publishedAt'] as String?, // when it was added to the playlist
          )
      ].where((v) => v.$1.isNotEmpty).toList();
      final tracks = await toTracks(videos);
      log('  $name: ${tracks.length} tracks');
      sources.add(SourcePlaylist(name, pl['id'], false, tracks));
    }

    log('Fetching liked music…');
    final liked = await _pages(token, 'videos', {'part': 'snippet', 'myRating': 'like'});
    final likedTracks = await toTracks([
      for (final v in liked) (v['id'] as String, (v['snippet']?['title'] ?? '') as String, (v['snippet']?['channelTitle'] ?? '') as String, null),
    ], musicOnly: true);
    log('  YT: Liked music: ${likedTracks.length} tracks');
    sources.add(SourcePlaylist('YT: Liked music', 'LL', false, likedTracks));

    final lib = await Sources.save('youtube', '', sources);
    log('Library: ${lib.tracks.length} unique tracks from ${lib.playlists.length} playlists');
    return lib;
  }
}
