// Soulseek sync (desktop): runs the bundled slsk_sync.py sidecar, imports what it drops in _inbox, and reads
// its results. Same files as the Mac app: _soulseek/sync.json, sync.log, queue.json, overrides.json.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'paths.dart';
import 'store.dart';

class SyncRecord {
  final String status, lastTry;
  final int attempts;
  final String? reason, format, source;
  final List<String> queries;
  SyncRecord(Map<String, dynamic> d)
      : status = d['status'] ?? '',
        lastTry = d['last_try'] ?? '',
        attempts = (d['attempts'] as num?)?.toInt() ?? 0,
        reason = d['reason'],
        format = d['format'],
        source = d['source'],
        queries = List<String>.from(d['queries'] ?? const []);
}

class Soulseek extends ChangeNotifier {
  final LibraryStore store;
  Process? _process;
  Timer? _timer;
  Map<String, SyncRecord> records = {};
  Map<String, Map<String, dynamic>> overrides = {};
  List<String> recent = [];
  final _inboxSeen = <String>{};

  Soulseek(this.store);

  /// Sidecar layout next to the app: soulseek/python/python(.exe), soulseek/slsk_sync.py
  static Directory get sidecarDir {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [p.join(exeDir, 'soulseek'), p.join(exeDir, '..', 'Resources', 'soulseek')];
    return Directory(candidates.firstWhere((c) => Directory(c).existsSync(), orElse: () => candidates.first));
  }

  static String get python => Platform.isWindows ? p.join(sidecarDir.path, 'python', 'python.exe') : p.join(sidecarDir.path, 'python', 'bin', 'python3');
  static File get configFile => File(p.join(AppPaths.settingsDir.path, 'soulseek.toml'));
  static bool get available => File(python).existsSync() && File(p.join(sidecarDir.path, 'slsk_sync.py')).existsSync();

  bool get running => _process != null || externalPid != null;
  int? externalPid;

  int get done => records.values.where((r) => r.status == 'done').length;
  int get notFound => records.values.where((r) => r.status == 'not_found').length;
  int get failed => records.values.where((r) => r.status == 'failed').length;

  bool get configured {
    try {
      final c = configFile.readAsStringSync();
      return RegExp(r'^username\s*=\s*"[^"]+"', multiLine: true).hasMatch(c) && RegExp(r'^password\s*=\s*"[^"]+"', multiLine: true).hasMatch(c);
    } catch (_) {
      return false;
    }
  }

  Future<void> saveLogin(String username, String password, {bool shareTracks = true}) async {
    String q(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
    final share = shareTracks ? '[${q(AppPaths.tracks.path)}]' : '[]';
    await writeAtomic(configFile, '[soulseek]\nusername = ${q(username)}\npassword = ${q(password)}\nlisten_port = 60000\nshare_dirs = $share\n\n[sync]\ninterval_minutes = 30\nmax_concurrent = 3\nmin_lossy_kbps = 256\n');
  }

  void startWatching() {
    _timer ??= Timer.periodic(const Duration(seconds: 15), (_) => refresh());
    refresh();
  }

  Future<void> refresh() async {
    final dir = AppPaths.soulseekDir;
    try {
      final j = jsonDecode(await File(p.join(dir.path, 'sync.json')).readAsString()) as Map<String, dynamic>;
      records = j.map((k, v) => MapEntry(k, SyncRecord(Map<String, dynamic>.from(v))));
    } catch (_) {}
    try {
      overrides = Map<String, dynamic>.from(jsonDecode(await File(p.join(dir.path, 'overrides.json')).readAsString()))
          .map((k, v) => MapEntry(k, Map<String, dynamic>.from(v)));
    } catch (_) {}
    recent = await _tail(File(p.join(dir.path, 'sync.log')), 40);
    externalPid = _process == null ? await _lockHolder() : null;
    await importInbox();
    notifyListeners();
  }

  /// Reads only the end of the log (it only grows).
  static Future<List<String>> _tail(File f, int lines) async {
    try {
      final raf = await f.open();
      final len = await raf.length();
      await raf.setPosition(len > 65536 ? len - 65536 : 0);
      final text = utf8.decode(await raf.read(65536), allowMalformed: true);
      await raf.close();
      final all = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
      return all.sublist(all.length > lines ? all.length - lines : 0).reversed.toList();
    } catch (_) {
      return [];
    }
  }

  /// A sync this app didn't start (left over, or from a terminal): pid file + the process still alive.
  Future<int?> _lockHolder() async {
    try {
      final pid = int.parse((await File(p.join(AppPaths.soulseekDir.path, 'sync.pid')).readAsString()).trim());
      if (Platform.isWindows) {
        final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
        return r.stdout.toString().contains('$pid') && r.stdout.toString().toLowerCase().contains('python') ? pid : null;
      }
      final r = await Process.run('ps', ['-p', '$pid', '-o', 'command=']);
      return r.stdout.toString().contains('slsk_sync') ? pid : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> start() async {
    if (running) return null;
    if (!available) return "The Soulseek component isn't installed next to the app.";
    if (!configured) return 'Add your Soulseek username and password first.';
    _process = await Process.start(python, [p.join(sidecarDir.path, 'slsk_sync.py'), 'run'], environment: {
      'WRECKBOX_ROOT': AppPaths.root.path,
      'WRECKBOX_SLSK_CONFIG': configFile.path,
      'PYTHONIOENCODING': 'utf-8',
    });
    _process!.stdout.drain<void>();
    _process!.stderr.drain<void>();
    _process!.exitCode.then((_) {
      _process = null;
      refresh();
    });
    store.log('soulseek', 'sync started');
    await store.save();
    notifyListeners();
    return null;
  }

  Future<void> stop() async {
    _process?.kill();
    if (externalPid != null) Process.killPid(externalPid!);
    store.log('soulseek', 'sync stopped');
    await store.save();
    notifyListeners();
  }

  /// Called when the app quits.
  void dispose_() {
    _timer?.cancel();
    _process?.kill();
  }

  /// Files the sidecar finished go through the organiser (tags, rename, move into Tracks/).
  Future<void> importInbox() async {
    final lib = store.library;
    if (lib == null || store.busy != null || !await AppPaths.inbox.exists()) return;
    final byName = {for (final t in lib.tracks) t.fileName: t.id};
    await for (final e in AppPaths.inbox.list()) {
      if (e is! File || !isAudio(e.path)) continue;
      final size = await e.length();
      if (!_inboxSeen.add('${e.path}|$size')) continue;
      final stem = p.basenameWithoutExtension(e.path);
      final base = stem.replaceFirst(RegExp(r' \(\d+\)$'), '');
      await store.organise(e.path, source: 'soulseek', trackID: byName[stem] ?? byName[base]);
    }
  }

  /// Ask the sidecar to retry tracks on its next pass (it wakes within ~10 s), optionally with a custom search.
  Future<void> retry(List<String> ids, {String? query}) async {
    final f = File(p.join(AppPaths.soulseekDir.path, 'overrides.json'));
    Map<String, dynamic> all = {};
    try {
      all = Map<String, dynamic>.from(jsonDecode(await f.readAsString()));
    } catch (_) {}
    final now = isoSeconds(DateTime.now());
    for (final id in ids) {
      final o = Map<String, dynamic>.from(all[id] ?? {});
      o['retryAt'] = now;
      if (query != null) {
        if (query.trim().isEmpty) {
          o.remove('query');
        } else {
          o['query'] = query.trim();
        }
      }
      all[id] = o;
    }
    await writeAtomic(f, const JsonEncoder.withIndent('  ').convert(all));
    await refresh();
  }

  bool retryPending(String id) {
    final o = overrides[id], r = records[id];
    return o != null && (o['retryAt'] ?? '').compareTo(r?.lastTry ?? '') > 0;
  }

  /// Download order for the sidecar (playlist / genre priorities), same format as the Mac app.
  Future<void> writeQueue() async {
    final lib = store.library;
    if (lib == null) return;
    final missing = lib.tracks.where((t) => (store.state.tracks[t.id]?.status ?? TrackStatus.missing) == TrackStatus.missing).toList()
      ..sort((a, b) => (b.firstAdded ?? '').compareTo(a.firstAdded ?? ''));
    final missingIds = {for (final t in missing) t.id};
    final ids = <String>[], seen = <String>{};
    for (final key in store.state.downloadPriority) {
      final i = key.indexOf(':');
      final kind = key.substring(0, i), name = key.substring(i + 1);
      if (kind == 'playlist') {
        final pl = lib.playlists.where((x) => x.name == name).firstOrNull;
        for (final id in pl?.trackIDs ?? const <String>[]) {
          if (missingIds.contains(id) && seen.add(id)) ids.add(id);
        }
      } else if (kind == 'genre') {
        for (final t in missing) {
          if (store.state.genreOverrides[t.id] == name && seen.add(t.id)) ids.add(t.id);
        }
      }
    }
    if (!store.state.priorityOnly) {
      for (final t in missing) {
        if (seen.add(t.id)) ids.add(t.id);
      }
    }
    await writeAtomic(File(p.join(AppPaths.soulseekDir.path, 'queue.json')),
        jsonEncode({'generatedAt': isoSeconds(DateTime.now()), 'onlyPriority': store.state.priorityOnly, 'priorities': store.state.downloadPriority, 'ids': ids}));
  }
}
