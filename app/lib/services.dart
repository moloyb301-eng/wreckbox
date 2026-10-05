// Background services: Downloads organiser, Dropbox import, update checks and bug reports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'engine.dart';
import 'paths.dart';
import 'settings.dart';
import 'store.dart';

// MARK: - Downloads organiser

/// Watches the Downloads folder: each new audio file that belongs to your library is analysed, tagged with
/// the Spotify data, renamed and moved into Tracks/. Files that don't match are remembered and left alone.
class DownloadsOrganiser {
  final LibraryStore store;
  Timer? _timer;
  final Set<String> _seen = {};
  bool _loaded = false;
  final List<String> recent = [];

  DownloadsOrganiser(this.store);

  File get _seenFile => File(p.join(AppPaths.cache.path, 'organiser_seen.json'));

  void start({Duration every = const Duration(seconds: 30)}) {
    _timer ??= Timer.periodic(every, (_) => runOnce());
    runOnce();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One pass; returns how many files were filed into the library.
  Future<int> runOnce() async {
    final dir = AppPaths.downloads;
    if (dir == null || store.library == null || store.busy != null || !Settings.current.organiseDownloads) return 0;
    if (!_loaded) {
      try {
        _seen.addAll(List<String>.from(jsonDecode(await _seenFile.readAsString())));
      } catch (_) {}
      _loaded = true;
    }
    if (!await dir.exists()) return 0;
    var filed = 0;
    final files = <File>[];
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File && isAudio(e.path) && !p.basename(e.path).startsWith('.')) files.add(e);
      }
    } catch (_) {
      return 0; // no permission yet
    }
    for (final f in files) {
      final key = '${f.path}|${await f.length()}';
      if (_seen.contains(key) || _seen.contains('$key|${store.library?.builtAt.toIso8601String()}')) continue;
      // Skip files still being written (size changing).
      final size1 = await f.length();
      await Future.delayed(const Duration(milliseconds: 600));
      if (!await f.exists() || await f.length() != size1) continue;
      final msg = await store.organise(f.path, source: 'downloads');
      recent.insert(0, msg);
      if (recent.length > 50) recent.removeLast();
      if (msg.startsWith('Added')) filed++;
      // A file that isn't in the library yet is retried after the next playlist import (key includes the
      // library's build time); anything else is handled once.
      _seen.add(msg.startsWith('Not in your library') ? '$key|${store.library?.builtAt.toIso8601String()}' : key);
    }
    await writeAtomic(_seenFile, jsonEncode(_seen.toList()));
    return filed;
  }
}

// MARK: - Dropbox

/// Pulls new audio files from a Dropbox folder through the organiser. Each user registers a free Dropbox app
/// (scoped, "files.content.read") and pastes its app key — no secret is needed with PKCE.
class Dropbox {
  final LibraryStore store;
  Dropbox(this.store);

  static String _random(int n) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final r = Random.secure();
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }

  bool get connected => Settings.current.dropboxRefreshToken != null;

  Future<void> connect() async {
    final s = Settings.current;
    if (s.dropboxAppKey.trim().isEmpty) throw Exception('Add your Dropbox app key first.');
    final verifier = _random(64);
    final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final url = Uri.https('www.dropbox.com', '/oauth2/authorize', {
      'client_id': s.dropboxAppKey.trim(),
      'response_type': 'code',
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
      'token_access_type': 'offline',
      'redirect_uri': AppConfig.dropboxRedirect,
    });
    final result = Uri.parse(await FlutterWebAuth2.authenticate(url: url.toString(), callbackUrlScheme: 'wreckbox'));
    final code = result.queryParameters['code'];
    if (code == null) throw Exception('Dropbox said: ${result.queryParameters['error'] ?? 'no code'}');
    final res = await http.post(Uri.parse('https://api.dropboxapi.com/oauth2/token'), body: {
      'code': code,
      'grant_type': 'authorization_code',
      'code_verifier': verifier,
      'client_id': s.dropboxAppKey.trim(),
      'redirect_uri': AppConfig.dropboxRedirect,
    });
    final j = jsonDecode(res.body);
    if (j['refresh_token'] == null) throw Exception('Dropbox sign-in failed: ${j['error_description'] ?? res.statusCode}');
    s.dropboxRefreshToken = j['refresh_token'];
    await s.save();
  }

  Future<String> _access() async {
    final s = Settings.current;
    final res = await http.post(Uri.parse('https://api.dropboxapi.com/oauth2/token'),
        body: {'grant_type': 'refresh_token', 'refresh_token': s.dropboxRefreshToken!, 'client_id': s.dropboxAppKey.trim()});
    final j = jsonDecode(res.body);
    if (j['access_token'] == null) throw Exception('Dropbox session expired — connect again.');
    return j['access_token'];
  }

  File get _seenFile => File(p.join(AppPaths.cache.path, 'dropbox_seen.json'));

  /// Downloads new audio files from the chosen folder and files them. `progress(line)`.
  Future<int> pull(void Function(String) progress) async {
    final token = await _access();
    final seen = <String>{};
    try {
      seen.addAll(List<String>.from(jsonDecode(await _seenFile.readAsString())));
    } catch (_) {}
    final entries = <Map<String, dynamic>>[];
    var res = await http.post(Uri.parse('https://api.dropboxapi.com/2/files/list_folder'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode({'path': Settings.current.dropboxFolder == '/' ? '' : Settings.current.dropboxFolder, 'recursive': true}));
    while (true) {
      final j = jsonDecode(res.body);
      if (res.statusCode != 200) throw Exception('Dropbox: ${j['error_summary'] ?? res.statusCode}');
      entries.addAll([for (final e in j['entries'] as List) Map<String, dynamic>.from(e)]);
      if (j['has_more'] != true) break;
      res = await http.post(Uri.parse('https://api.dropboxapi.com/2/files/list_folder/continue'),
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'}, body: jsonEncode({'cursor': j['cursor']}));
    }
    final files = entries.where((e) => e['.tag'] == 'file' && isAudio(e['name']) && !seen.contains(e['rev'])).toList();
    var filed = 0;
    for (var i = 0; i < files.length; i++) {
      final e = files[i];
      progress('Downloading ${i + 1}/${files.length}: ${e['name']}');
      final dl = await http.post(Uri.parse('https://content.dropboxapi.com/2/files/download'),
          headers: {'Authorization': 'Bearer $token', 'Dropbox-API-Arg': jsonEncode({'path': e['id']})});
      if (dl.statusCode != 200) continue;
      await AppPaths.inbox.create(recursive: true);
      final tmp = File(p.join(AppPaths.inbox.path, e['name']));
      await tmp.writeAsBytes(dl.bodyBytes);
      final msg = await store.organise(tmp.path, source: 'dropbox');
      if (msg.startsWith('Added')) filed++;
      seen.add(e['rev']);
    }
    await writeAtomic(_seenFile, jsonEncode(seen.toList()));
    return filed;
  }
}

// MARK: - Updates

class UpdateInfo {
  final String version, notes, url;
  UpdateInfo(this.version, this.notes, this.url);
}

class Updates {
  static Future<String> currentVersion() async => (await PackageInfo.fromPlatform()).version;

  /// Newer release in the public releases repo, with the download for this platform; null if up to date.
  static Future<UpdateInfo?> check() async {
    try {
      final res = await http.get(Uri.parse('https://api.github.com/repos/${AppConfig.releasesRepo}/releases/latest'),
          headers: {'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body);
      final latest = (j['tag_name'] as String? ?? '').replaceFirst('v', '');
      if (!_newer(latest, await currentVersion())) return null;
      final want = Platform.isAndroid ? '.apk' : Platform.isWindows ? 'windows' : 'mac';
      final asset = (j['assets'] as List).cast<Map>().where((a) => (a['name'] as String).toLowerCase().contains(want)).firstOrNull;
      return UpdateInfo(latest, j['body'] ?? '', asset?['browser_download_url'] ?? j['html_url']);
    } catch (_) {
      return null;
    }
  }

  static bool _newer(String a, String b) {
    List<int> parse(String v) => v.split(RegExp(r'[.+-]')).map((x) => int.tryParse(x) ?? 0).toList();
    final x = parse(a), y = parse(b);
    for (var i = 0; i < 3; i++) {
      final xi = i < x.length ? x[i] : 0, yi = i < y.length ? y[i] : 0;
      if (xi != yi) return xi > yi;
    }
    return false;
  }
}

// MARK: - Bug reports

class BugReport {
  /// Sends the report to the relay, which files a GitHub issue (and GitHub emails the owner).
  /// `screenshots`: PNG/JPEG bytes. Returns the issue number or throws with a readable message.
  static Future<int> send({
    required String title,
    required String description,
    required List<(List<int>, String)> screenshots, // (bytes, mime)
    required LibraryStore store,
    List<String> extraLog = const [],
  }) async {
    final info = await PackageInfo.fromPlatform();
    final log = [
      'engine ${await Engine.version()}',
      ...store.state.log.reversed.take(40).map((e) => '${e.date.toIso8601String()} ${e.event}: ${e.detail}'),
      ...extraLog,
    ].join('\n');
    final res = await http
        .post(Uri.parse(AppConfig.bugRelayUrl),
            headers: {'Content-Type': 'application/json', 'X-WreckBox-Key': AppConfig.bugRelayKey},
            body: jsonEncode({
              'title': title,
              'description': description,
              'app': 'WreckBox',
              'version': '${info.version}+${info.buildNumber}',
              'platform': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
              'reporter': Settings.current.reporterName,
              'contact': Settings.current.reporterContact,
              'logs': log,
              'screenshots': [for (final (bytes, mime) in screenshots.take(3)) {'type': mime, 'data': base64Encode(bytes)}],
            }))
        .timeout(const Duration(seconds: 60));
    final j = jsonDecode(res.body);
    if (res.statusCode != 200 || j['ok'] != true) throw Exception(j['error'] ?? 'the report service answered ${res.statusCode}');
    return j['issue'];
  }
}
