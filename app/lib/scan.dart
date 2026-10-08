// Scan this phone and Identify — the phone side of the Mac's "Scan & identify" (DJLibrary LibraryScan.swift /
// Identify.swift).
//
// Scan: walks shared storage for music outside Music/WreckBox, groups it by folder, and moves the picked folders'
// tracks in: playlist tracks through LibraryStore.organise (tagged, renamed, into Tracks/), the rest into Tracks/Found.
// Other apps' folders (Android/media, e.g. WhatsApp Audio) start unticked.
//
// Identify: fingerprints the tracks in Tracks/Found (Rust engine, Chromaprint — same as the Mac's fpcalc), looks
// them up on AcoustID, adds ISRC / year / genre from MusicBrainz and the cover from the Cover Art Archive, and keeps
// the suggestions until the user accepts (tags written, renamed "Artist - Title", filed if it's a playlist track)
// or skips. Suggestions live in _cache/identify.json.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'config.dart';
import 'engine.dart';
import 'matcher.dart';
import 'models.dart';
import 'paths.dart';
import 'store.dart';

class ScanGroup {
  final String name;
  final List<ScanFind> finds = [];
  ScanGroup(this.name);
  int get matched => finds.where((f) => f.trackID != null).length;
  int get size => finds.fold(0, (a, f) => a + f.size);
  bool get otherApp => name.startsWith('Android') || name.toLowerCase().contains('rekordbox');
}

class ScanFind {
  final String path, label;
  final String? trackID;
  final int size;
  ScanFind(this.path, this.label, this.trackID, this.size);
}

enum ScanPhase { idle, scanning, review, moving, done }

class PhoneScanner extends ChangeNotifier {
  static final instance = PhoneScanner();

  ScanPhase phase = ScanPhase.idle;
  List<ScanGroup> groups = [];
  final picked = <String>{};
  int done = 0, total = 0;
  String line = '';

  static const storageRoot = '/storage/emulated/0';
  /// Smaller than this is a ringtone, notification sound or voice note, not a track.
  static const minBytes = 1500000;
  static const _skip = {'Android', 'Notifications', 'Ringtones', 'Alarms', 'Recordings', 'Call', 'Voice Recorder', 'Podcasts', 'Audiobooks'};

  static Directory get foundDir => Directory(p.join(AppPaths.tracks.path, 'Found'));

  Future<void> scan(LibraryStore store) async {
    final lib = store.library;
    if (lib == null || phase == ScanPhase.scanning || phase == ScanPhase.moving) return;
    phase = ScanPhase.scanning;
    groups = [];
    line = 'Looking through your folders…';
    notifyListeners();
    final files = <File>[];
    await _walk(Directory(storageRoot), files, 0);
    final matcher = TrackMatcher(lib.tracks);
    final byGroup = <String, ScanGroup>{};
    total = files.length;
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      done = i + 1;
      line = p.basename(f.path);
      if (i % 10 == 0) notifyListeners();
      final facts = await store.facts(f.path);
      final idx = matcher.match(facts);
      final label = [facts.artists.join(', '), facts.title ?? ''].where((s) => s.isNotEmpty).join(' – ');
      final g = byGroup.putIfAbsent(group(f.path), () => ScanGroup(group(f.path)));
      g.finds.add(ScanFind(f.path, label.isEmpty ? p.basenameWithoutExtension(f.path) : label, idx == null ? null : lib.tracks[idx].id, await f.length()));
    }
    groups = byGroup.values.toList()..sort((a, b) => b.finds.length.compareTo(a.finds.length));
    picked
      ..clear()
      ..addAll(groups.where((g) => !g.otherApp).map((g) => g.name));
    line = '';
    phase = ScanPhase.review;
    store.log('scan', 'Scan found ${files.length} tracks outside WreckBox in ${groups.length} folders');
    notifyListeners();
  }

  /// Folders one at a time, so a folder we may not read (Android/data) doesn't end the walk.
  Future<void> _walk(Directory dir, List<File> out, int depth) async {
    if (dir.path == AppPaths.root.path || depth > 12) return;
    List<FileSystemEntity> list;
    try {
      list = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }
    for (final e in list) {
      final name = p.basename(e.path);
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        // Android/ is other apps' private data, except Android/media (e.g. WhatsApp Audio).
        if (depth == 0 && name == 'Android') {
          await _walk(Directory(p.join(e.path, 'media')), out, depth + 2);
        } else if (!(_skip.contains(name) && depth <= 1) && !name.contains('Voice Notes')) {
          await _walk(e, out, depth + 1);
        }
      } else if (e is File && isAudio(e.path)) {
        try {
          if (await e.length() >= minBytes) out.add(e);
        } catch (_) {}
      }
    }
  }

  /// "Download", "Music/Old phone", "Android/media": the first two folders under storage.
  static String group(String path) {
    final parts = p.split(p.relative(p.dirname(path), from: storageRoot)).where((s) => s != '.').take(2).toList();
    return parts.isEmpty ? 'Phone storage' : parts.join('/');
  }

  Future<void> move(LibraryStore store) async {
    if (phase != ScanPhase.review) return;
    final finds = [for (final g in groups) if (picked.contains(g.name)) ...g.finds];
    if (finds.isEmpty) return;
    phase = ScanPhase.moving;
    total = finds.length;
    notifyListeners();
    var filed = 0, found = 0, already = 0, failed = 0;
    for (var i = 0; i < finds.length; i++) {
      final f = finds[i];
      done = i + 1;
      line = f.label;
      notifyListeners();
      if (!await File(f.path).exists()) continue;
      final tid = f.trackID;
      if (tid != null) {
        final st = store.state.tracks[tid];
        final have = st?.status == TrackStatus.downloaded && st?.localPath != null && st!.localPath != f.path && File(st.localPath!).existsSync();
        if (have) {
          already++; // WreckBox has this track already: the extra copy stays where it is
          continue;
        }
        final r = await store.organise(f.path, source: 'scan', trackID: tid);
        r.startsWith('Added') ? filed++ : failed++;
      } else {
        (await moveInto(f.path, foundDir)) != null ? found++ : failed++;
      }
    }
    line = '$filed playlist tracks filed · $found other tracks in Tracks/Found'
        '${already > 0 ? ' · $already already in WreckBox (left where they are)' : ''}'
        '${failed > 0 ? ' · $failed couldn\'t be moved' : ''}';
    store.log('scan', 'Scan moved tracks in: $line');
    await store.save();
    groups = [];
    phase = ScanPhase.done;
    notifyListeners();
  }

  void reset() {
    if (phase == ScanPhase.review || phase == ScanPhase.done) {
      phase = ScanPhase.idle;
      groups = [];
      line = '';
      notifyListeners();
    }
  }

  /// Moves a file into `dir` under a free name; returns the new path.
  static Future<String?> moveInto(String path, Directory dir, {String? name}) async {
    try {
      await dir.create(recursive: true);
      final ext = p.extension(path);
      final stem = name ?? p.basenameWithoutExtension(path);
      var dest = p.join(dir.path, '$stem$ext');
      for (var n = 2; File(dest).existsSync() && dest != path; n++) {
        dest = p.join(dir.path, '$stem ($n)$ext');
      }
      if (dest == path) return dest;
      try {
        await File(path).rename(dest);
      } on FileSystemException {
        await File(path).copy(dest);
        await File(path).delete();
      }
      return dest;
    } catch (_) {
      return null;
    }
  }
}

// MARK: - Identify

class IdentifyEntry {
  String path;
  String status; // suggested, nomatch, accepted, skipped
  double score;
  String? title, album, year, genre, isrc, cover, recordingID;
  List<String> artists;
  String was;
  IdentifyEntry(this.path, this.status, {this.score = 0, this.artists = const [], this.was = ''});

  String get name => '${artists.join(', ')} – ${title ?? ''}';

  Map<String, dynamic> toJson() => {
        'path': path, 'status': status, 'score': score, 'title': title, 'artists': artists, 'album': album, 'year': year,
        'genre': genre, 'isrc': isrc, 'cover': cover, 'recordingID': recordingID, 'was': was,
      };

  factory IdentifyEntry.fromJson(Map<String, dynamic> j) => IdentifyEntry(j['path'], j['status'],
      score: (j['score'] as num?)?.toDouble() ?? 0, artists: List<String>.from(j['artists'] ?? const []), was: j['was'] ?? '')
    ..title = j['title']
    ..album = j['album']
    ..year = j['year']
    ..genre = j['genre']
    ..isrc = j['isrc']
    ..cover = j['cover']
    ..recordingID = j['recordingID'];
}

class Identifier extends ChangeNotifier {
  static final instance = Identifier();

  final entries = <String, IdentifyEntry>{};
  bool running = false, _stop = false, _loaded = false;
  int done = 0, total = 0;
  String line = '';

  static String get key => AppConfig.acoustidKey;
  static File get _file => File(p.join(AppPaths.cache.path, 'identify.json'));
  static const _ua = 'WreckBox/0.6 ( https://github.com/moloyb301-eng/wreckbox )';

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      for (final e in j.values) {
        final x = IdentifyEntry.fromJson(Map<String, dynamic>.from(e));
        entries[x.path] = x;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async => writeAtomic(_file, jsonEncode({for (final e in entries.entries) e.key: e.value.toJson()}));

  List<IdentifyEntry> get suggestions =>
      entries.values.where((e) => e.status == 'suggested' && File(e.path).existsSync()).toList()..sort((a, b) => b.score.compareTo(a.score));
  int get noMatch => entries.values.where((e) => e.status == 'nomatch').length;

  /// Tracks in Tracks/Found that haven't been tried yet.
  Future<List<String>> candidates() async {
    final dir = PhoneScanner.foundDir;
    if (!await dir.exists()) return [];
    return [
      await for (final f in dir.list(recursive: true))
        if (f is File && isAudio(f.path) && !entries.containsKey(f.path)) f.path,
    ];
  }

  Future<void> run(LibraryStore store) async {
    if (running) return;
    await load();
    final list = await candidates();
    if (list.isEmpty) return;
    running = true;
    _stop = false;
    total = list.length;
    for (var i = 0; i < list.length && !_stop; i++) {
      done = i + 1;
      line = p.basename(list[i]);
      notifyListeners();
      final tags = await Engine.readTags(list[i]);
      final was = [List<String>.from(tags['artists'] ?? const []).join(', '), tags['title'] ?? ''].where((s) => s.isNotEmpty).join(' – ');
      IdentifyEntry e;
      try {
        e = await identify(list[i]);
      } catch (_) {
        e = IdentifyEntry(list[i], 'nomatch');
      }
      e.was = was.isEmpty ? p.basenameWithoutExtension(list[i]) : was;
      entries[list[i]] = e;
      if (i % 10 == 9) await _save();
    }
    await _save();
    running = false;
    line = '';
    store.log('identify', 'Identify: ${suggestions.length} suggestions waiting, $noMatch not recognised');
    notifyListeners();
  }

  void cancel() => _stop = true;

  Future<void> skip(IdentifyEntry e) async {
    e.status = 'skipped';
    await _save();
    notifyListeners();
  }

  static DateTime _lastAcoustID = DateTime(2000), _lastMB = DateTime(2000);

  static Future<void> _pace(bool acoustid) async {
    final last = acoustid ? _lastAcoustID : _lastMB;
    final gap = Duration(milliseconds: acoustid ? 350 : 1100);
    final wait = gap - DateTime.now().difference(last);
    final next = DateTime.now().add(wait.isNegative ? Duration.zero : wait);
    acoustid ? _lastAcoustID = next : _lastMB = next;
    if (!wait.isNegative) await Future.delayed(wait);
  }

  static Future<IdentifyEntry> identify(String path) async {
    if (key.isEmpty) throw Exception('No AcoustID key');
    final fp = await Engine.fingerprint(path);
    if (fp['error'] != null) return IdentifyEntry(path, 'nomatch');
    await _pace(true);
    final res = await http.post(Uri.parse('https://api.acoustid.org/v2/lookup'), body: {
      'client': key,
      'meta': 'recordings releasegroups compress',
      'duration': '${fp['duration']}',
      'fingerprint': fp['fingerprint'],
    }).timeout(const Duration(seconds: 20));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (j['status'] != 'ok') throw Exception('AcoustID: ${j['error']?['message']}');
    final results = List<Map<String, dynamic>>.from(j['results'] ?? const [])
      ..sort((a, b) => ((b['score'] as num?) ?? 0).compareTo((a['score'] as num?) ?? 0));
    for (final r in results) {
      final score = (r['score'] as num?)?.toDouble() ?? 0;
      final recs = List<Map<String, dynamic>>.from(r['recordings'] ?? const []).where((x) => x['title'] != null && x['artists'] != null).toList();
      if (score < 0.5 || recs.isEmpty) continue;
      final rec = recs.first;
      final e = IdentifyEntry(path, 'suggested',
          score: score, artists: [for (final a in rec['artists'] as List) a['name'] as String])
        ..title = rec['title']
        ..recordingID = rec['id'];
      // An album or single over a compilation.
      final rgs = [for (final x in recs) ...List<Map<String, dynamic>>.from(x['releasegroups'] ?? const [])];
      final rg = rgs.where((g) => (g['secondarytypes'] as List?)?.isEmpty != false && ['Album', 'Single', 'EP'].contains(g['type'])).firstOrNull ??
          rgs.firstOrNull;
      e.album = rg?['title'];
      if (rg?['id'] != null) e.cover = 'https://coverartarchive.org/release-group/${rg!['id']}/front-500';
      try {
        await _musicBrainz(e);
      } catch (_) {}
      return e;
    }
    return IdentifyEntry(path, 'nomatch');
  }

  static Future<void> _musicBrainz(IdentifyEntry e) async {
    if (e.recordingID == null) return;
    await _pace(false);
    final res = await http.get(Uri.parse('https://musicbrainz.org/ws/2/recording/${e.recordingID}?inc=isrcs+genres&fmt=json'),
        headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 20));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    e.isrc = (j['isrcs'] as List?)?.firstOrNull;
    final d = j['first-release-date'] as String?;
    if (d != null && d.length >= 4) e.year = d.substring(0, 4);
    final genres = List<Map<String, dynamic>>.from(j['genres'] ?? const [])..sort((a, b) => ((b['count'] as num?) ?? 0).compareTo((a['count'] as num?) ?? 0));
    final g = genres.firstOrNull?['name'] as String?;
    e.genre = g?.split(' ').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
  }

  /// Writes the tags (with the cover), renames it "Artist - Title", and files it if it's a playlist track.
  Future<String> accept(IdentifyEntry e, LibraryStore store) async {
    if (e.title == null || e.artists.isEmpty || !File(e.path).existsSync()) return 'Gone';
    String? coverPath;
    if (e.cover != null) {
      try {
        final r = await http.get(Uri.parse(e.cover!)).timeout(const Duration(seconds: 20));
        if (r.statusCode == 200) {
          final f = File(p.join(AppPaths.artwork.path, 'mb_${e.recordingID ?? e.title.hashCode}.jpg'));
          await f.parent.create(recursive: true);
          await f.writeAsBytes(r.bodyBytes);
          coverPath = f.path;
        }
      } catch (_) {}
    }
    final res = await Engine.writeTags({
      'path': e.path, 'title': e.title, 'artists': e.artists, 'album': e.album, 'year': e.year, 'genre': e.genre,
      'isrc': e.isrc, 'cover': coverPath,
    });
    if (res['error'] != null) return 'Couldn\'t tag: ${res['error']}';
    final clean = '${e.artists.join(', ')} - ${e.title}'.replaceAll(RegExp(r'[/\\:*?"<>|]'), ' ');
    final moved = await PhoneScanner.moveInto(e.path, Directory(p.dirname(e.path)), name: clean) ?? e.path;
    entries.remove(e.path);
    entries[moved] = e
      ..path = moved
      ..status = 'accepted';
    await _save();
    store.log('identify', '${e.was} → ${e.name}');
    final r = await store.organise(moved, source: 'scan'); // into Tracks/ if it's one of your playlists' tracks
    notifyListeners();
    return r.startsWith('Added') ? r : 'Tagged ${e.name}';
  }

  Future<void> acceptAll(LibraryStore store, {double minScore = 0.9}) async {
    for (final e in suggestions.where((e) => e.score >= minScore).toList()) {
      await accept(e, store);
    }
  }
}
