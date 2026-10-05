// Tests against a COPY of a real WreckBox / DJ Library folder (never the original).
//   WRECKBOX_TEST_LIBRARY  folder with library.json, state.json, _cache/analysis.json, Tracks/
//   WRECKBOX_CORE_LIB      path to the Rust engine (core/target/release/libwreckbox_core.dylib)
// Run: flutter test test/app_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wreckbox/engine.dart';
import 'package:wreckbox/matcher.dart';
import 'package:wreckbox/models.dart';
import 'package:wreckbox/paths.dart';
import 'package:wreckbox/settings.dart';
import 'package:wreckbox/store.dart';
import 'package:wreckbox/ui/desktop.dart';
import 'package:wreckbox/ui/theme.dart';
import 'package:wreckbox/phone_sync.dart';
import 'package:wreckbox/services.dart';
import 'package:wreckbox/soulseek.dart';
import 'package:wreckbox/sources.dart';
import 'package:wreckbox/youtube.dart';

final src = Platform.environment['WRECKBOX_TEST_LIBRARY'] ?? '';
final hasLib = src.isNotEmpty && Directory(src).existsSync();
final hasEngine = File(Platform.environment['WRECKBOX_CORE_LIB'] ?? '').existsSync();

Future<Directory> copyLibrary() async {
  final tmp = await Directory.systemTemp.createTemp('wreckbox-test-');
  for (final f in ['library.json', 'state.json']) {
    await File(p.join(src, f)).copy(p.join(tmp.path, f));
  }
  await Directory(p.join(tmp.path, '_cache')).create();
  await File(p.join(src, '_cache', 'analysis.json')).copy(p.join(tmp.path, '_cache', 'analysis.json'));
  return tmp;
}

Future<void> loadFonts() async {
  for (final (family, file) in [('Urbanist', 'assets/fonts/Urbanist.ttf'), ('Doto', 'assets/fonts/Doto.ttf')]) {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(File(file).readAsBytesSync())));
    await loader.load();
  }
  final icons = File('${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())))).load();
  }
}

void main() {
  test('YouTube titles become artist + title', () {
    void check(String video, String channel, List<String> artists, String title) {
      final (a, t) = YouTubeImport.parseTitle(video, channel);
      expect(a, artists, reason: video);
      expect(t, title, reason: video);
    }
    check('Fred again.. - Danielle (smile on my face) [Official Video]', 'Fred again..', ['Fred again..'], 'Danielle (smile on my face)');
    check('Innerbloom', 'RÜFÜS DU SOL - Topic', ['RÜFÜS DU SOL'], 'Innerbloom');
    check('Skrillex & BEAM - Selecta (Official Visualizer) | OWSLA', 'Skrillex', ['Skrillex', 'BEAM'], 'Selecta');
    check('Mirage (Lyrics)', 'MPH Music', ['MPH'], 'Mirage');
    expect(YouTubeImport.parseIsoDuration('PT3M20S'), 200000);
    expect(YouTubeImport.parseIsoDuration('PT1H2S'), 3602000);
  });

  test('a song in both Spotify and YouTube playlists becomes one library entry', () {
    final lib = Sources.build('me', [
      SourcePlaylist('Bangers', 'sp1', false, [SourceTrack(spotifyID: 'abc', isrc: 'USRC1', name: 'Selecta', artists: ['Skrillex', 'BEAM'], durationMs: 190000)]),
      SourcePlaylist('YT: Gym', 'yt1', false, [
        SourceTrack(youtubeID: 'v1', name: 'Selecta', artists: ['Skrillex'], durationMs: 201000), // music video, longer
        SourceTrack(youtubeID: 'v2', name: 'Some YouTube Only Song', artists: ['Someone']),
      ]),
    ]);
    expect(lib.tracks.length, 2);
    final selecta = lib.tracks.firstWhere((t) => t.title == 'Selecta');
    expect(selecta.id, 'USRC1');
    expect(selecta.playlists, ['Bangers', 'YT: Gym']);
    expect(lib.tracks.firstWhere((t) => t.title != 'Selecta').id, 'youtube:v2');
  });

  test('importing YouTube into a library made before sources keeps the Spotify playlists', () async {
    final tmp = await copyLibrary();
    await AppPaths.init(overrideRoot: tmp.path);
    final before = LibraryStore();
    await before.load();
    final lib = await Sources.save('youtube', '', [SourcePlaylist('YT: Test', 'x', false, [SourceTrack(youtubeID: 'zz', name: 'New Song', artists: ['New Artist'])])]);
    expect(lib.playlists.where((p) => !p.name.startsWith('YT:')).length, before.library!.playlists.length);
    expect(lib.tracks.length, before.library!.tracks.length + 1);
    // Track ids survive, so download state still lines up.
    final ids = {for (final t in lib.tracks) t.id};
    expect(before.state.tracks.keys.where(ids.contains).length, before.state.tracks.length);
  }, skip: !hasLib);

  test('reads the Mac app\'s library, state and analysis files', () async {
    final tmp = await copyLibrary();
    await AppPaths.init(overrideRoot: tmp.path);
    final store = LibraryStore();
    await store.load();
    final macLib = jsonDecode(File(p.join(src, 'library.json')).readAsStringSync());
    final macState = jsonDecode(File(p.join(src, 'state.json')).readAsStringSync());
    expect(store.loadError, isNull);
    expect(store.library!.tracks.length, (macLib['tracks'] as List).length);
    expect(store.library!.playlists.length, (macLib['playlists'] as List).length);
    expect(store.state.tracks.length, (macState['tracks'] as Map).length);
    expect(store.count(TrackStatus.downloaded), (macState['tracks'] as Map).values.where((v) => v['status'] == 'downloaded').length);
    expect(store.analysis, isNotEmpty);
    // Round trip: saving and reloading keeps every track state.
    await store.save();
    final again = LibraryStore();
    await again.load();
    expect(again.state.tracks.length, store.state.tracks.length);
  }, skip: !hasLib);

  test('matcher finds downloaded tracks from their file names', () async {
    final tmp = await copyLibrary();
    await AppPaths.init(overrideRoot: tmp.path);
    final store = LibraryStore();
    await store.load();
    final m = TrackMatcher(store.library!.tracks);
    var hits = 0, total = 0;
    for (final e in store.state.tracks.entries.where((e) => e.value.status == TrackStatus.downloaded && e.value.source == 'soulseek').take(40)) {
      total++;
      final idx = m.match(FileFacts(path: e.value.localPath!));
      if (idx != null && store.library!.tracks[idx].id == e.key) hits++;
    }
    expect(total, greaterThan(0));
    expect(hits / total, greaterThan(0.9), reason: '$hits of $total matched by file name alone');
  }, skip: !hasLib);

  test('engine analyses a real track through FFI', () async {
    final track = Directory(p.join(src, 'Tracks')).listSync().whereType<File>().firstWhere((f) => isAudio(f.path));
    final r = await Engine.analyze(track.path);
    expect(r['error'], isNull);
    expect(r['bpm'], isA<num>());
    expect(r['camelot'], isA<String>());
  }, skip: !(hasLib && hasEngine));

  test('organiser: junk-named download → analysed, tagged, renamed, filed', () async {
    final tmp = await copyLibrary();
    await AppPaths.init(overrideRoot: tmp.path);
    final store = LibraryStore();
    await store.load();
    // A Soulseek FLAC we have, copied into a fake Downloads folder under a junk name.
    final entry = store.state.tracks.entries.firstWhere((e) => e.value.status == TrackStatus.downloaded && (e.value.localPath ?? '').endsWith('.flac') && File(e.value.localPath!).existsSync());
    final t = store.track(entry.key)!;
    store.state.tracks.remove(entry.key); // pretend we don't have it
    final downloads = Directory(p.join(tmp.path, 'Downloads'))..createSync();
    final junk = await File(entry.value.localPath!).copy(p.join(downloads.path, 'track_01 (1).flac'));
    final msg = await store.organise(junk.path, source: 'downloads');
    expect(msg, startsWith('Added'));
    final st = store.state.tracks[entry.key]!;
    expect(st.status, TrackStatus.downloaded);
    expect(p.basename(st.localPath!), '${t.fileName}.flac');
    expect(File(junk.path).existsSync(), isFalse);
    final tags = await Engine.readTags(st.localPath!);
    expect(tags['title'], t.title);
    expect(tags['isrc'], t.isrc);
    expect(tags['bpm'], isA<num>());
    expect(tags['key'], isA<String>());
  }, skip: !(hasLib && hasEngine));

  testWidgets('desktop layout renders with the real library', (tester) async {
    await loadFonts();
    final tmp = await tester.runAsync(copyLibrary);
    await tester.runAsync(() => AppPaths.init(overrideRoot: tmp!.path));
    final store = LibraryStore();
    await tester.runAsync(store.load);
    Settings.current = Settings();
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      theme: T.theme(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: DesktopShell(store: store, soulseek: Soulseek(store), phoneServer: PhoneSyncServer(store), dropbox: Dropbox(store))),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Your crate'), findsOneWidget);
    expect(find.text('All tracks'), findsOneWidget);
    expect(tester.takeException(), isNull); // no overflow / layout errors
    // Screenshots for design review: run with --update-goldens to (re)write test/goldens/*.png.
    if (autoUpdateGoldenFiles) await expectLater(find.byType(DesktopShell), matchesGoldenFile('goldens/desktop_home.png'));
  }, skip: !hasLib);
}
