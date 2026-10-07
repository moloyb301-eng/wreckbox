// Mini player bar (desktop and phone): cover, title, BPM / key, previous / play / next, seek bar.
// Phone: when another device plays (the computer, another phone), the bar shows that and controls it; the devices
// button moves the music between devices (remote_playback.dart).

import 'package:flutter/material.dart';

import '../player.dart';
import '../remote_playback.dart';
import 'full_player.dart';
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
    final sync = PlaybackSync.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([player, sync]),
      builder: (context, _) {
        final remote = compact ? sync.remoteActive : null;
        if (remote != null && !player.playing) return _remoteBar(context, remote);
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
                ? Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => openFullPlayer(context, store), child: info)), controls, DevicesButton(store: store)]),
                    seek,
                  ])
                : Row(children: [Expanded(flex: 3, child: info), controls, const SizedBox(width: 12), Expanded(flex: 4, child: seek)]),
          ),
        );
      },
    );
  }

  /// Another device is playing: its track, and controls that act on it.
  Widget _remoteBar(BuildContext context, RemoteDevice d) {
    final sync = PlaybackSync.instance;
    final r = store.row(d.trackID!);
    final max = d.duration > 0 ? d.duration : 1.0;
    final pos = d.duration > 0 ? d.livePosition.clamp(0, max).toDouble() : 0.0; // length not known yet: empty bar
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
      child: Glass(
        radius: 20,
        solid: true,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            if (r != null) GestureDetector(onTap: () => openFullPlayer(context, store), child: Artwork(track: r.track, store: store, size: 40, radius: 8)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(r?.track.title ?? store.describe(d.trackID!), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(13.5, FontWeight.w600)),
                Row(children: [
                  Icon(d.kind == 'mac' ? Icons.laptop_mac : Icons.smartphone, size: 12, color: T.lilac),
                  const SizedBox(width: 4),
                  Flexible(child: Text('Playing on ${d.name}', maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(11.5, FontWeight.w600, T.lilac))),
                ]),
              ]),
            ),
            IconButton(tooltip: 'Previous', icon: const Icon(Icons.skip_previous_rounded), color: T.text, onPressed: () => sync.command('previous')),
            IconButton.filled(
              tooltip: d.playing ? 'Pause' : 'Play',
              style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              icon: Icon(d.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              onPressed: () => sync.command('toggle'),
            ),
            IconButton(tooltip: 'Next', icon: const Icon(Icons.skip_next_rounded), color: T.text, onPressed: () => sync.command('next')),
            DevicesButton(store: store),
          ]),
          Row(children: [
            Text(_fmt(Duration(milliseconds: (d.livePosition * 1000).round())), style: T.dot(11, T.text3)),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), activeTrackColor: T.lilac, inactiveTrackColor: T.hairline, thumbColor: Colors.white, overlayShape: SliderComponentShape.noOverlay),
                child: Slider(value: pos, max: max, onChanged: (_) {}, onChangeEnd: d.duration > 0 ? (v) => sync.command('seek', value: v) : null),
              ),
            ),
            Text(d.duration > 0 ? _fmt(Duration(milliseconds: (d.duration * 1000).round())) : '–:––', style: T.dot(11, T.text3)),
          ]),
        ]),
      ),
    );
  }
}

/// Where the music plays: this phone, the computer, other phones. Picking one moves the music there.
class DevicesButton extends StatelessWidget {
  final LibraryStore store;
  const DevicesButton({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final sync = PlaybackSync.instance;
    final elsewhere = sync.remoteActive != null && !Player.instance.playing;
    return IconButton(
      tooltip: 'Devices',
      icon: Icon(Icons.devices_rounded, color: elsewhere ? T.lilac : T.text2),
      onPressed: () {
        sync.fetch();
        showModalBottomSheet(
          context: context,
          backgroundColor: T.bgRaised,
          builder: (ctx) => ListenableBuilder(
            listenable: sync,
            builder: (ctx, _) {
              final activeHere = sync.activeID == null || sync.activeID == sync.myID;
              Widget tile(String id, String name, IconData icon, {String? sub, required bool active}) => ListTile(
                    leading: Icon(icon, color: active ? T.lilac : T.text2),
                    title: Text(name, style: T.ui(14.5, FontWeight.w600, active ? T.lilac : T.text)),
                    subtitle: sub == null ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(12, FontWeight.w400, T.text3)),
                    trailing: active ? const Icon(Icons.graphic_eq, color: T.lilac) : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      if (!active) sync.transferTo(id);
                    },
                  );
              return SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 6), child: Text('Play on', style: T.ui(18, FontWeight.w600))),
                  tile(sync.myID, 'This phone', Icons.smartphone, active: activeHere),
                  for (final d in sync.others)
                    tile(d.id, d.name, d.kind == 'mac' ? Icons.laptop_mac : Icons.smartphone,
                        sub: d.trackID == null ? null : '${d.playing ? 'Playing' : 'Paused'} · ${store.describe(d.trackID!)}', active: sync.activeID == d.id),
                  if (sync.others.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                      child: Text('Connect to your computer (Computer tab) to see your other devices.', style: T.ui(12.5, FontWeight.w400, T.text3)),
                    ),
                  const SizedBox(height: 8),
                ]),
              );
            },
          ),
        );
      },
    );
  }
}
