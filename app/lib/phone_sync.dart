// Computer → phone library sync over the local network.
//
// Desktop: serves the crate (tracks you have, with their analysis) on port 47390. Every request must carry
// the pairing token shown in the QR code, so only phones you paired can browse or download.
// Phone: scans the QR code, lists the computer's playlists, downloads the chosen tracks straight into its
// own Tracks/ folder (already tagged and analysed on the computer).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'config.dart';
import 'models.dart';
import 'paths.dart';
import 'settings.dart';
import 'store.dart';

class PhoneSyncServer {
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
    return 'wreckbox://pair?hosts=${ips.join(',')}&port=${AppConfig.phoneSyncPort}&t=$token';
  }

  Future<void> start() async {
    if (_server != null) return;
    final r = Router()
      ..get('/info', (Request _) => _json({'name': 'WreckBox on ${Platform.localHostname}', 'tracks': store.count(TrackStatus.downloaded)}))
      ..get('/library.json', (Request _) async => Response.ok(await AppPaths.libraryFile.readAsString(), headers: {'content-type': 'application/json'}))
      ..get('/crate', (Request _) => _json(_crate()))
      ..get('/file/<id>', (Request req, String id) => _file(Uri.decodeComponent(id)))
      ..get('/art/<id>', (Request req, String id) async {
        final t = store.track(Uri.decodeComponent(id));
        final f = t == null ? null : await store.ensureArtwork(t);
        return f == null ? Response.notFound('') : Response.ok(f.openRead(), headers: {'content-type': 'image/jpeg'});
      });
    final handler = const Pipeline().addMiddleware(_auth()).addHandler(r.call);
    _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, AppConfig.phoneSyncPort);
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

  Future<Response> _file(String id) async {
    final path = store.state.tracks[id]?.localPath;
    if (path == null || !await File(path).exists()) return Response.notFound('no such track');
    final f = File(path);
    return Response.ok(f.openRead(), headers: {'content-type': 'application/octet-stream', 'content-length': '${await f.length()}'});
  }
}

/// Phone side.
class PhoneSyncClient {
  final LibraryStore store;
  PhoneSyncClient(this.store);

  static Map<String, String>? parsePairing(String raw) {
    final u = Uri.tryParse(raw);
    if (u == null || u.scheme != 'wreckbox' || u.host != 'pair') return null;
    final t = u.queryParameters['t'], port = u.queryParameters['port'] ?? '${AppConfig.phoneSyncPort}';
    final hosts = (u.queryParameters['hosts'] ?? '').split(',').where((h) => h.isNotEmpty).toList();
    if (t == null || hosts.isEmpty) return null;
    return {'hosts': hosts.join(','), 'port': port, 't': t};
  }

  /// Tries each address from the QR code and keeps the first that answers.
  static Future<String?> pair(Map<String, String> info) async {
    for (final h in info['hosts']!.split(',')) {
      final base = 'http://$h:${info['port']}';
      try {
        final r = await http.get(Uri.parse('$base/info'), headers: {'x-wreckbox-token': info['t']!}).timeout(const Duration(seconds: 4));
        if (r.statusCode == 200) {
          Settings.current
            ..pairedDesktop = base
            ..pairToken = info['t'];
          await Settings.current.save();
          return base;
        }
      } catch (_) {}
    }
    return null;
  }

  Map<String, String> get _headers => {'x-wreckbox-token': Settings.current.pairToken ?? ''};
  String? get base => Settings.current.pairedDesktop;

  Future<Map<String, dynamic>> info() async =>
      jsonDecode((await http.get(Uri.parse('$base/info'), headers: _headers).timeout(const Duration(seconds: 6))).body);

  /// Use the computer's Spotify library on the phone (no separate Spotify setup needed).
  Future<void> adoptLibrary() async {
    final r = await http.get(Uri.parse('$base/library.json'), headers: _headers);
    if (r.statusCode != 200) throw Exception('computer said ${r.statusCode}');
    await writeAtomic(AppPaths.libraryFile, r.body);
    await store.load();
  }

  Future<List<Map<String, dynamic>>> crate() async {
    final r = await http.get(Uri.parse('$base/crate'), headers: _headers).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('computer said ${r.statusCode}');
    return List<Map<String, dynamic>>.from(jsonDecode(r.body));
  }

  /// Downloads `items` (from crate()) the phone doesn't have yet. `progress(done, total, name)`.
  Future<int> download(List<Map<String, dynamic>> items, void Function(int, int, String) progress) async {
    var done = 0;
    final client = http.Client();
    try {
      for (final item in items) {
        final id = item['id'] as String;
        final t = store.track(id);
        if (t == null) continue;
        final dest = p.join(AppPaths.tracks.path, '${t.fileName}${item['ext']}');
        progress(done, items.length, t.title);
        final req = http.Request('GET', Uri.parse('$base/file/${Uri.encodeComponent(id)}'))..headers.addAll(_headers);
        final res = await client.send(req);
        if (res.statusCode != 200) continue;
        await AppPaths.tracks.create(recursive: true);
        final tmp = File('$dest.part');
        await res.stream.pipe(tmp.openWrite());
        await tmp.rename(dest);
        final a = item['analysis'];
        if (a is Map) {
          final st = await File(dest).stat();
          store.analysis[dest] = FileAnalysis.fromJson({...Map<String, dynamic>.from(a), 'path': dest, 'sizeBytes': st.size, 'modified': isoSeconds(st.modified)});
        }
        store.state.tracks[id] = TrackState(status: TrackStatus.downloaded, localPath: dest, source: 'phone-sync');
        done++;
      }
    } finally {
      client.close();
    }
    store.log('phone sync', '$done tracks copied from the computer');
    await store.saveAnalysis();
    await store.save();
    store.changed();
    return done;
  }
}
