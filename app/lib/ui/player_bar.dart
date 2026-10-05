// Mini player bar (desktop and phone): cover, title, BPM / key, previous / play / next, seek bar.

import 'package:flutter/material.dart';

import '../player.dart';
import '../store.dart';
import 'theme.dart';

class PlayerBar extends StatelessWidget {
  final LibraryStore store;
  final bool compact;
  const PlayerBar({super.key, required this.store, this.compact = false});

  String _fmt(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final player = Player.instance;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final id = player.currentId;
        final r = id == null ? null : store.row(id);
        if (r == null) return const SizedBox.shrink();
        final controls = Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(tooltip: 'Previous', icon: const Icon(Icons.skip_previous_rounded), color: T.text, onPressed: player.previous),
          IconButton.filled(
            tooltip: player.playing ? 'Pause' : 'Play',
            style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
            icon: Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            onPressed: player.toggle,
          ),
          IconButton(tooltip: 'Next', icon: const Icon(Icons.skip_next_rounded), color: T.text, onPressed: player.next),
        ]);
        final seek = StreamBuilder<Duration>(
          stream: player.audio.positionStream,
          builder: (context, snap) {
            final pos = snap.data ?? Duration.zero;
            final dur = player.audio.duration ?? Duration.zero;
            final max = dur.inMilliseconds.toDouble().clamp(1, double.infinity).toDouble();
            return Row(children: [
              Text(_fmt(pos), style: T.dot(11, T.text3)),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), activeTrackColor: T.lilac, inactiveTrackColor: T.hairline, thumbColor: Colors.white, overlayShape: SliderComponentShape.noOverlay),
                  child: Slider(value: pos.inMilliseconds.toDouble().clamp(0, max), max: max, onChanged: (v) => player.audio.seek(Duration(milliseconds: v.round()))),
                ),
              ),
              Text(_fmt(dur), style: T.dot(11, T.text3)),
            ]);
          },
        );
        final info = Row(children: [
          Artwork(track: r.track, store: store, size: compact ? 40 : 44, radius: 8),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(r.track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(13.5, FontWeight.w600)),
              Row(children: [
                Flexible(child: Text(r.track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(11.5, FontWeight.w400, T.text2))),
                if (player.isRemote(r.id)) ...[const SizedBox(width: 6), const Icon(Icons.wifi, size: 12, color: T.lilac)],
              ]),
              if (player.error != null) Text(player.error!, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(11, FontWeight.w600, T.peach)),
            ]),
          ),
          if (!compact) ...[BpmReadout(r.bpm, size: 15), const SizedBox(width: 8), KeyBadge(r.camelot), const SizedBox(width: 8)],
        ]);
        return Padding(
          padding: compact ? const EdgeInsets.fromLTRB(8, 4, 8, 6) : const EdgeInsets.fromLTRB(0, 0, 10, 10),
          child: Glass(
            radius: 20,
            solid: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: compact
                ? Column(mainAxisSize: MainAxisSize.min, children: [Row(children: [Expanded(child: info), controls]), seek])
                : Row(children: [Expanded(flex: 3, child: info), controls, const SizedBox(width: 12), Expanded(flex: 4, child: seek)]),
          ),
        );
      },
    );
  }
}
