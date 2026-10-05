// Manual end-to-end harness (skipped unless WRECKBOX_E2E_SECONDS is set): signs a computer into a test
// account, opens the Cloudflare tunnel and registers it, then keeps serving so a phone can sign in and stream.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wreckbox/account.dart';
import 'package:wreckbox/paths.dart';
import 'package:wreckbox/phone_sync.dart';
import 'package:wreckbox/settings.dart';
import 'package:wreckbox/store.dart';
import 'package:wreckbox/tunnel.dart';

void main() {
  final seconds = int.tryParse(Platform.environment['WRECKBOX_E2E_SECONDS'] ?? '');
  test('computer: account + tunnel', () async {
    final src = Platform.environment['WRECKBOX_TEST_LIBRARY']!;
    final tmp = await Directory.systemTemp.createTemp('wreckbox-e2e-');
    await File(p.join(src, 'library.json')).copy(p.join(tmp.path, 'library.json'));
    await Directory(p.join(tmp.path, '_cache')).create();
    await File(p.join(src, '_cache', 'analysis.json')).copy(p.join(tmp.path, '_cache', 'analysis.json'));
    final mac = jsonDecode(await File(p.join(src, 'state.json')).readAsString());
    final picked = Map<String, dynamic>.fromEntries((mac['tracks'] as Map<String, dynamic>).entries
        .where((e) => e.value['status'] == 'downloaded' && File(e.value['localPath'] ?? '').existsSync()).take(8));
    await File(p.join(tmp.path, 'state.json')).writeAsString(jsonEncode({'tracks': picked}));
    await AppPaths.init(overrideRoot: tmp.path);
    Settings.current = Settings();
    final store = LibraryStore();
    await store.load();
    final email = Platform.environment['WRECKBOX_E2E_EMAIL']!, pw = Platform.environment['WRECKBOX_E2E_PASSWORD']!;
    try {
      await Account.signUp(email, pw, 'E2E computer');
    } catch (_) {
      await Account.signIn(email, pw);
    }
    await Account.uploadLibrary(store);
    final server = PhoneSyncServer(store);
    final tunnel = Tunnel(server);
    await tunnel.start();
    print('tunnel: ${tunnel.url} status: ${tunnel.status}');
    expect(tunnel.url, isNotNull);
    final list = await Account.computers();
    print('account computers: ${list.map((c) => '${c.name} online=${c.online}').join(', ')}');
    expect(list.any((c) => c.online && c.url == tunnel.url), isTrue);
    await Future.delayed(Duration(seconds: seconds!));
    await tunnel.stop();
  }, skip: seconds == null, timeout: Timeout(Duration(seconds: (seconds ?? 0) + 180)));
}
