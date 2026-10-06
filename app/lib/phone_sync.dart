// Computer → phone library sync: over the local network, or from anywhere through the computer's tunnel.
//
// Desktop: serves the crate (tracks you have, with their analysis) on port 47390. Every request must carry
// the pairing token shown in the QR code, so only phones you paired can browse or download.
// Phone: scans the QR code, lists the computer's playlists, downloads the chosen tracks straight into its
// own Tracks/ folder (already tagged and analysed on the computer).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'account.dart';
import 'config.dart';
import 'models.dart';
import 'player.dart';
import 'remote_playback.dart';
import 'paths.dart';
import 'settings.dart';
import 'store.dart';
import 'ui/account_ui.dart' show AccountConnect;

class PhoneSyncServer {
  /// The sync port (WRECKBOX_SYNC_PORT overrides it, e.g. to test next to another WreckBox).
  static int get port => int.tryParse(Platform.environment['WRECKBOX_SYNC_PORT'] ?? '') ?? AppConfig.phoneSyncPort;
  final LibraryStore store;
  HttpServer? _server;
  PhoneSyncServer(this.store);

  bool get running => _server != null;

  static String _newToken() {
    final r = Random.secure();
    return base64Url.encode(List.generate(18, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  String get token {
    final s = Settings.current;
    if (s.desktopPairToken == null) {
      s.desktopPairToken = _newToken();
      s.save();
    }
    return s.desktopPairToken!;
  }

  /// Revokes every paired phone.
  Future<void> resetToken() async {
    Settings.current.desktopPairToken = _newToken();
    await Settings.current.save();
  }

  /// This computer's private-network IPv4 addresses (what a phone on the same Wi-Fi can reach).
  static Future<List<String>> localAddresses() async {
    final out = <String>[];
    for (final ni in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in ni.addresses) {
        final ip = a.address;
        if (ip.startsWith('192.168.') || ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) out.add(ip);
      }
    }
    return out;
  }

  Future<String> pairingUri() async {
    final ips = await localAddresses();
    return 'wreckbox://pair?hosts=${ips.join(',')}&port=$port&t=$token';
  }

  Future<void> start() async {
    if (_server != null) return;
    final r = Router()
      ..get('/info', (Request _) => _json({'name': 'WreckBox on ${Platform.localHostname}', 'tracks': store.count(TrackStatus.downloaded)}))
      ..get('/library.json', (Request _) async => Response.ok(await AppPaths.libraryFile.readAsString(), headers: {'content-type': 'application/json'}))
      ..get('/crate', (Request _) => _json(_crate()))
      ..get('/file/<id>', (Request req, String id) => _file(Uri.decodeComponent(id), req.headers['range']))
      ..get('/art/<id>', (Request req, String id) async {
        final t = store.track(Uri.decodeComponent(id));
        final f = t == null ? null : await store.ensureArtwork(t);
        return f == null ? Response.notFound('') : Response.ok(f.openRead(), headers: {'content-type': 'image/jpeg'});
      });
    final handler = const Pipeline().addMiddleware(_auth()).addHandler(r.call);
    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Middleware _auth() => (inner) => (req) {
        final given = req.headers['x-wreckbox-token'] ?? req.url.queryParameters['t'];
        if (given != token) return Response.forbidden('not paired');
        return inner(req);
      };

  Response _json(Object o) => Response.ok(jsonEncode(o), headers: {'content-type': 'application/json'});

  List<Map<String, dynamic>> _crate() {
    final out = <Map<String, dynamic>>[];
    for (final t in store.library?.tracks ?? const <LibraryTrack>[]) {
      final st = store.state.tracks[t.id];
      final path = st?.localPath;
      if (st?.status != TrackStatus.downloaded || path == null || !File(path).existsSync()) continue;
      out.add({
        'id': t.id,
        'ext': p.extension(path).toLowerCase(),
        'size': File(path).lengthSync(),
        'analysis': store.analysis[path]?.toJson(),
      });
    }
    return out;
  }

  /// Serves a track; honours "Range: bytes=a-b" so the phone's player can seek while streaming.
  Future<Response> _file(String id, String? range) async {
    final path = store.state.tracks[id]?.localPath;
    if (path == null || !await File(path).exists()) return Response.notFound('no such track');
    final f = File(path);
    final len = await f.length();
    final type = _mime(path);
    final m = range == null ? null : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
    if (m != null && (m.group(1)!.isNotEmpty || m.group(2)!.isNotEmpty)) {
      var start = int.tryParse(m.group(1)!) ?? (len - (int.tryParse(m.group(2)!) ?? 0));
      var end = m.group(1)!.isEmpty ? len - 1 : (int.tryParse(m.group(2)!) ?? len - 1);
      if (end >= len) end = len - 1;
      if (start < 0) start = 0;
      if (start > end) return Response(416, headers: {'content-range': 'bytes */$len'});
      return Response(206, body: f.openRead(start, end + 1), headers: {
        'content-type': type,
        'content-length': '${end - start + 1}',
        'content-range': 'bytes $start-$end/$len',
        'accept-ranges': 'bytes',
      });
    }
    return Response.ok(f.openRead(), headers: {'content-type': type, 'content-length': '$len', 'accept-ranges': 'bytes'});
  }

  static String _mime(String path) => switch (p.extension(path).toLowerCase()) {
        '.flac' => 'audio/flac',
        '.mp3' => 'audio/mpeg',
        '.m4a' || '.aac' || '.alac' => 'audio/mp4',
        '.wav' => 'audio/wav',
        '.aif' || '.aiff' => 'audio/aiff',
        '.ogg' || '.opus' => 'audio/ogg',
        _ => 'application/octet-stream',
      };
}

/// Phone side. Talks to the paired computer — on the same Wi-Fi directly, or from anywhere through its tunnel —
/// keeps a live connection for instant updates (new tracks, request progress), downloads in the chosen quality,
/// and asks the computer to find tracks it doesn't have yet.
class PhoneSyncClient extends ChangeNotifier {
  static PhoneSyncClient? instance; // the phone's client, for track sheets
  final LibraryStore store;
  PhoneSyncClient(this.store) {
    instance = this;
  }

  /// What the computer has: id → {id, ext, size, analysis}. Null until the first load.
  Map<String, Map<String, dynamic>>? crateById;
  /// Requests in progress: track id → searching / not_found / failed / ready.
  final Map<String, String> requests = {};
  bool live = false; // the events stream is connected
  String? lastError;

  static const qualities = {'flac': 'FLAC (original)', 'high': 'High · 256k', 'med': 'Medium · 160k', 'low': 'Low · 96k'};

  static Map<String, String>? parsePairing(String raw) {
    final u = Uri.tryParse(raw);
    if (u == null || u.scheme != 'wreckbox' || u.host != 'pair') return null;
    final t = u.queryParameters['t'], port = u.queryParameters['port'] ?? '${AppConfig.phoneSyncPort}';
    final hosts = (u.queryParameters['hosts'] ?? '').split(',').where((h) => h.isNotEmpty).toList();
    final link = u.queryParameters['link'], computer = u.queryParameters['computer'];
    if (t == null || (hosts.isEmpty && link == null)) return null;
    return {
      'hosts': hosts.join(','), 'port': port, 't': t,
      // A signed-in computer adds a one-time code that signs this phone in to the same account.
      if (link != null) 'link': link,
      if (computer != null) 'computer': computer,
    };
  }

  /// Credentials go in headers only. Older computers read X-WreckBox-Token; newer ones Authorization.
  static Map<String, String> authHeaders([String? token]) {
    final t = token ?? Settings.current.pairToken ?? '';
    return {'authorization': 'Bearer $t', 'x-wreckbox-token': t};
  }

  /// Tries each address from the QR code and keeps the first that answers.
  static Future<String?> pair(Map<String, String> info) async {
    for (final h in info['hosts']!.split(',')) {
      final base = 'http://$h:${info['port']}';
      try {
        final r = await http.get(Uri.parse('$base/info'), headers: authHeaders(info['t'])).timeout(const Duration(seconds: 4));
        if (r.statusCode == 200) {
          Settings.current
            ..pairedDesktop = base
            ..remoteDesktop = null
            ..pairToken = info['t']
            ..ticketExpires = 0
            ..connectedComputerId = null;
          await Settings.current.save();
          return base;
        }
      } catch (_) {}
    }
    return null;
  }

  /// Connected through the account: use the computer's home-network address when this phone can reach it
  /// (faster, and nothing goes through the internet), otherwise its tunnel.
  static Future<void> preferLan() async {
    final s = Settings.current;
    final remote = s.remoteDesktop;
    if (remote == null || s.pairToken == null) return;
    try {
      final r = await http.get(Uri.parse('$remote/info'), headers: authHeaders()).timeout(const Duration(seconds: 8));
      final info = jsonDecode(r.body) as Map<String, dynamic>;
      for (final ip in List<String>.from(info['lan'] ?? const [])) {
        final base = 'http://$ip:${info['port'] ?? AppConfig.phoneSyncPort}';
        try {
          final l = await http.get(Uri.parse('$base/info'), headers: authHeaders()).timeout(const Duration(milliseconds: 1500));
          if (l.statusCode == 200) {
            s.pairedDesktop = base;
            await s.save();
            return;
          }
        } catch (_) {}
      }
    } catch (_) {}
    s.pairedDesktop = remote;
    await s.save();
  }

  Map<String, String> get _headers => authHeaders();
  /// The computer over a direct Wi-Fi link while one is open (direct_link.dart), else the paired address.
  String? directBase;
  String? get base => directBase ?? Settings.current.pairedDesktop;

  /// On Wi-Fi the Wi-Fi quality, on mobile data the mobile one.
  static Future<String> streamQuality() async {
    final c = await Connectivity().checkConnectivity();
    final s = Settings.current;
    return c.contains(ConnectivityResult.wifi) || c.contains(ConnectivityResult.ethernet) ? s.qualityWifi : s.qualityMobile;
  }

  Future<Map<String, dynamic>> info() async =>
      jsonDecode((await http.get(Uri.parse('$base/info'), headers: _headers).timeout(const Duration(seconds: 8))).body);

  /// Use the computer's Spotify library on the phone (no separate Spotify setup needed).
  Future<void> adoptLibrary() async {
    final r = await http.get(Uri.parse('$base/library.json'), headers: _headers);
    if (r.statusCode != 200) throw Exception('computer said ${r.statusCode}');
    await writeAtomic(AppPaths.libraryFile, r.body);
    await store.load();
  }

  /// The computer's library changed (new playlists or tracks from its Spotify sync): take it, so playlists here
  /// match. `builtAt` from the event saves a download when nothing changed.
  Future<void> _refreshLibrary({String? builtAt}) async {
    final mine = store.library?.builtAt;
    final theirs = builtAt == null ? null : DateTime.tryParse(builtAt);
    if (mine != null && theirs != null && !theirs.isAfter(mine)) return;
    try {
      await adoptLibrary();
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> crate() async {
    final r = await http.get(Uri.parse('$base/crate'), headers: _headers).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('computer said ${r.statusCode}');
    final list = List<Map<String, dynamic>>.from(jsonDecode(r.body));
    crateById = {for (final c in list) c['id'] as String: c};
    Player.instance.remoteIds = crateById!.keys.toSet(); // these can stream to the phone
    notifyListeners();
    return list;
  }

  // MARK: live updates

  bool _wantLive = false, _polling = false;
  int _seq = -1, _failures = 0;
  http.Client? _pollClient;

  /// Long-polls the computer for news (new tracks, request progress): each call returns as soon as something
  /// happens, or after ~25 s with nothing. Works on Wi-Fi and through the tunnel, which can't hold a stream open.
  Future<void> startLive() async {
    _wantLive = true;
    if (_polling || base == null) return;
    _polling = true;
    _pollClient = http.Client();
    try {
      while (_wantLive) {
        try {
          if (_seq < 0) {
            await crate(); // catch up on anything missed while disconnected
            _seq = (await _poll(-1))['seq'] as int;
            unawaited(_autoSync());
            unawaited(_refreshLibrary());
            unawaited(PlaybackSync.instance.fetch());
          }
          final j = await _poll(_seq);
          if (!live) {
            live = true;
            notifyListeners();
          }
          _failures = 0;
          if (j['reset'] == true) {
            _seq = -1; // the computer restarted or we fell behind: reload
            continue;
          }
          for (final e in List<Map<String, dynamic>>.from(j['events'] ?? const [])) {
            _onEvent(e['event'] as String, e['data']);
          }
          _seq = j['seq'] as int;
        } catch (e) {
          lastError = '$e';
          if (live) {
            live = false;
            notifyListeners();
          }
          _seq = -1;
          final wait = Duration(seconds: min(60, 2 << min(_failures++, 5)));
          await Future.delayed(wait);
          // The computer's address may have changed (restart) or the ticket run out: ask the account again.
          if (_wantLive && Account.signedIn && Settings.current.connectedComputerId != null) {
            try {
              await AccountConnect.refreshIfNeeded();
              if (_failures > 1) await AccountConnect.reconnect();
            } catch (_) {}
          }
        }
      }
    } finally {
      _polling = false;
      _pollClient?.close();
      _pollClient = null;
    }
  }

  Future<Map<String, dynamic>> _poll(int after) async {
    final r = await _pollClient!
        .get(Uri.parse('$base/poll?after=$after'), headers: _headers)
        .timeout(const Duration(seconds: 40));
    if (r.statusCode != 200) throw Exception('computer said ${r.statusCode}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  void stopLive() {
    _wantLive = false;
    _pollClient?.close(); // ends a waiting poll
    live = false;
    notifyListeners();
  }

  void _onEvent(String event, dynamic j) {
    switch (event) {
      case 'crate':
        final map = crateById ??= {};
        final upgraded = <Map<String, dynamic>>[];
        for (final a in List<Map<String, dynamic>>.from(j['added'] ?? const [])) {
          final id = a['id'] as String;
          // The computer has a new file for a track this phone copied in the original quality (e.g. it found the
          // FLAC): bring the better one over.
          final st = store.state.tracks[id], local = st?.localPath;
          if (map.containsKey(id) && st?.status == TrackStatus.downloaded && st?.source == 'phone-sync' && local != null &&
              Settings.current.downloadQuality == 'flac' && File(local).existsSync() && File(local).lengthSync() != a['size']) {
            upgraded.add(a);
          }
          map[id] = a;
        }
        if (upgraded.isNotEmpty) unawaited(download(upgraded, (_, _, _) {}));
        for (final r in List<String>.from(j['removed'] ?? const [])) {
          map.remove(r);
        }
        Player.instance.remoteIds = map.keys.toSet();
        notifyListeners();
        _autoSync();
      case 'playback' || 'playback-command':
        PlaybackSync.instance.onEvent(event, j);
      case 'library':
        _refreshLibrary(builtAt: j['builtAt'] as String?);
      case 'request':
        final id = j['id'] as String;
        requests[id] = j['status'] as String;
        notifyListeners();
        if (j['status'] == 'ready') _fetchRequested(id);
    }
  }

  // MARK: requests

  /// Asks the computer to find `id` (or a song by artist + title) on Soulseek. If the computer is offline,
  /// the request waits in the account until it's back. Returns the status.
  Future<String> request({String? id, String? artist, String? title}) async {
    try {
      final r = await http
          .post(Uri.parse('$base/request'), headers: {..._headers, 'content-type': 'application/json'},
              body: jsonEncode({'id': id, 'artist': artist, 'title': title}))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) throw Exception('computer said ${r.statusCode}');
      final j = jsonDecode(r.body);
      requests[j['id'] as String] = j['status'] as String;
      notifyListeners();
      if (j['status'] == 'ready') _fetchRequested(j['id']);
      return j['status'];
    } catch (_) {
      final cid = Settings.current.connectedComputerId;
      if (!Account.signedIn || cid == null) rethrow;
      await Account.queueRequest(cid, id: id, artist: artist, title: title);
      if (id != null) requests[id] = 'queued';
      notifyListeners();
      return 'queued';
    }
  }

  /// A requested track is on the computer: bring it to the phone (refreshing the library first if it's a
  /// song that wasn't in any playlist before).
  Future<void> _fetchRequested(String id) async {
    if (store.track(id) == null) {
      try {
        await adoptLibrary();
      } catch (_) {}
    }
    final item = crateById?[id];
    if (item == null || store.track(id) == null) return;
    await download([item], (_, _, _) {});
    requests.remove(id);
    notifyListeners();
  }

  /// Makes the computer prepare the next tracks at `quality`, so skipping to them starts instantly.
  Future<void> prepare(List<String> ids, String quality) async {
    if (base == null || ids.isEmpty || quality == 'flac') return;
    try {
      await http.post(Uri.parse('$base/prepare'), headers: {..._headers, 'content-type': 'application/json'},
          body: jsonEncode({'ids': ids, 'q': quality})).timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  // MARK: downloads

  bool _syncing = false;

  /// Tracks of the auto-sync playlists that the computer has and this phone doesn't.
  List<Map<String, dynamic>> autoSyncMissing() {
    final crate = crateById, lib = store.library;
    if (crate == null || lib == null) return const [];
    final want = Settings.current.autoSyncPlaylists.toSet();
    final out = <String, Map<String, dynamic>>{};
    for (final pl in lib.playlists) {
      if (!want.contains(pl.name)) continue;
      for (final id in pl.trackIDs) {
        if (crate.containsKey(id) && store.state.tracks[id]?.status != TrackStatus.downloaded) out[id] = crate[id]!;
      }
    }
    return out.values.toList();
  }

  Future<void> _autoSync() async {
    if (_syncing) return;
    final todo = autoSyncMissing();
    if (todo.isEmpty) return;
    _syncing = true;
    try {
      await download(todo, (_, _, _) {});
    } finally {
      _syncing = false;
    }
  }

  int _downloads = 0;
  /// Set to stop download() after the files in flight.
  bool cancelDownload = false;
  /// Bytes received by the current download(), for speed and time left.
  int bytesDone = 0;

  /// Downloads `items` (from crate()) the phone doesn't have yet, at `quality` (default: the download setting),
  /// `parallel` at a time. A FLAC cut off half-way picks up where it stopped. `progress(done, total, name)`.
  Future<int> download(List<Map<String, dynamic>> items, void Function(int, int, String) progress,
      {String? quality, int parallel = 1}) async {
    await AccountConnect.refreshIfNeeded();
    final q = quality ?? Settings.current.downloadQuality;
    // Another download may be running (a big copy + an upgrade arriving): only the first one resets the counters.
    if (_downloads++ == 0) {
      cancelDownload = false;
      bytesDone = 0;
    }
    var done = 0, failedInARow = 0;
    final todo = [...items];
    final client = http.Client();
    await AppPaths.tracks.create(recursive: true);
    Future<void> worker() async {
      while (todo.isNotEmpty && !cancelDownload && failedInARow < 6) {
        final item = todo.removeAt(0);
        final t = store.track(item['id'] as String);
        if (t == null) continue;
        progress(done, items.length, t.title);
        for (var attempt = 0; attempt < 3 && !cancelDownload; attempt++) {
          try {
            if (await _copyOne(client, item, t, q)) {
              done++;
              failedInARow = 0;
              if (done % 25 == 0) await store.save(); // a long copy that's interrupted keeps what it got
            }
            break;
          } catch (e) {
            lastError = '$e';
            if (attempt == 2) failedInARow++;
            await Future.delayed(const Duration(seconds: 2));
          }
        }
        progress(done, items.length, t.title);
      }
    }

    try {
      await Future.wait([for (var i = 0; i < max(1, parallel); i++) worker()]);
    } finally {
      client.close();
      _downloads--;
    }
    if (done > 0) {
      store.log('phone sync', '$done tracks copied from the computer');
      await store.saveAnalysis();
      await store.save();
      store.changed();
    }
    return done;
  }

  Future<bool> _copyOne(http.Client client, Map<String, dynamic> item, LibraryTrack t, String q) async {
    final id = item['id'] as String;
    final part = File(p.join(AppPaths.tracks.path, '${t.fileName}.$q.part'));
    // Only originals resume: a smaller copy could differ from the one the first part came from.
    final have = q == 'flac' && await part.exists() ? await part.length() : 0;
    final req = http.Request('GET', Uri.parse('$base/file/${Uri.encodeComponent(id)}?q=$q'))..headers.addAll(_headers);
    if (have > 0) req.headers['range'] = 'bytes=$have-';
    final res = await client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode == 416) {
      await part.delete();
      throw Exception('restart $id');
    }
    if (res.statusCode != 200 && res.statusCode != 206) {
      await res.stream.drain<void>();
      return false;
    }
    // A smaller copy comes back as AAC (.m4a); the original keeps its own format.
    final ext = (res.headers['content-type'] ?? '') == 'audio/mp4' && item['ext'] != '.m4a' && item['ext'] != '.alac' ? '.m4a' : item['ext'];
    final dest = p.join(AppPaths.tracks.path, '${t.fileName}$ext');
    final sink = part.openWrite(mode: res.statusCode == 206 ? FileMode.append : FileMode.write);
    var got = 0;
    try {
      // A link that goes quiet for 20 s is gone; the retry resumes.
      await for (final chunk in res.stream.timeout(const Duration(seconds: 20))) {
        sink.add(chunk);
        got += chunk.length;
        bytesDone += chunk.length;
      }
    } finally {
      await sink.close();
    }
    final want = res.contentLength;
    if (want != null && got < want) throw Exception('cut off after $got of $want bytes');
    final previous = store.state.tracks[id]?.localPath;
    await part.rename(dest);
    // A better copy replaces the old one (which may have had another extension).
    if (previous != null && previous != dest && await File(previous).exists()) await File(previous).delete();
    final a = item['analysis'];
    if (a is Map) {
      final st = await File(dest).stat();
      store.analysis[dest] = FileAnalysis.fromJson({...Map<String, dynamic>.from(a), 'path': dest, 'sizeBytes': st.size, 'modified': isoSeconds(st.modified)});
    }
    store.state.tracks[id] = TrackState(status: TrackStatus.downloaded, localPath: dest, source: 'phone-sync');
    store.changed();
    return true;
  }
}
