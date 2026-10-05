// "Use from anywhere" (desktop): a Cloudflare quick tunnel gives this computer's phone-sync server a temporary
// https address; it's registered in the account so the account's phones can stream and download from anywhere.
// Requests still need the phone-sync token, which only the account's devices receive.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'account.dart';
import 'paths.dart';
import 'phone_sync.dart';

class Tunnel extends ChangeNotifier {
  final PhoneSyncServer server;
  Process? _proc;
  Timer? _heartbeat;
  String? url;
  String status = 'Off';
  bool _wanted = false;

  Tunnel(this.server);

  bool get running => _proc != null && url != null;

  static File get binary => File(p.join(AppPaths.settingsDir.path, Platform.isWindows ? 'cloudflared.exe' : 'cloudflared'));

  /// Downloads Cloudflare's cloudflared once (≈ 40 MB) into the app's folder.
  static Future<void> _ensureBinary(void Function(String) log) async {
    if (await binary.exists()) return;
    const base = 'https://github.com/cloudflare/cloudflared/releases/latest/download';
    final asset = Platform.isWindows
        ? 'cloudflared-windows-amd64.exe'
        : (Platform.isMacOS ? 'cloudflared-darwin-arm64.tgz' : 'cloudflared-linux-amd64');
    log('Downloading Cloudflare tunnel tool…');
    final r = await http.get(Uri.parse('$base/$asset'));
    if (r.statusCode != 200) throw Exception('download failed (${r.statusCode})');
    await binary.parent.create(recursive: true);
    if (asset.endsWith('.tgz')) {
      final tgz = File('${binary.path}.tgz');
      await tgz.writeAsBytes(r.bodyBytes);
      final x = await Process.run('tar', ['-xzf', tgz.path, '-C', binary.parent.path]);
      await tgz.delete();
      if (x.exitCode != 0) throw Exception('unpack failed');
    } else {
      await binary.writeAsBytes(r.bodyBytes);
    }
    if (!Platform.isWindows) await Process.run('chmod', ['+x', binary.path]);
  }

  Future<void> start() async {
    _wanted = true;
    if (_proc != null) return;
    if (!Account.signedIn) {
      status = 'Sign in to your WreckBox account first.';
      notifyListeners();
      return;
    }
    try {
      await server.start();
      await _ensureBinary((s) {
        status = s;
        notifyListeners();
      });
      status = 'Connecting…';
      notifyListeners();
      final proc = await Process.start(binary.path,
          ['tunnel', '--no-autoupdate', '--url', 'http://127.0.0.1:${PhoneSyncServer.port}']);
      _proc = proc;
      // cloudflared prints the quick-tunnel address on stderr.
      final found = Completer<String>();
      void scan(String line) {
        final m = RegExp(r'https://[a-z0-9-]+\.trycloudflare\.com').firstMatch(line);
        if (m != null && !found.isCompleted) found.complete(m.group(0));
      }
      proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(scan);
      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(scan);
      proc.exitCode.then((_) {
        _proc = null;
        url = null;
        _heartbeat?.cancel();
        status = _wanted ? 'Reconnecting…' : 'Off';
        notifyListeners();
        if (_wanted) Future.delayed(const Duration(seconds: 10), start); // dropped: bring it back
      });
      url = await found.future.timeout(const Duration(seconds: 45));
      await _register();
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(minutes: 5), (_) => _register().catchError((_) {}));
      status = 'Reachable from anywhere';
      notifyListeners();
    } catch (e) {
      await stop(keepWanted: true);
      status = "Couldn't connect: $e"; // after stop(), which resets the status
      notifyListeners();
    }
  }

  Future<void> _register() async {
    await Account.registerComputer(name: 'WreckBox on ${Platform.localHostname}', platform: Platform.operatingSystem, url: url, syncToken: server.token);
    await Account.uploadLibrary(server.store).catchError((_) {}); // keep the account's copy current
  }

  Future<void> stop({bool keepWanted = false}) async {
    _wanted = keepWanted;
    _heartbeat?.cancel();
    _proc?.kill();
    _proc = null;
    url = null;
    status = 'Off';
    // Tell the account this computer is no longer reachable.
    if (Account.signedIn) {
      await Account.registerComputer(name: 'WreckBox on ${Platform.localHostname}', platform: Platform.operatingSystem).catchError((_) {});
    }
    notifyListeners();
  }
}
