// Track list and inspector — shared by the desktop and phone layouts.

import 'dart:io';

import 'package:flutter/material.dart' hide Row;
import 'package:flutter/material.dart' as m show Row;

import '../matcher.dart';
import '../models.dart';
import '../phone_sync.dart';
import '../player.dart';
import '../store.dart';
import 'theme.dart';

typedef HRow = m.Row;

enum SortKey { none, title, artist, bpm, key, energy }

class MixFilter {
  String? minBpm, maxBpm, key;
  bool compatible = true;
  bool get active => (minBpm ?? '').isNotEmpty || (maxBpm ?? '').isNotEmpty || key != null;
  bool allows(TrackRow r) {
    final lo = double.tryParse(minBpm ?? ''), hi = double.tryParse(maxBpm ?? '');
    if (lo != null && (r.bpm == null || r.bpm! < lo)) return false;
    if (hi != null && (r.bpm == null || r.bpm! > hi)) return false;
    if (key != null) return compatible ? compatibleKeys(key!).contains(r.camelot) : r.camelot == key;
    return true;
  }
}

class TrackListView extends StatefulWidget {
  final LibraryStore store;
  final ListFilter filter;
  final String? playlist;
  final bool compact; // phone
  const TrackListView({super.key, required this.store, this.filter = ListFilter.all, this.playlist, this.compact = false});
  @override
  State<TrackListView> createState() => _TrackListViewState();
}

class _TrackListViewState extends State<TrackListView> {
  String search = '';
  final mix = MixFilter();
  SortKey sort = SortKey.none;
  bool asc = true;

  static const presets = [('< 100', '', '99'), ('100–120', '100', '120'), ('120–130', '120', '130'), ('130–145', '130', '145'), ('145+', '145', '')];

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    var rows = store.rows(filter: widget.filter, playlist: widget.playlist, search: search).where(mix.allows).toList();
    int cmp<T extends Comparable>(T a, T b) => asc ? a.compareTo(b) : b.compareTo(a);
    switch (sort) {
      case SortKey.title:
        rows.sort((a, b) => cmp(a.track.title.toLowerCase(), b.track.title.toLowerCase()));
      case SortKey.artist:
        rows.sort((a, b) => cmp(a.track.artist.toLowerCase(), b.track.artist.toLowerCase()));
      case SortKey.bpm:
        rows.sort((a, b) => cmp(a.bpm ?? -1, b.bpm ?? -1));
      case SortKey.key:
        rows.sort((a, b) => cmp(camelotOrder(a.camelot), camelotOrder(b.camelot)));
      case SortKey.energy:
        rows.sort((a, b) => cmp(a.energy ?? -1, b.energy ?? -1));
      case SortKey.none:
        break;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _filters(),
      const SizedBox(height: 12),
      Expanded(
        child: Glass(
          child: Column(children: [
            if (!widget.compact) _header(),
            if (!widget.compact) const Divider(height: 1, color: T.hairline),
            Expanded(
              child: rows.isEmpty
                  ? Center(child: Text(search.isEmpty && !mix.active ? 'Nothing here yet.' : 'No tracks match.', style: T.ui(13, FontWeight.w400, T.text3)))
                  : ListenableBuilder(
                      listenable: Player.instance, // now-playing marker
                      builder: (context, _) => ListView.builder(
                      padding: const EdgeInsets.all(6),
                      itemCount: rows.length,
                      itemExtent: widget.compact ? 60 : 54,
                      itemBuilder: (_, i) => _TrackTile(row: rows[i], store: store, compact: widget.compact, queue: [for (final r in rows) r.id]),
                    )),
            ),
          ]),
        ),
      ),
    ]);
  }

  Widget _filters() {
    final searchBox = Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(color: T.glassFill, borderRadius: BorderRadius.circular(99), border: Border.all(color: T.hairline)),
      child: HRow(children: [
        const Icon(Icons.search, size: 17, color: T.text3),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            onChanged: (v) => setState(() => search = v),
            style: T.ui(13),
            decoration: InputDecoration.collapsed(hintText: 'Search artist, title, album', hintStyle: T.ui(13, FontWeight.w400, T.text3)),
          ),
        ),
      ]),
    );
    final chips = [
      for (final (label, lo, hi) in presets)
        ChipButton(
          label: label,
          selected: mix.minBpm == lo && mix.maxBpm == hi,
          onTap: () => setState(() {
            final on = mix.minBpm == lo && mix.maxBpm == hi;
            mix.minBpm = on ? null : lo;
            mix.maxBpm = on ? null : hi;
          }),
        ),
      PopupMenuButton<String?>(
        tooltip: 'Key',
        color: T.bgRaised,
        onSelected: (k) => setState(() => mix.key = k == '' ? null : k),
        itemBuilder: (_) => [
          const PopupMenuItem(value: '', child: Text('Any key')),
          for (var n = 1; n <= 12; n++)
            for (final l in ['A', 'B']) PopupMenuItem(value: '$n$l', child: KeyBadge('$n$l')),
        ],
        child: mix.key == null ? ChipButton(label: 'Any key', onTap: () {}) : KeyBadge(mix.key!),
      ),
      if (mix.key != null)
        ChipButton(label: '+ compatible', smart: mix.compatible, onTap: () => setState(() => mix.compatible = !mix.compatible)),
      if (mix.active) TextButton(onPressed: () => setState(() => mix..minBpm = null..maxBpm = null..key = null), child: Text('Clear', style: T.ui(12.5, FontWeight.w600, T.text2))),
    ];
    if (widget.compact) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        searchBox,
        const SizedBox(height: 8),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: HRow(children: [for (final c in chips) Padding(padding: const EdgeInsets.only(right: 6), child: c)])),
      ]);
    }
    return HRow(children: [
      SizedBox(width: 260, child: searchBox),
      const SizedBox(width: 10),
      const DotLabel('BPM', size: 10),
      const SizedBox(width: 6),
      Expanded(child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: chips)),
    ]);
  }

  Widget _header() {
    Widget head(String label, SortKey k, double? width) {
      final on = sort == k;
      final w = InkWell(
        onTap: () => setState(() {
          if (on) {
            if (asc) {
              asc = false;
            } else {
              sort = SortKey.none;
              asc = true;
            }
          } else {
            sort = k;
            asc = true;
          }
        }),
        child: HRow(mainAxisSize: MainAxisSize.min, children: [
          DotLabel(label, color: on ? T.text : T.text3, size: 10),
          if (on) Icon(asc ? Icons.arrow_drop_up : Icons.arrow_drop_down, size: 14, color: T.text),
        ]),
      );
      return width == null ? Expanded(child: Align(alignment: Alignment.centerLeft, child: w)) : SizedBox(width: width, child: w);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: HRow(children: [
        const SizedBox(width: 52),
        head('Title', SortKey.title, null),
        head('BPM', SortKey.bpm, 60),
        head('Key', SortKey.key, 70),
        head('Energy', SortKey.energy, 60),
        const SizedBox(width: 50),
        const SizedBox(width: 26),
      ]),
    );
  }
}

class _TrackTile extends StatelessWidget {
  final TrackRow row;
  final LibraryStore store;
  final bool compact;
  final List<String> queue; // the list on screen: next / previous in the player follow it
  const _TrackTile({required this.row, required this.store, required this.compact, required this.queue});

  @override
  Widget build(BuildContext context) {
    final focused = store.focus == row.id;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => compact ? showTrackSheet(context, store, row.id) : store.setFocus(row.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: focused ? Colors.white.withValues(alpha: 0.10) : null,
          border: focused ? Border.all(color: T.lilac.withValues(alpha: 0.6)) : null,
        ),
        child: HRow(children: [
          // Tap the cover to play (own files, or streamed from your computer on the phone).
          Tooltip(
            message: Player.instance.canPlay(row.id) ? 'Play' : 'Not on this device',
            child: InkWell(
              onTap: Player.instance.canPlay(row.id) ? () => Player.instance.play(row.id, list: queue) : null,
              child: Stack(alignment: Alignment.center, children: [
                Artwork(track: row.track, store: store, size: compact ? 44 : 40),
                if (Player.instance.currentId == row.id)
                  Container(
                    width: compact ? 44 : 40,
                    height: compact ? 44 : 40,
                    decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), borderRadius: BorderRadius.circular(8)),
                    child: Icon(Player.instance.playing ? Icons.graphic_eq : Icons.pause, color: T.lilac, size: 20),
                  ),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(row.track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(13.5, FontWeight.w600)),
              const SizedBox(height: 2),
              Text(row.track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(12, FontWeight.w400, T.text2)),
            ]),
          ),
          SizedBox(width: compact ? 40 : 60, child: BpmReadout(row.bpm, unsure: row.file?.bpmUnsure ?? false, size: compact ? 14 : 17)),
          SizedBox(width: compact ? 48 : 70, child: Align(alignment: Alignment.centerLeft, child: KeyBadge(row.camelot, unsure: row.file?.keyUnsure ?? false))),
          if (!compact) SizedBox(width: 60, child: EnergyMeter(row.energy)),
          if (!compact) SizedBox(width: 50, child: Text(row.durationText, textAlign: TextAlign.right, style: T.dot(12, T.text3))),
          const SizedBox(width: 10),
          row.status == TrackStatus.missing && Player.instance.remoteIds.contains(row.id)
              ? const Tooltip(message: 'On your computer — tap the cover to stream', child: Icon(Icons.wifi, size: 16, color: T.lilac))
              : StatusDot(row.status),
        ]),
      ),
    );
  }
}

/// Phone: track details as a bottom sheet.
void showTrackSheet(BuildContext context, LibraryStore store, String id) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: T.bgRaised,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      builder: (_, controller) => ListenableBuilder(
        listenable: store,
        builder: (_, __) => SingleChildScrollView(controller: controller, padding: const EdgeInsets.all(18), child: InspectorBody(store: store, id: id)),
      ),
    ),
  );
}

class Inspector extends StatelessWidget {
  final LibraryStore store;
  final bool floating;
  const Inspector({super.key, required this.store, this.floating = false});
  @override
  Widget build(BuildContext context) {
    final id = store.focus;
    if (id == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
      child: Glass(
        solid: floating,
        child: SingleChildScrollView(padding: const EdgeInsets.all(18), child: InspectorBody(store: store, id: id, onClose: () => store.setFocus(null))),
      ),
    );
  }
}

class InspectorBody extends StatelessWidget {
  final LibraryStore store;
  final String id;
  final VoidCallback? onClose;
  const InspectorBody({super.key, required this.store, required this.id, this.onClose});

  @override
  Widget build(BuildContext context) {
    final r = store.row(id);
    if (r == null) return const SizedBox.shrink();
    final f = r.file;
    final mixes = store.mixesWith(r);
    Widget readout(String label, Widget value, [Widget? sub]) => Expanded(
          child: Glass(
            radius: 16,
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [DotLabel(label, size: 10), const SizedBox(height: 6), value, if (sub != null) ...[const SizedBox(height: 4), sub]]),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      HRow(children: [
        DotLabel(r.status == TrackStatus.downloaded ? 'In your crate' : r.status == TrackStatus.ignored ? 'Ignored' : 'Missing'),
        const Spacer(),
        if (onClose != null) IconButton(onPressed: onClose, icon: const Icon(Icons.close, size: 18, color: T.text2)),
      ]),
      const SizedBox(height: 8),
      Center(child: Artwork(track: r.track, store: store, size: 280, radius: 20)),
      const SizedBox(height: 16),
      Text(r.track.title, style: T.ui(22, FontWeight.w600)),
      Text(r.track.artist, style: T.ui(15, FontWeight.w400, T.text2)),
      Text([r.track.album, r.track.year].whereType<String>().join(' · '), style: T.ui(12, FontWeight.w400, T.text3)),
      const SizedBox(height: 14),
      IntrinsicHeight(child: HRow(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        readout('BPM', BpmReadout(r.bpm, unsure: f?.bpmUnsure ?? false, size: 28), f?.bpmAlternate != null ? Text('or ${f!.bpmAlternate!.round()}', style: T.dot(11, T.text3)) : null),
        const SizedBox(width: 8),
        readout('Key', KeyBadge(r.camelot, unsure: f?.keyUnsure ?? false, large: true), Text(f?.key ?? ' ', style: T.ui(11, FontWeight.w400, T.text3))),
        const SizedBox(width: 8),
        readout('Energy', EnergyMeter(r.energy, height: 22), Text(r.energy == null ? '–' : '${(r.energy! * 100).round()}%', style: T.dot(11, T.text3))),
      ])),
      const SizedBox(height: 8),
      Text(
        f == null
            ? (r.status == TrackStatus.downloaded ? 'Not analysed yet — run Rescan & analyse.' : 'Not on this device yet.')
            : 'Full-track analysis · tempo confidence ${((f.bpmConfidence ?? 0) * 100).round()}%'
                '${f.keyAgreement != null ? ' · key ${f.keyAgreement}/3 methods agree' : ''}',
        style: T.ui(11.5, FontWeight.w400, T.text3),
      ),
      const SizedBox(height: 14),
      if (r.track.playlists.isNotEmpty) ...[
        const DotLabel('Playlists'),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [for (final pl in r.track.playlists) ChipButton(label: pl, onTap: () {})]),
        const SizedBox(height: 14),
      ],
      Glass(
        smart: true,
        radius: 18,
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          HRow(children: [const Icon(Icons.auto_awesome, size: 14, color: T.text), const SizedBox(width: 6), const DotLabel('Mixes with', color: T.text)]),
          const SizedBox(height: 10),
          if (r.camelot.isEmpty || r.bpm == null)
            Text('Needs a key and BPM — available once the track is on this device and analysed.', style: T.ui(12, FontWeight.w400, T.text2))
          else if (mixes.isEmpty)
            Text('Nothing in your crate within ±6% tempo in a compatible key yet.', style: T.ui(12, FontWeight.w400, T.text2))
          else
            for (final mx in mixes)
              InkWell(
                onTap: () => store.setFocus(mx.id),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: HRow(children: [
                    Artwork(track: mx.track, store: store, size: 30, radius: 6),
                    const SizedBox(width: 10),
                    Expanded(child: Text(mx.track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(12.5, FontWeight.w600))),
                    BpmReadout(mx.bpm, size: 13),
                    const SizedBox(width: 6),
                    KeyBadge(mx.camelot),
                  ]),
                ),
              ),
        ]),
      ),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (Player.instance.canPlay(r.id))
          PillButton(
            label: Player.instance.isRemote(r.id) ? 'Stream from computer' : 'Play',
            icon: Icons.play_arrow_rounded,
            style: PillStyle.primary,
            onTap: () => Player.instance.play(r.id),
          ),
        if (r.status == TrackStatus.downloaded && r.state?.localPath != null) ...[
          PillButton(label: 'Write tags to file', icon: Icons.sell_outlined, style: PillStyle.smart, onTap: store.busy != null ? null : () => store.writeTags([r.id])),
          if (Platform.isWindows || Platform.isMacOS)
            PillButton(label: 'Show in folder', icon: Icons.folder_open, onTap: () => revealInFolder(r.state!.localPath!)),
        ],
        // Phone: stream / download if the computer has it, otherwise ask it to find it on Soulseek. Rebuilt when the
        // computer's track list arrives or changes.
        if (r.status == TrackStatus.missing && PhoneSyncClient.instance?.base != null) _PhoneActions(id: r.id),
        if (r.status == TrackStatus.missing) PillButton(label: 'Ignore', icon: Icons.block, onTap: () => store.setStatus([r.id], TrackStatus.ignored)),
        if (r.status == TrackStatus.ignored) PillButton(label: 'Un-ignore', icon: Icons.undo, onTap: () => store.setStatus([r.id], TrackStatus.missing)),
      ]),
      if (r.state?.localPath != null) ...[const SizedBox(height: 8), Text(r.state!.localPath!, style: T.ui(11, FontWeight.w400, T.text3))],
    ]);
  }
}

void revealInFolder(String path) {
  if (Platform.isWindows) {
    Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isMacOS) {
    Process.run('open', ['-R', path]);
  }
}

class _PhoneActions extends StatelessWidget {
  final String id;
  const _PhoneActions({required this.id});
  @override
  Widget build(BuildContext context) {
    final c = PhoneSyncClient.instance!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final item = c.crateById?[id];
        if (c.crateById == null) return const PillButton(label: 'Connecting to computer…', icon: Icons.sync);
        if (item == null) return _RequestButton(id: id);
        return Wrap(spacing: 8, runSpacing: 8, children: [
          if (!Player.instance.canPlay(id))
            PillButton(label: 'Stream from computer', icon: Icons.play_arrow_rounded, style: PillStyle.primary, onTap: () => Player.instance.play(id)),
          PillButton(label: 'Download to phone', icon: Icons.download, onTap: () => c.download([item], (_, _, _) {})),
        ]);
      },
    );
  }
}

class _RequestButton extends StatelessWidget {
  final String id;
  const _RequestButton({required this.id});
  @override
  Widget build(BuildContext context) {
    final c = PhoneSyncClient.instance!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final st = c.requests[id];
        final label = switch (st) {
          null => 'Ask computer to find it',
          'queued' => 'Waiting for computer',
          'not_found' => 'Not found — try again',
          'failed' => 'Failed — try again',
          'ready' => 'On its way',
          _ => 'Searching…',
        };
        final canTap = st == null || st == 'not_found' || st == 'failed';
        return PillButton(
          label: label,
          icon: Icons.travel_explore,
          style: PillStyle.smart,
          onTap: canTap ? () => c.request(id: id).catchError((_) => 'failed') : null,
        );
      },
    );
  }
}
