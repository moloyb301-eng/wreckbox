// Matching audio files to library tracks — a port of the Mac app's Matcher (ISRC first, then artist +
// title from tags or "Artist - Title" file names, with a duration check).

import 'package:path/path.dart' as p;

import 'models.dart';

class FileFacts {
  final String path;
  final String? title, isrc;
  final List<String> artists;
  final double? durationSec;
  FileFacts({required this.path, this.title, this.artists = const [], this.isrc, this.durationSec});
  String get fileName => p.basename(path);
}

class TrackMatcher {
  final List<LibraryTrack> tracks;
  final _byISRC = <String, int>{};
  final _byTitle = <String, List<int>>{};

  TrackMatcher(this.tracks) {
    for (var i = 0; i < tracks.length; i++) {
      final t = tracks[i];
      if (t.isrc != null) _byISRC[t.isrc!.toUpperCase()] = i;
      _byTitle.putIfAbsent(cleanTitle(t.title), () => []).add(i);
    }
  }

  /// Strips noise that differs between Spotify titles and file tags / names, keeping remix / edit names.
  static String cleanTitle(String s) {
    var t = s.toLowerCase();
    for (final pattern in [
      r'[\(\[]\s*(feat|ft|with)\.?\s[^\)\]]*[\)\]]',
      r'\s(feat|ft)\.?\s.*$',
      r'[\(\[][^\)\]]*(official|visuali[sz]er|lyric|audio|video|free\s?d(ownload|l)|out now)[^\)\]]*[\)\]]',
      r'[\(\[]\s*original mix\s*[\)\]]',
      r'\s-\s(remaster(ed)?|original mix).*$',
    ]) {
      t = t.replaceAll(RegExp(pattern), '');
    }
    return normalized(t);
  }

  int? match(FileFacts f) {
    if (f.isrc != null && _byISRC.containsKey(f.isrc!.toUpperCase())) return _byISRC[f.isrc!.toUpperCase()];
    final guesses = <(String, String)>[];
    if (f.artists.isNotEmpty && f.title != null) guesses.add((f.artists.join(' '), f.title!));
    final stem = p.basenameWithoutExtension(f.path);
    final parts = stem.split(' - ');
    if (parts.length >= 2) {
      guesses.add((parts.first, parts.sublist(1).join(' - ')));
      guesses.add((parts.last, parts.sublist(0, parts.length - 1).join(' - ')));
    } else if (f.artists.isNotEmpty) {
      guesses.add((f.artists.join(' '), parts.first));
    }
    for (final (artist, title) in guesses) {
      final fileArtist = normalized(artist);
      final cands = (_byTitle[cleanTitle(title)] ?? const []).where((i) => tracks[i].artists.any((a) {
            final n = normalized(a);
            return n.isNotEmpty && (fileArtist.contains(n) || n.contains(fileArtist));
          }));
      int? best;
      double bestGap = double.infinity;
      for (final i in cands) {
        final gap = _gap(i, f);
        if (gap < bestGap) {
          bestGap = gap;
          best = i;
        }
      }
      if (best != null && (f.durationSec == null || tracks[best].durationMs == null || bestGap < 8)) return best;
    }
    return null;
  }

  double _gap(int i, FileFacts f) {
    final a = tracks[i].durationMs, b = f.durationSec;
    if (a == null || b == null) return 0;
    return (a / 1000 - b).abs();
  }
}

/// Keys that mix with Camelot code `c`: same, ±1 on the wheel, relative major / minor.
Set<String> compatibleKeys(String c) {
  final n = int.tryParse(c.substring(0, c.length - 1));
  if (n == null) return {};
  final letter = c[c.length - 1], other = letter == 'A' ? 'B' : 'A';
  final up = n % 12 + 1, down = (n + 10) % 12 + 1;
  return {'$n$letter', '$up$letter', '$down$letter', '$n$other'};
}

int camelotOrder(String? c) {
  if (c == null || c.isEmpty) return 999;
  final n = int.tryParse(c.substring(0, c.length - 1)) ?? 99;
  return n * 2 + (c.endsWith('B') ? 1 : 0);
}
