// Library sources. Each importer (Spotify, YouTube) saves its playlists to _sources/<kind>.json; the library is
// rebuilt from all of them, so re-importing one source never drops the others. One library entry per
// recording (ISRC → Spotify id → artist/title/duration), tagged with every playlist it appears in.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'models.dart';
import 'paths.dart';

class SourceTrack {
  final String? spotifyID, youtubeID, isrc, album, releaseDate, addedAt, artworkURL;
  final String name;
  final List<String> artists;
  final int? durationMs;
  final bool isLocal;

  SourceTrack({
    this.spotifyID,
    this.youtubeID,
    required this.name,
    required this.artists,
    this.album,
    this.releaseDate,
    this.isrc,
    this.durationMs,
    this.isLocal = false,
    this.addedAt,
    this.artworkURL,
  });

  factory SourceTrack.fromJson(Map<String, dynamic> j) => SourceTrack(
        spotifyID: j['spotifyID'],
        youtubeID: j['youtubeID'],
        name: j['name'] ?? '',
        artists: List<String>.from(j['artists'] ?? const []),
        album: j['album'],
        releaseDate: j['releaseDate'],
        isrc: j['isrc'],
        durationMs: j['durationMs'],
        isLocal: j['isLocal'] ?? false,
        addedAt: j['addedAt'],
        artworkURL: j['artworkURL'],
      );

  Map<String, dynamic> toJson() => {
        if (spotifyID != null) 'spotifyID': spotifyID,
        if (youtubeID != null) 'youtubeID': youtubeID,
        'name': name,
        'artists': artists,
        if (album != null) 'album': album,
        if (releaseDate != null) 'releaseDate': releaseDate,
        if (isrc != null) 'isrc': isrc,
        if (durationMs != null) 'durationMs': durationMs,
        if (isLocal) 'isLocal': true,
        if (addedAt != null) 'addedAt': addedAt,
        if (artworkURL != null) 'artworkURL': artworkURL,
      };
}

class SourcePlaylist {
  final String name;
  final String? id;
  final bool collaborative;
  final List<SourceTrack> tracks;
  SourcePlaylist(this.name, this.id, this.collaborative, this.tracks);

  factory SourcePlaylist.fromJson(Map<String, dynamic> j) => SourcePlaylist(
      j['name'] ?? '', j['id'], j['collaborative'] ?? false, [for (final t in (j['tracks'] as List? ?? const [])) SourceTrack.fromJson(Map<String, dynamic>.from(t))]);
  Map<String, dynamic> toJson() => {'name': name, if (id != null) 'id': id, 'collaborative': collaborative, 'tracks': [for (final t in tracks) t.toJson()]};
}

class Sources {
  static Directory get dir => Directory(p.join(AppPaths.root.path, '_sources'));

  /// Playlists previously saved by one importer (empty if none).
  static Future<List<SourcePlaylist>> load(String kind) async {
    final f = File(p.join(dir.path, '$kind.json'));
    if (!await f.exists()) return [];
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    return [for (final pl in (j['playlists'] as List? ?? const [])) SourcePlaylist.fromJson(Map<String, dynamic>.from(pl))];
  }

  /// Saves one importer's playlists and rebuilds library.json from every source.
  static Future<Library> save(String kind, String user, List<SourcePlaylist> playlists) async {
    await _preserveLegacy(kind);
    await writeAtomic(File(p.join(dir.path, '$kind.json')),
        const JsonEncoder.withIndent(' ').convert({'kind': kind, 'user': user, 'savedAt': isoSeconds(DateTime.now()), 'playlists': [for (final pl in playlists) pl.toJson()]}));
    return rebuild();
  }

  /// A library.json made before sources existed (the Mac app, or one copied from the computer) has no
  /// _sources/spotify.json. Keep it as a source so importing YouTube doesn't drop those playlists.
  static Future<void> _preserveLegacy(String kind) async {
    if (kind == 'spotify' || await File(p.join(dir.path, 'spotify.json')).exists()) return;
    final legacy = File(p.join(dir.path, 'library-legacy.json'));
    if (await legacy.exists() || !await AppPaths.libraryFile.exists()) return;
    final lib = Library.fromJson(jsonDecode(await AppPaths.libraryFile.readAsString()));
    final byId = {for (final t in lib.tracks) t.id: t};
    final pls = [
      for (final pl in lib.playlists)
        if (!pl.name.startsWith('YT: '))
          SourcePlaylist(pl.name, pl.spotifyID, pl.collaborative, [
            for (final id in pl.trackIDs)
              if (byId[id] case final t?)
                SourceTrack(
                  spotifyID: t.spotifyIDs.firstOrNull, name: t.title, artists: t.artists, album: t.album,
                  releaseDate: t.year, isrc: t.isrc, durationMs: t.durationMs, addedAt: t.firstAdded, artworkURL: t.artworkURL,
                ),
          ]),
    ];
    await writeAtomic(legacy, jsonEncode({'kind': 'spotify-legacy', 'user': lib.spotifyUser, 'playlists': [for (final pl in pls) pl.toJson()]}));
  }

  static Future<Library> rebuild() async {
    final all = <(String, List<SourcePlaylist>)>[];
    String user = '';
    if (await dir.exists()) {
      final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList()
        ..sort((a, b) => _order(a).compareTo(_order(b)));
      for (final f in files) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        if ((j['kind'] ?? '').toString().startsWith('spotify')) user = j['user'] ?? user;
        all.add((j['kind'] ?? '', [for (final pl in (j['playlists'] as List? ?? const [])) SourcePlaylist.fromJson(Map<String, dynamic>.from(pl))]));
      }
    }
    final lib = build(user, [for (final (_, pls) in all) ...pls]);
    await writeAtomic(AppPaths.libraryFile, const JsonEncoder.withIndent('  ').convert(lib.toJson()));
    return lib;
  }

  /// Spotify first (its titles and ids win when a song is in several sources), then the rest.
  static String _order(File f) {
    final n = p.basename(f.path);
    return n == 'spotify.json' ? '0' : n == 'library-legacy.json' ? '1' : '2$n';
  }

  static Library build(String user, List<SourcePlaylist> sources) {
    final tracks = <LibraryTrack>[];
    final index = <String, int>{};
    final playlists = <LibraryPlaylist>[];
    final seenNames = <String, int>{};
    for (final src in sources) {
      var name = src.name.trim().isEmpty ? 'Untitled' : src.name.trim();
      seenNames[name] = (seenNames[name] ?? 0) + 1;
      if (seenNames[name]! > 1) name = '$name (${seenNames[name]})';
      final ids = <String>[];
      for (final t in src.tracks) {
        if (t.isLocal || t.name.isEmpty) continue;
        // Loose key without duration so a YouTube upload (different length) still merges with the Spotify track.
        final loose = 'nt:${normalized(t.artists.isEmpty ? '' : t.artists.first)}|${normalized(t.name)}';
        final fuzzy = 'na:${normalized(t.artists.isEmpty ? '' : t.artists.first)}|${normalized(t.name)}|${(t.durationMs ?? 0) ~/ 5000}';
        final keys = [
          if (t.isrc != null) 'isrc:${t.isrc!.toUpperCase()}',
          if (t.spotifyID != null) 'sp:${t.spotifyID}',
          if (t.youtubeID != null) 'yt:${t.youtubeID}',
          fuzzy,
          loose,
        ];
        // Strong keys (ISRC, Spotify / YouTube id) merge anything. Artist + title keys only merge when one side
        // has no ISRC (e.g. a YouTube upload) — two recordings with different ISRCs (radio edit vs original) stay apart.
        final strong = keys.where((k) => !k.startsWith('na:') && !k.startsWith('nt:')).map((k) => index[k]).whereType<int>().firstOrNull;
        final weak = keys.where((k) => k.startsWith('na:') || k.startsWith('nt:')).map((k) => index[k]).whereType<int>()
            .where((i) => t.isrc == null || tracks[i].isrc == null).firstOrNull;
        final hit = strong ?? weak;
        if (hit != null) {
          final old = tracks[hit];
          tracks[hit] = LibraryTrack(
            id: old.id,
            artists: old.artists,
            title: old.title,
            album: old.album ?? t.album,
            year: old.year,
            isrc: old.isrc ?? t.isrc?.toUpperCase(),
            spotifyIDs: {...old.spotifyIDs, if (t.spotifyID != null) t.spotifyID!}.toList(),
            durationMs: old.durationMs ?? t.durationMs,
            playlists: old.playlists.contains(name) ? old.playlists : [...old.playlists, name],
            firstAdded: [old.firstAdded, t.addedAt].whereType<String>().fold<String?>(null, (a, b) => a == null || b.compareTo(a) < 0 ? b : a),
            fileName: old.fileName,
            artworkURL: old.artworkURL ?? t.artworkURL,
          );
          for (final k in keys) {
            index.putIfAbsent(k, () => hit);
          }
          ids.add(old.id);
          continue;
        }
        final tid = t.isrc?.toUpperCase() ?? (t.spotifyID != null ? 'spotify:${t.spotifyID}' : (t.youtubeID != null ? 'youtube:${t.youtubeID}' : fuzzy));
        tracks.add(LibraryTrack(
          id: tid,
          artists: t.artists,
          title: t.name,
          album: t.album,
          year: t.releaseDate != null && t.releaseDate!.length >= 4 ? t.releaseDate!.substring(0, 4) : null,
          isrc: t.isrc?.toUpperCase(),
          spotifyIDs: [if (t.spotifyID != null) t.spotifyID!],
          durationMs: t.durationMs,
          playlists: [name],
          firstAdded: t.addedAt,
          fileName: safeFileName('${t.artists.join(', ')} - ${t.name}'),
          artworkURL: t.artworkURL,
        ));
        for (final k in keys) {
          index.putIfAbsent(k, () => tracks.length - 1);
        }
        ids.add(tid);
      }
      playlists.add(LibraryPlaylist(name: name, spotifyID: src.id, collaborative: src.collaborative, trackIDs: ids));
    }
    return Library(builtAt: DateTime.now(), spotifyUser: user, tracks: tracks, playlists: playlists);
  }
}
