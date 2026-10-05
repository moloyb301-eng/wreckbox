import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:wreckbox/csv_import.dart';
import 'package:wreckbox/paths.dart';
import 'package:wreckbox/sources.dart';

/// Tests that call live catalogues (MusicBrainz, Deezer, YouTube) only run when asked: WRECKBOX_NETWORK_TESTS=1.
final networkTests = Platform.environment['WRECKBOX_NETWORK_TESTS'] == '1';

void main() {
  test('CSV parser handles quotes, commas and newlines inside fields', () {
    final rows = CsvImport.parseCsv('a,b\n"x, y","say ""hi""\nthere"\r\n');
    expect(rows, [['a', 'b'], ['x, y', 'say "hi"\nthere']]);
  });

  test('Exportify, TuneMyMusic and Takeout files become playlists', () async {
    final ex = await CsvImport.parseFile('test/fixtures/exportify_bangers.csv', lookupYoutube: false);
    expect(ex.single.name, 'exportify bangers');
    expect(ex.single.tracks.first.artists, ['Skrillex', 'BEAM']);
    expect(ex.single.tracks.first.spotifyID, '0FJ6sfZPS9zNxRz8OHwnKy');
    expect(ex.single.tracks.first.durationMs, 190000);
    final tm = await CsvImport.parseFile('test/fixtures/tunemymusic.csv', lookupYoutube: false);
    expect({for (final pl in tm) pl.name: pl.tracks.length}, {'Chill': 2, 'Gym': 1});
    expect(tm.firstWhere((p) => p.name == 'Gym').tracks.single.artists, ['MPH', 'Skrillex']);
  });

  test('full import with Deezer + YouTube lookups (network)', () async {
    final tmp = await Directory.systemTemp.createTemp('wreckbox-csv-');
    await AppPaths.init(overrideRoot: tmp.path);
    final lines = <String>[];
    final r = await CsvImport.run(['test/fixtures/exportify_bangers.csv', 'test/fixtures/Takeout - Liked videos.csv'], lines.add);
    print(lines.join('\n'));
    final all = [for (final pl in r.playlists) ...pl.tracks];
    for (final t in all) {
      print('${t.artists.join(", ")} – ${t.name} | isrc ${t.isrc} | cover ${t.artworkURL != null} | ${t.durationMs}');
    }
    final rick = all.firstWhere((t) => t.youtubeID == 'dQw4w9WgXcQ');
    expect(rick.artists, ['Rick Astley']);
    expect(rick.name, 'Never Gonna Give You Up');
    // Any ISRC found must be the real one (Spotify's); a wrong-length version must not lend its ISRC.
    final real = {'Selecta': 'USAT22300854', 'Danielle (smile on my face)': 'GBAHS2300020'};
    // A song can have several valid ISRCs (single vs album release); they share the label's registrant prefix.
    for (final t in all.where((t) => real.containsKey(t.name) && t.isrc != null)) {
      expect(t.isrc!.substring(0, 5), real[t.name]!.substring(0, 5), reason: t.name);
    }
    // Lengths come only from ISRC-confirmed matches (Deezer's length for that ISRC).
    for (final t in all.where((t) => t.durationMs != null && t.name != 'Selecta' && t.name != 'Danielle (smile on my face)')) {
      expect(t.isrc, isNotNull, reason: '${t.name}: length without a confirmed match');
    }
    expect(all.where((t) => t.artworkURL != null).length, greaterThanOrEqualTo(2)); // live catalogues are sometimes busy
    final lib = await Sources.rebuild();
    expect(lib.tracks.length, 3);
  }, skip: !networkTests, timeout: const Timeout(Duration(minutes: 2)));
}
