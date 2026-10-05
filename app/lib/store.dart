// LibraryStore: the app's state (library, per-track status, analysis cache, activity log) and the
// operations on it — scanning, analysing, organising new files and writing tags.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'engine.dart';
import 'matcher.dart';
import 'models.dart';
import 'paths.dart';
import 'settings.dart';

class TrackRow {
  final LibraryTrack track;
  final TrackState? state;
  final FileAnalysis? file;
  final String genre;
  TrackRow(this.track, this.state, this.file, this.genre);

  String get id => track.id;
  TrackStatus get status => state?.status ?? TrackStatus.missing;
  double? get bpm => file?.bpm;
  String get camelot => file?.camelot ?? '';
  double? get energy => file?.energy;
  String get durationText {
    final ms = track.durationMs;
    if (ms == null) return '';
    return '${ms ~/ 60000}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}';
  }
}

enum ListFilter { all, missing, downloaded, ignored }

class LibraryStore extends ChangeNotifier {
  Library? library;
  AppState state = AppState();
  Map<String, FileAnalysis> analysis = {};
  Map<String, double> catalogueBpm = {}; // track id → Deezer BPM (0 = none)
  String? loadError;
  String? busy;
  String? focus; // track shown in the inspector
  final Map<String, int> _index = {};
  bool _stateUnreadable = false;

  // MARK: Load / save

  Future<void> load() async {
    loadError = null;
    try {
      if (await AppPaths.libraryFile.exists()) {
        library = Library.fromJson(jsonDecode(await AppPaths.libraryFile.readAsString()));
      }
    } catch (e) {
      loadError = "Couldn't read library.json ($e)";
    }
    _index
      ..clear()
      ..addEntries([for (var i = 0; i < (library?.tracks.length ?? 0); i++) MapEntry(library!.tracks[i].id, i)]);
    try {
      if (await AppPaths.stateFile.exists()) {
        state = AppState.fromJson(jsonDecode(await AppPaths.stateFile.readAsString()));
      }
      _stateUnreadable = false;
    } catch (e) {
      // Never overwrite a state file we couldn't read.
      _stateUnreadable = true;
      loadError = "Couldn't read state.json — changes won't be saved until it's fixed ($e)";
    }
    try {
      if (await AppPaths.analysisCache.exists()) {
        final j = jsonDecode(await AppPaths.analysisCache.readAsString()) as Map<String, dynamic>;
        analysis = j.map((k, v) => MapEntry(k, FileAnalysis.fromJson(Map<String, dynamic>.from(v))));
      }
    } catch (_) {
      analysis = {};
    }
    try {
      final f = File(p.join(AppPaths.cache.path, 'catalogue_bpm.json'));
      if (await f.exists()) {
        catalogueBpm = Map<String, dynamic>.from(jsonDecode(await f.readAsString())).map((k, v) => MapEntry(k, (v as num).toDouble()));
      }
    } catch (_) {}
    if (state.scanFolders.isEmpty) state.scanFolders = defaultScanFolders();
    notifyListeners();
  }

  List<String> defaultScanFolders() => [
        AppPaths.tracks.path,
        if (AppPaths.downloads != null) AppPaths.downloads!.path,
        if (AppPaths.isDesktop) p.join(AppPaths.root.parent.path), // ~/Music
        ...Settings.current.extraScanFolders,
      ];

  Future<void> save() async {
    if (_stateUnreadable) return;
    await writeAtomic(AppPaths.stateFile, const JsonEncoder.withIndent('  ').convert(state.toJson()));
  }

  Future<void> saveAnalysis() async {
    await writeAtomic(AppPaths.analysisCache, jsonEncode(analysis.map((k, v) => MapEntry(k, v.toJson()))));
    await writeAtomic(File(p.join(AppPaths.cache.path, 'catalogue_bpm.json')), jsonEncode(catalogueBpm));
  }

  void log(String event, String detail, [String? trackID]) {
    state.log.add(LogEntry(event: event, detail: detail, trackID: trackID));
  }

  void setBusy(String? b) {
    busy = b;
    notifyListeners();
  }

  /// Tell listeners something changed (for services that edit the store directly).
  void changed() => notifyListeners();

  void setFocus(String? id) {
    focus = id;
    notifyListeners();
  }

  // MARK: Queries

  LibraryTrack? track(String id) {
    final i = _index[id];
    return i == null ? null : library!.tracks[i];
  }

  String genreOf(String id, FileAnalysis? f) => state.genreOverrides[id] ?? '';

  TrackRow? row(String id) {
    final t = track(id);
    if (t == null) return null;
    final st = state.tracks[id];
    final f = st?.localPath != null ? analysis[st!.localPath!] : null;
    return TrackRow(t, st, f, genreOf(id, f));
  }

  List<TrackRow> rows({ListFilter filter = ListFilter.all, String? playlist, String search = ''}) {
    final lib = library;
    if (lib == null) return [];
    Iterable<LibraryTrack> ts = lib.tracks;
    if (playlist != null) {
      final pl = lib.playlists.where((x) => x.name == playlist).firstOrNull;
      final seen = <String>{};
      ts = (pl?.trackIDs ?? const []).where(seen.add).map(track).whereType<LibraryTrack>();
    }
    var out = ts.map((t) => row(t.id)!).toList();
    switch (filter) {
      case ListFilter.missing:
        out = out.where((r) => r.status == TrackStatus.missing).toList();
      case ListFilter.downloaded:
        out = out.where((r) => r.status == TrackStatus.downloaded).toList();
      case ListFilter.ignored:
        out = out.where((r) => r.status == TrackStatus.ignored).toList();
      case ListFilter.all:
        break;
    }
    final q = normalized(search);
    if (q.isNotEmpty) out = out.where((r) => normalized('${r.track.artist} ${r.track.title} ${r.track.album ?? ''}').contains(q)).toList();
    return out;
  }

  int count(TrackStatus s) => library?.tracks.where((t) => (state.tracks[t.id]?.status ?? TrackStatus.missing) == s).length ?? 0;

  int downloadedIn(LibraryPlaylist pl) => pl.trackIDs.where((id) => state.tracks[id]?.status == TrackStatus.downloaded).length;

  /// Tracks you have that mix with `r`: compatible key, tempo within ±6% (also half / double time).
  List<TrackRow> mixesWith(TrackRow r) {
    final bpm = r.bpm, key = r.camelot;
    if (bpm == null || key.isEmpty) return [];
    final keys = compatibleKeys(key);
    final out = <(TrackRow, double)>[];
    for (final t in library?.tracks ?? const <LibraryTrack>[]) {
      if (t.id == r.id) continue;
      final o = row(t.id)!;
      if (o.bpm == null || !keys.contains(o.camelot)) continue;
      final gap = [o.bpm!, o.bpm! * 2, o.bpm! / 2].map((b) => (b - bpm).abs() / bpm).reduce((a, b) => a < b ? a : b);
      if (gap <= 0.06) out.add((o, gap + (o.camelot == key ? 0 : 0.01)));
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return out.take(12).map((e) => e.$1).toList();
  }

  // MARK: Actions

  Future<void> setStatus(Iterable<String> ids, TrackStatus s) async {
    for (final id in ids) {
      final old = state.tracks[id];
      state.tracks[id] = TrackState(status: s, localPath: s == TrackStatus.downloaded ? old?.localPath : null, source: 'manual');
      log('marked ${s.name}', describe(id), id);
    }
    await save();
    notifyListeners();
  }

  String describe(String id) {
    final t = track(id);
    return t == null ? id : '${t.artist} – ${t.title}';
  }

  // MARK: Artwork

  File artworkFile(LibraryTrack t) => File(p.join(AppPaths.artwork.path, '${t.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_')}.jpg'));

  /// Downloads the Spotify cover (640 px) into the cache if needed; returns the file or null.
  Future<File?> ensureArtwork(LibraryTrack t) async {
    final f = artworkFile(t);
    if (await f.exists()) return f;
    final url = t.artworkURL?.replaceAll('ab67616d00001e02', 'ab67616d0000b273');
    if (url == null) return null;
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      await f.parent.create(recursive: true);
      await f.writeAsBytes(res.bodyBytes);
      return f;
    } catch (_) {
      return null;
    }
  }

  // MARK: Analysis

  Future<FileAnalysis?> analyzeFile(String path, {String? trackID}) async {
    final stat = await File(path).stat();
    final cached = analysis[path];
    if (cached != null && cached.sizeBytes == stat.size && cached.modified != null && isoSeconds(cached.modified!) == isoSeconds(stat.modified)) {
      return cached;
    }
    final r = await Engine.analyze(path);
    if (r['error'] != null) {
      log('analysis failed', '${p.basename(path)}: ${r['error']}', trackID);
      return null;
    }
    var a = FileAnalysis.fromJson({...r, 'path': path, 'sizeBytes': stat.size, 'modified': isoSeconds(stat.modified), 'libraryTrackID': trackID});
    if (trackID != null) a = await _reconcileBpm(a, trackID);
    analysis[path] = a;
    return a;
  }

  /// Uses Deezer's catalogue BPM (looked up by ISRC) to pick between the analyser's top tempos.
  Future<FileAnalysis> _reconcileBpm(FileAnalysis a, String trackID) async {
    final t = track(trackID);
    if (t?.isrc == null || a.bpm == null) return a;
    var ref = catalogueBpm[trackID];
    if (ref == null) {
      try {
        final res = await http.get(Uri.parse('https://api.deezer.com/track/isrc:${t!.isrc}')).timeout(const Duration(seconds: 10));
        ref = ((jsonDecode(res.body) as Map)['bpm'] as num?)?.toDouble() ?? 0;
      } catch (_) {
        return a; // offline: keep the analyser's choice, try again next time
      }
      catalogueBpm[trackID] = ref;
    }
    if (ref <= 0) return a;
    bool near(double x) => (x - ref!).abs() / ref < 0.02;
    if (near(a.bpm!)) return a;
    for (final c in [a.bpmAlternate, ...a.bpmCandidates].whereType<double>()) {
      if (near(c) || near(c * 2) || near(c / 2)) return a.copyWith(bpm: near(c) ? c : (near(c * 2) ? c * 2 : c / 2));
    }
    return a;
  }

  Future<FileFacts> facts(String path) async {
    final tags = await Engine.readTags(path);
    final a = analysis[path];
    return FileFacts(
      path: path,
      title: tags['title'],
      artists: List<String>.from(tags['artists'] ?? const []),
      isrc: tags['isrc'],
      durationSec: a?.durationSec,
    );
  }

  // MARK: Rescan

  Future<void> rescan() async {
    final lib = library;
    if (lib == null || busy != null) return;
    setBusy('Scanning folders…');
    final matcher = TrackMatcher(lib.tracks);
    final files = <String>[];
    for (final dir in state.scanFolders) {
      final d = Directory(dir);
      if (!await d.exists()) continue;
      try {
        await for (final e in d.list(recursive: true, followLinks: false)) {
          if (e is File && isAudio(e.path) && !p.split(e.path).any((s) => s.startsWith('.') || s == '_inbox')) files.add(e.path);
        }
      } catch (_) {}
    }
    final unique = files.toSet().toList();
    final found = <String, String>{};
    for (var i = 0; i < unique.length; i++) {
      setBusy('Scanning & analysing ${i + 1}/${unique.length}…');
      final path = unique[i];
      final f = await facts(path);
      final idx = matcher.match(f);
      final tid = idx == null ? null : lib.tracks[idx].id;
      if (tid != null) found.putIfAbsent(tid, () => path);
      final a = await analyzeFile(path, trackID: tid);
      if (a != null && tid != null && a.libraryTrackID != tid) analysis[path] = a.copyWith(libraryTrackID: tid);
      if (i % 20 == 19) await saveAnalysis();
    }
    analysis.removeWhere((k, _) => !File(k).existsSync());
    var added = 0, gone = 0;
    for (final t in lib.tracks) {
      final cur = state.tracks[t.id];
      final path = found[t.id];
      if (path != null) {
        if (cur?.status == TrackStatus.ignored) continue;
        if (cur?.status != TrackStatus.downloaded || cur?.localPath != path) {
          state.tracks[t.id] = TrackState(status: TrackStatus.downloaded, localPath: path, source: cur?.source ?? 'scan');
          log('found', '${describe(t.id)} → $path', t.id);
          added++;
        }
      } else if (cur?.status == TrackStatus.downloaded && cur?.localPath != null && !File(cur!.localPath!).existsSync()) {
        state.tracks[t.id] = TrackState(status: TrackStatus.missing, source: 'scan');
        log('file gone', '${describe(t.id)} – ${cur.localPath} no longer exists', t.id);
        gone++;
      }
    }
    log('rescan', '${unique.length} audio files read, $added newly matched, $gone gone');
    await saveAnalysis();
    await save();
    setBusy(null);
  }

  // MARK: Organising new files

  /// Analyse → match → write tags (Spotify data, BPM, key, cover) → rename "Artist - Title.ext" → move into
  /// Tracks/. Returns a short status line. `trackID` skips matching when the target is already known.
  Future<String> organise(String path, {required String source, String? trackID}) async {
    final lib = library;
    if (lib == null) return 'no library loaded';
    final name = p.basename(path);
    try {
      String? tid = trackID;
      if (tid == null) {
        await analyzeFile(path); // duration helps matching
        final idx = TrackMatcher(lib.tracks).match(await facts(path));
        tid = idx == null ? null : lib.tracks[idx].id;
      }
      if (tid == null) {
        log('unmatched', '$name — not in your Spotify library, left where it is');
        await save();
        return 'Not in your library: $name';
      }
      final t = track(tid)!;
      final a = await analyzeFile(path, trackID: tid);
      final cover = await ensureArtwork(t);
      final res = await Engine.writeTags({
        'path': path, 'title': t.title, 'artists': t.artists, 'album': t.album, 'year': t.year,
        'genre': state.genreOverrides[tid], 'bpm': a?.bpm, 'key': a?.key, 'isrc': t.isrc, 'cover': cover?.path,
      });
      if (res['error'] != null) log('tag failed', '$name: ${res['error']}', tid);
      await AppPaths.tracks.create(recursive: true);
      final ext = p.extension(path).toLowerCase();
      var dest = p.join(AppPaths.tracks.path, '${t.fileName}$ext');
      for (var n = 2; File(dest).existsSync() && dest != path; n++) {
        dest = p.join(AppPaths.tracks.path, '${t.fileName} ($n)$ext');
      }
      if (dest != path) await _move(path, dest);
      final moved = analysis.remove(path);
      final st = await File(dest).stat();
      if (moved != null) analysis[dest] = moved.copyWith(sizeBytes: st.size, modified: st.modified, libraryTrackID: tid);
      state.tracks[tid] = TrackState(status: TrackStatus.downloaded, localPath: dest, source: source);
      log('downloaded', '${describe(tid)} via $source → Tracks/${p.basename(dest)}', tid);
      await saveAnalysis();
      await save();
      notifyListeners();
      return 'Added ${describe(tid)}';
    } catch (e) {
      log('organise failed', '$name: $e');
      await save();
      return 'Failed: $name ($e)';
    }
  }

  /// rename(), falling back to copy + delete across volumes (e.g. SD card → internal storage).
  Future<void> _move(String from, String to) async {
    try {
      await File(from).rename(to);
    } on FileSystemException {
      await File(from).copy(to);
      await File(from).delete();
    }
  }

  // MARK: Tags

  Future<void> writeTags([List<String>? ids]) async {
    if (busy != null) return;
    final targets = ids ?? [for (final t in library?.tracks ?? const <LibraryTrack>[]) if (state.tracks[t.id]?.status == TrackStatus.downloaded) t.id];
    var ok = 0, failed = 0;
    for (var i = 0; i < targets.length; i++) {
      setBusy('Writing tags ${i + 1}/${targets.length}…');
      final r = row(targets[i]);
      final path = r?.state?.localPath;
      if (r == null || path == null || !File(path).existsSync()) continue;
      final cover = await ensureArtwork(r.track);
      final res = await Engine.writeTags({
        'path': path, 'title': r.track.title, 'artists': r.track.artists, 'album': r.track.album, 'year': r.track.year,
        'genre': state.genreOverrides[r.id], 'bpm': r.bpm, 'key': r.file?.key, 'isrc': r.track.isrc, 'cover': cover?.path,
      });
      if (res['error'] != null) {
        failed++;
        log('tag failed', '${p.basename(path)}: ${res['error']}', r.id);
      } else {
        ok++;
        final st = await File(path).stat();
        final a = analysis[path];
        if (a != null) analysis[path] = a.copyWith(sizeBytes: st.size, modified: st.modified);
      }
    }
    log('tags written', '$ok files updated, $failed failed');
    await saveAnalysis();
    await save();
    setBusy(null);
  }
}
