// "Scan this phone" and "Identify tracks" cards on the Organise tab (see scan.dart).

import 'package:flutter/material.dart';

import '../scan.dart';
import '../store.dart';
import 'theme.dart';

class ScanCards extends StatefulWidget {
  final LibraryStore store;
  const ScanCards({super.key, required this.store});
  @override
  State<ScanCards> createState() => _ScanCardsState();
}

class _ScanCardsState extends State<ScanCards> {
  final scanner = PhoneScanner.instance, id = Identifier.instance;
  int waiting = 0;
  final busy = <String>{};
  String note = '';

  @override
  void initState() {
    super.initState();
    _count();
  }

  Future<void> _count() async {
    await id.load();
    final n = (await id.candidates()).length;
    if (mounted) setState(() => waiting = n);
  }

  static String mb(int b) => b >= 1e9 ? '${(b / 1e9).toStringAsFixed(1)} GB' : '${(b / 1e6).round()} MB';

  Widget _progress(int done, int total, String line) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SizedBox(height: 8),
        LinearProgressIndicator(value: total == 0 ? null : done / total, color: T.lilac, backgroundColor: T.text3.withValues(alpha: 0.2)),
        const SizedBox(height: 6),
        Text('$done / $total · $line', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(12, FontWeight.w400, T.text2)),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([scanner, id]),
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _scanCard(),
        const SizedBox(height: 12),
        _identifyCard(),
      ]),
    );
  }

  Widget _scanCard() {
    final picked = scanner.groups.where((g) => scanner.picked.contains(g.name)).fold<int>(0, (a, g) => a + g.finds.length);
    return Glass(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const DotLabel('Scan this phone', color: T.text),
        const SizedBox(height: 6),
        Text('Finds music anywhere on this phone that isn\'t in WreckBox yet. Tracks from your playlists are tagged and filed '
            'into Music/WreckBox/Tracks, the rest go to Tracks/Found, where Identify can name them.',
            style: T.ui(12.5, FontWeight.w400, T.text2)),
        if (scanner.phase == ScanPhase.scanning || scanner.phase == ScanPhase.moving)
          _progress(scanner.done, scanner.total, (scanner.phase == ScanPhase.scanning ? 'Reading ' : 'Moving ') + scanner.line),
        if (scanner.phase == ScanPhase.done && scanner.line.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(scanner.line, style: T.ui(12.5, FontWeight.w600, T.lilac))),
        if (scanner.phase == ScanPhase.review) ...[
          const SizedBox(height: 6),
          if (scanner.groups.isEmpty) Text('Nothing found outside WreckBox — everything\'s already in.', style: T.ui(13, FontWeight.w400, T.text2)),
          for (final g in scanner.groups)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: T.lilac,
              value: scanner.picked.contains(g.name),
              onChanged: (v) => setState(() => v == true ? scanner.picked.add(g.name) : scanner.picked.remove(g.name)),
              title: Text(g.name, style: T.ui(13.5, FontWeight.w600)),
              subtitle: Text('${g.finds.length} tracks · ${g.matched} in your playlists · ${mb(g.size)}${g.otherApp ? ' · another app\'s files' : ''}',
                  style: T.ui(11.5, FontWeight.w400, g.otherApp ? T.peach : T.text3)),
            ),
        ],
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (scanner.phase == ScanPhase.review) ...[
            PillButton(label: 'Move $picked tracks in', icon: Icons.move_to_inbox, style: PillStyle.smart,
                onTap: picked == 0 ? null : () async {
                  await scanner.move(widget.store);
                  _count();
                }),
            PillButton(label: 'Cancel', icon: Icons.close, onTap: scanner.reset),
          ] else
            PillButton(label: 'Scan this phone', icon: Icons.manage_search, style: PillStyle.smart,
                onTap: scanner.phase == ScanPhase.scanning || scanner.phase == ScanPhase.moving || widget.store.library == null
                    ? null
                    : () => scanner.scan(widget.store)),
        ]),
      ]),
    );
  }

  Widget _identifyCard() {
    final list = id.suggestions;
    final sure = list.where((e) => e.score >= 0.9).length;
    return Glass(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const DotLabel('Identify tracks', color: T.text),
        const SizedBox(height: 6),
        Text('Listens to each track in Tracks/Found (like Shazam, but for files) and suggests its real title, artist, album, '
            'year, genre and cover. Nothing changes until you accept.', style: T.ui(12.5, FontWeight.w400, T.text2)),
        if (Identifier.key.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('Coming in the next update.', style: T.ui(12, FontWeight.w400, T.peach))),
        if (id.running) _progress(id.done, id.total, id.line),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (id.running)
            PillButton(label: 'Stop', icon: Icons.stop, onTap: id.cancel)
          else
            PillButton(label: waiting == 0 ? 'Nothing to identify' : 'Identify $waiting tracks', icon: Icons.graphic_eq, style: PillStyle.smart,
                onTap: waiting == 0 || Identifier.key.isEmpty ? null : () async {
                  await id.run(widget.store);
                  _count();
                }),
          if (sure > 0 && !id.running)
            PillButton(label: 'Accept all $sure over 90%', icon: Icons.done_all, onTap: () async {
              await id.acceptAll(widget.store);
              _count();
            }),
        ]),
        if (note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(note, style: T.ui(12, FontWeight.w600, T.text2))),
        if (list.isNotEmpty || id.noMatch > 0)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('${list.length} suggestions${id.noMatch > 0 ? ' · ${id.noMatch} not recognised' : ''}', style: T.ui(12.5, FontWeight.w600, T.text2)),
          ),
        for (final e in list.take(100))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              SizedBox(
                width: 40,
                child: Text('${(e.score * 100).round()}%', style: T.dot(12).copyWith(color: e.score >= 0.9 ? T.lilac : T.peach)),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(13.5, FontWeight.w600)),
                  Text([e.album, e.year, e.genre].whereType<String>().join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: T.ui(11.5, FontWeight.w400, T.text2)),
                  Text('was: ${e.was}', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(11.5, FontWeight.w400, T.text3)),
                ]),
              ),
              IconButton(tooltip: 'Skip', icon: const Icon(Icons.close, color: T.text3), onPressed: () => id.skip(e)),
              IconButton(
                tooltip: 'Accept',
                icon: Icon(busy.contains(e.path) ? Icons.hourglass_top : Icons.check, color: T.lilac),
                onPressed: busy.contains(e.path)
                    ? null
                    : () async {
                        setState(() => busy.add(e.path));
                        final r = await id.accept(e, widget.store);
                        if (mounted) {
                          setState(() {
                            busy.remove(e.path);
                            note = r;
                          });
                        }
                      },
              ),
            ]),
          ),
      ]),
    );
  }
}
