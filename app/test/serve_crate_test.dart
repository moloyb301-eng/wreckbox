// Manual test harness (skipped unless WRECKBOX_SERVE_SECONDS is set): runs the desktop's phone-sync server
// over a COPY of a library whose state lists a few real downloaded tracks, so a phone / emulator can pair
// and download. Writes the pairing link to $WRECKBOX_SERVE_LINK.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wreckbox/models.dart';
import 'package:wreckbox/paths.dart';
import 'package:wreckbox/phone_sync.dart';
import 'package:wreckbox/settings.dart';
import 'package:wreckbox/store.dart';

void main() {
  final seconds = int.tryParse(Platform.environment['WRECKBOX_SERVE_SECONDS'] ?? '');
  test('serve a crate to a phone', () async {
    final src = Platform.environment['WRECKBOX_TEST_LIBRARY']!;
    final tmp = await Directory.systemTemp.createTemp('wreckbox-serve-');
    await File(p.join(src, 'library.json')).copy(p.join(tmp.path, 'library.json'));
    await Directory(p.join(tmp.path, '_cache')).create();
    await File(p.join(src, '_cache', 'analysis.json')).copy(p.join(tmp.path, '_cache', 'analysis.json'));
    final mac = jsonDecode(await File(p.join(src, 'state.json')).readAsString());
    final picked = Map<String, dynamic>.fromEntries((mac['tracks'] as Map<String, dynamic>).entries
        .where((e) => e.value['status'] == 'downloaded' && e.value['source'] == 'soulseek' && File(e.value['localPath']).existsSync())
        .take(6));
    await File(p.join(tmp.path, 'state.json')).writeAsString(jsonEncode({'tracks': picked}));
    await AppPaths.init(overrideRoot: tmp.path);
    Settings.current = Settings();
    final store = LibraryStore();
    await store.load();
    final server = PhoneSyncServer(store);
    await server.start();
    final link = await server.pairingUri();
    await File(Platform.environment['WRECKBOX_SERVE_LINK']!).writeAsString(link);
    print('serving ${store.count(TrackStatus.downloaded)} tracks: $link');
    await Future.delayed(Duration(seconds: seconds!));
    await server.stop();
  }, skip: seconds == null, timeout: Timeout(Duration(seconds: (seconds ?? 0) + 60)));
}
