// Playlist import from CSV files — no Spotify / Google developer keys needed.
//
// Understands the common export formats (column names are matched loosely):
//   • Exportify (Spotify):        Track URI, Track Name, Artist Name(s), Album Name, Release Date, Duration (ms), Added At, ISRC?
//   • TuneMyMusic (Spotify, YouTube Music, …): Track name, Artist name, Album, Playlist name, ISRC?, …
//   • Google Takeout YouTube playlists: Video ID, Playlist Video Creation Timestamp — titles are looked up through
//     YouTube's public oEmbed endpoint (no key).
//   • Any CSV with title + artist columns.
//
// Every track is then enriched from free catalogues (MusicBrainz → ISRC; Deezer by ISRC → cover, album) so matching,
// Soulseek searches and tag writing work as well as with the Spotify API.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'models.dart';
import 'paths.dart';
import 'sources.dart';
import 'youtube.dart';

class CsvImportResult {
  final List<SourcePlaylist> playlists;
  final int tracks, enriched;
  CsvImportResult(this.playlists, this.tracks, this.enriched);
}

class CsvImport {
  // MARK: CSV parsing (RFC 4180: quoted fields, doubled quotes, newlines inside quotes)

  static List<List<String>> parseCsv(String text) {
    if (text.startsWith('﻿')) text = text.substring(1);
    final rows = <List<String>>[];
    var row = <String>[], field = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        row.add(field.toString());
        field = StringBuffer();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(field.toString());
        field = StringBuffer();
        if (row.any((f) => f.isNotEmpty)) rows.add(row);
        row = <String>[];
      } else {
        field.write(c);
      }
    }
    row.add(field.toString());
    if (row.any((f) => f.isNotEmpty)) rows.add(row);
    return rows;
  }

  static String _key(String h) => h.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Index of the first header matching any of the candidate names (compared without spaces / punctuation).
  static int? _col(List<String> header, List<String> names) {
    final keys = header.map(_key).toList();
    for (final n in names) {
      final i = keys.indexOf(_key(n));
      if (i >= 0) return i;
    }
    return null;
  }

  static int? _durationMs(String v) {
    v = v.trim();
    if (v.isEmpty) return null;
    if (v.contains(':')) {
      final parts = v.split(':').map((x) => int.tryParse(x.trim()) ?? 0).toList();
      var s = 0;
      for (final x in parts) {
        s = s * 60 + x;
      }
      return s * 1000;
    }
    final n = double.tryParse(v);
    if (n == null) return null;
    return n > 20000 ? n.round() : (n * 1000).round(); // ms or seconds
  }

  static List<String> _splitArtists(String v) =>
      // Exportify / TuneMyMusic separate artists with commas or semicolons. ("Tyler, The Creator" is kept whole.)
      v.replaceAll('Tyler, The Creator', 'Tyler\u0000 The Creator').split(RegExp(r'\s*[;|,]\s*')).map((a) => a.replaceAll('\u0000', ',').trim()).where((a) => a.isNotEmpty).toList();

  /// Parses one CSV file into playlists (one per "Playlist name" value, or one named after the file).
  /// `lookupYoutube` resolves Takeout video ids to titles.
  static Future<List<SourcePlaylist>> parseFile(String path, {bool lookupYoutube = true, void Function(String)? log}) async {
    final rows = parseCsv(await File(path).readAsString());
    if (rows.length < 2) return [];
    final h = rows.first;
    final cTitle = _col(h, ['Track Name', 'Track name', 'Title', 'Song', 'Name', 'Song Name']);
    final cArtist = _col(h, ['Artist Name(s)', 'Artist name', 'Artist', 'Artists', 'Artist Names']);
    final cAlbum = _col(h, ['Album Name', 'Album', 'Album title']);
    final cIsrc = _col(h, ['ISRC']);
    final cDur = _col(h, ['Duration (ms)', 'Duration', 'Length', 'Time']);
    final cDate = _col(h, ['Release Date', 'Album Release Date', 'Year']);
    final cAdded = _col(h, ['Added At', 'Date Added', 'Playlist Video Creation Timestamp', 'Added']);
    final cUri = _col(h, ['Track URI', 'Spotify - id', 'Spotify ID', 'Spotify URI']);
    final cPlaylist = _col(h, ['Playlist name', 'Playlist']);
    final cVideo = _col(h, ['Video ID', 'YouTube ID', 'Video Id', 'Youtube - id']);
    final cImage = _col(h, ['Album Image URL', 'Image URL', 'Artwork']);

    final fileName = p.basenameWithoutExtension(path).replaceAll(RegExp(r'[_-]+'), ' ').trim();
    final byPlaylist = <String, List<SourceTrack>>{};
    var done = 0;
    for (final r in rows.skip(1)) {
      String? get(int? c) => c != null && c < r.length && r[c].trim().isNotEmpty ? r[c].trim() : null;
      var title = get(cTitle);
      var artists = get(cArtist) != null ? _splitArtists(get(cArtist)!) : <String>[];
      final video = get(cVideo);
      if ((title == null || artists.isEmpty) && video != null && lookupYoutube) {
        final o = await _oembed(video);
        if (o != null) {
          final (a, t) = YouTubeImport.parseTitle(o.$1, o.$2);
          title ??= t;
          if (artists.isEmpty) artists = a;
        }
        if (++done % 25 == 0) log?.call('  looked up $done YouTube videos…');
      }
      if (title == null || title.isEmpty) continue;
      final uri = get(cUri);
      final spotifyID = uri == null ? null : (uri.startsWith('spotify:track:') ? uri.substring(14) : (RegExp(r'^[A-Za-z0-9]{22}$').hasMatch(uri) ? uri : null));
      final playlist = get(cPlaylist) ?? fileName;
      byPlaylist.putIfAbsent(playlist, () => []).add(SourceTrack(
            name: title,
            artists: artists.isEmpty ? ['Unknown Artist'] : artists,
            album: get(cAlbum),
            isrc: get(cIsrc)?.toUpperCase(),
            durationMs: get(cDur) == null ? null : _durationMs(get(cDur)!),
            releaseDate: get(cDate),
            addedAt: get(cAdded),
            spotifyID: spotifyID,
            youtubeID: video,
            artworkURL: get(cImage),
          ));
    }
    return [for (final e in byPlaylist.entries) SourcePlaylist(e.key, null, false, e.value)];
  }

  static Future<(String, String)?> _oembed(String videoId) async {
    try {
      final r = await http
          .get(Uri.parse('https://www.youtube.com/oembed?format=json&url=${Uri.encodeComponent('https://www.youtube.com/watch?v=$videoId')}'))
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null; // private / deleted video
      final j = jsonDecode(r.body);
      return (j['title'] as String? ?? '', j['author_name'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  // MARK: Catalogue enrichment (free, no keys)
  //
  // MusicBrainz (worldwide, 1 request / s) finds the recording and its ISRC; Deezer's ISRC lookup then gives the
  // cover, album and duration (Deezer *search* hides results outside its regions, ISRC lookups don't); the
  // Cover Art Archive is the fallback cover. Results are cached, so re-imports are instant and give the same ids.

  static File get _cacheFile => File(p.join(AppPaths.cache.path, 'catalogue_lookup.json'));
  static const _ua = {'User-Agent': 'WreckBox/0.1 (https://github.com/moloyb301-eng/wreckbox-releases)'};
  static DateTime _lastMb = DateTime.fromMillisecondsSinceEpoch(0);
  static const _variants = ['live', 'remix', 'edit', 'acoustic', 'instrumental', 'karaoke', 'video', 'cover', 'sped', 'slowed', 'remaster'];

  static String _clean(String t) => normalized(t.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*(feat|ft|with)\.?[^\)\]]*[\)\]]', caseSensitive: false), ''));

  static Future<Map<String, dynamic>?> _musicBrainz(SourceTrack t) async {
    final wait = const Duration(milliseconds: 1100) - DateTime.now().difference(_lastMb);
    if (!wait.isNegative) await Future.delayed(wait);
    _lastMb = DateTime.now();
    String esc(String s) => s.replaceAll('"', r'\"');
    final title = t.name.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*(feat|ft|with)\.?[^\)\]]*[\)\]]', caseSensitive: false), '');
    final q = 'recording:"${esc(title)}" AND artist:"${esc(t.artists.first)}"';
    final r = await http.get(Uri.https('musicbrainz.org', '/ws/2/recording', {'query': q, 'fmt': 'json', 'limit': '8', 'inc': 'isrcs'}), headers: _ua).timeout(const Duration(seconds: 15));
    if (r.statusCode == 503) throw const SocketException('MusicBrainz busy'); // rate limited: treat like offline, retry later
    if (r.statusCode != 200) return null;
    final want = _clean(t.name);
    final wantWords = want.split(' ').toSet();
    Map<String, dynamic>? best;
    double bestScore = -1;
    for (final rec in (jsonDecode(r.body)['recordings'] as List? ?? const []).cast<Map<String, dynamic>>()) {
      final got = _clean(rec['title'] ?? '');
      if ((rec['score'] ?? 0) < 85 || !(got == want || got.startsWith(want) || want.startsWith(got))) continue;
      final gotWords = got.split(' ').toSet();
      if (_variants.any((v) => gotWords.contains(v) && !wantWords.contains(v))) continue;
      final isrcs = List<String>.from(rec['isrcs'] ?? const []);
      final len = rec['length'] as int?;
      var score = (rec['score'] as num).toDouble() + (isrcs.isNotEmpty ? 50 : 0) + (got == want ? 10 : 0);
      if (len != null && t.durationMs != null) score -= ((len - t.durationMs!).abs() / 1000).clamp(0, 60);
      if (score > bestScore) {
        bestScore = score;
        final release = ((rec['releases'] as List?) ?? const []).cast<Map>().firstOrNull;
        // Only trust the ISRC when the length agrees (otherwise it may be another release of the song).
        final lengthOk = len == null || t.durationMs == null || (len - t.durationMs!).abs() <= 5000;
        final isrc = lengthOk ? isrcs.firstOrNull : null;
        // A length is only trusted from a match confirmed by an ISRC: a wrong length would make Soulseek reject
        // the right file (it filters by duration), while a missing one just skips that check.
        best = {'isrc': isrc, 'durationMs': isrc != null ? len : null, 'album': release?['title'], 'releaseId': release?['id'], 'date': release?['date']};
      }
    }
    return best;
  }

  static Future<Map<String, dynamic>?> _deezerByIsrc(String isrc) async {
    final r = await http.get(Uri.parse('https://api.deezer.com/track/isrc:$isrc')).timeout(const Duration(seconds: 10));
    final d = jsonDecode(r.body) as Map;
    if (d['error'] != null) return null;
    return {'cover': (d['album'] as Map?)?['cover_big'], 'album': (d['album'] as Map?)?['title'], 'durationMs': d['duration'] == null ? null : (d['duration'] as num).round() * 1000, 'date': d['release_date']};
  }

  static Future<SourceTrack> enrich(SourceTrack t, Map<String, dynamic> cache) async {
    if (t.isrc != null && t.artworkURL != null && t.durationMs != null) return t;
    final key = normalized('${t.artists.first} ${t.name}');
    Map<String, dynamic>? hit;
    if (cache.containsKey(key)) {
      hit = (cache[key] as Map?)?.cast<String, dynamic>();
    } else {
      try {
        hit = await _musicBrainz(t);
        final isrc = t.isrc ?? hit?['isrc'];
        if (isrc != null) {
          final dz = await _deezerByIsrc(isrc);
          // Deezer's data for this exact ISRC wins for length and cover; MusicBrainz fills the gaps.
          hit = {...?hit, 'isrc': isrc, if (dz != null) ...{for (final e in dz.entries) if (e.value != null && (hit?[e.key] == null || e.key == 'cover' || e.key == 'durationMs')) e.key: e.value}};
        }
        if (hit != null && hit['cover'] == null && hit['releaseId'] != null) {
          hit['cover'] = 'https://coverartarchive.org/release/${hit['releaseId']}/front-500';
        }
        cache[key] = hit; // null = not found (cached so it isn't asked again)
      } on SocketException {
        return t; // offline / busy: keep what we have, try again next import
      } on http.ClientException {
        return t;
      } catch (_) {
        return t;
      }
    }
    if (hit == null) return t;
    return SourceTrack(
      spotifyID: t.spotifyID,
      youtubeID: t.youtubeID,
      name: t.name,
      artists: t.artists,
      album: t.album ?? hit['album'],
      releaseDate: t.releaseDate ?? hit['date'],
      isrc: t.isrc ?? (hit['isrc'] as String?)?.toUpperCase(),
      durationMs: t.durationMs ?? hit['durationMs'],
      addedAt: t.addedAt,
      artworkURL: t.artworkURL ?? hit['cover'],
    );
  }

  /// Imports CSV files: parse, enrich, and add / replace those playlists in the "csv" source.
  static Future<CsvImportResult> run(List<String> paths, void Function(String) log) async {
    final parsed = <SourcePlaylist>[];
    for (final path in paths) {
      log('Reading ${p.basename(path)}…');
      final pls = await parseFile(path, log: log);
      for (final pl in pls) {
        log('  ${pl.name}: ${pl.tracks.length} tracks');
      }
      parsed.addAll(pls);
    }
    final cache = <String, dynamic>{};
    try {
      cache.addAll(jsonDecode(await _cacheFile.readAsString()));
    } catch (_) {}
    var n = 0, enriched = 0;
    final total = parsed.fold<int>(0, (a, pl) => a + pl.tracks.length);
    final out = <SourcePlaylist>[];
    for (final pl in parsed) {
      final tracks = <SourceTrack>[];
      for (final t in pl.tracks) {
        final e = await enrich(t, cache);
        if (e.isrc != null && t.isrc == null) enriched++;
        tracks.add(e);
        if (++n % 20 == 0) {
          log('Looking up ISRC and covers: $n/$total…');
          await writeAtomic(_cacheFile, jsonEncode(cache));
        }
      }
      out.add(SourcePlaylist(pl.name, pl.id, false, tracks));
    }
    await writeAtomic(_cacheFile, jsonEncode(cache));

    // Merge with earlier CSV imports: a re-imported playlist replaces the old version of itself.
    final existing = await Sources.load('csv');
    final names = {for (final pl in out) pl.name};
    final merged = [...existing.where((pl) => !names.contains(pl.name)), ...out];
    await Sources.save('csv', '', merged);
    log('Imported ${out.length} playlists, $total tracks ($enriched matched to the catalogue).');
    return CsvImportResult(out, total, enriched);
  }
}
