// Where WreckBox keeps things on each platform.
//
// Desktop:  <home>/Music/WreckBox            library.json, state.json, Tracks/, _inbox/, _cache/, _soulseek/
// Android:  /storage/emulated/0/Music/WreckBox  (shared storage, so Rekordbox and other players see Tracks/)
//           app documents dir for settings.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppPaths {
  static late Directory root; // the library folder
  static late Directory settingsDir;
  static Directory? downloads; // scanned by the organiser

  static bool get isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  static bool get isPhone => Platform.isAndroid || Platform.isIOS;

  static Future<void> init({String? overrideRoot}) async {
    if (overrideRoot != null) {
      root = Directory(overrideRoot);
      settingsDir = Directory(p.join(overrideRoot, '_settings'));
    } else if (Platform.isAndroid) {
      root = Directory('/storage/emulated/0/Music/WreckBox');
      settingsDir = await getApplicationDocumentsDirectory();
      downloads = Directory('/storage/emulated/0/Download');
    } else {
      final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
      root = Directory(p.join(home, 'Music', 'WreckBox'));
      settingsDir = Directory(p.join((await getApplicationSupportDirectory()).path));
      downloads = Directory(p.join(home, 'Downloads'));
    }
    for (final d in [root, tracks, inbox, cache, artwork, settingsDir]) {
      try {
        d.createSync(recursive: true);
      } catch (_) {
        // Android before the storage permission is granted; created again after.
      }
    }
  }

  static File get libraryFile => File(p.join(root.path, 'library.json'));
  static File get stateFile => File(p.join(root.path, 'state.json'));
  static Directory get tracks => Directory(p.join(root.path, 'Tracks'));
  static Directory get inbox => Directory(p.join(root.path, '_inbox'));
  static Directory get cache => Directory(p.join(root.path, '_cache'));
  static Directory get artwork => Directory(p.join(root.path, '_cache', 'artwork'));
  static File get analysisCache => File(p.join(root.path, '_cache', 'analysis.json'));
  static Directory get spotifyDir => Directory(p.join(root.path, '_spotify'));
  static Directory get soulseekDir => Directory(p.join(root.path, '_soulseek'));
  static File get settingsFile => File(p.join(settingsDir.path, 'settings.json'));
  static File get appLog => File(p.join(settingsDir.path, 'wreckbox.log'));
}

const audioExtensions = {'mp3', 'wav', 'aif', 'aiff', 'flac', 'm4a', 'alac', 'aac', 'ogg', 'opus'};

bool isAudio(String path) => audioExtensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

/// Writes a file atomically (temp file + rename) so a crash never leaves a half-written JSON file.
int _tmpSeq = 0;

Future<void> writeAtomic(File f, String contents) async {
  await f.parent.create(recursive: true);
  // A temp name of its own, so two saves of the same file at once can't take each other's temp file.
  final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.$_tmpSeq.tmp');
  _tmpSeq++;
  await tmp.writeAsString(contents, flush: true);
  await tmp.rename(f.path);
}
