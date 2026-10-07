// Full-screen player (tap the player bar): album art or a dot-matrix visualiser (Matrix / Halo), the EQ, and the
// controls — for this phone, or for whichever device is playing. Painted with CustomPainter, ~30 fps, one pass
// over a few hundred rounded squares: light on the battery.

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../eq.dart';
import '../player.dart';
import '../remote_playback.dart';
import '../settings.dart';
import '../store.dart';
import '../visualizer.dart';
import 'player_bar.dart';
import 'theme.dart';

void openFullPlayer(BuildContext context, LibraryStore store) {
  Navigator.of(context).push(PageRouteBuilder(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, a, _) => FadeTransition(opacity: a, child: FullPlayer(store: store)),
  ));
}

/// lilac → light blue → peach, like the app's gradient.
Color dotColor(double h) {
  const a = Color(0xFFBB96DA), m = Color(0xFFA9C8F0), z = Color(0xFFEFAF86);
  return h < 0.5 ? Color.lerp(a, m, h * 2)! : Color.lerp(m, z, (h - 0.5) * 2)!;
}

class FullPlayer extends StatefulWidget {
  final LibraryStore store;
  const FullPlayer({super.key, required this.store});
  @override
  State<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends State<FullPlayer> {
  String get mode => Settings.current.visualMode;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(milliseconds: 500), (_) => setState(() {})); // remote clock
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  String _fmt(double s) => '${s ~/ 60}:${(s.toInt() % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final player = Player.instance, sync = PlaybackSync.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([player, sync]),
      builder: (context, _) {
        final remote = !player.playing ? sync.remoteActive : null;
        final id = remote?.trackID ?? player.currentId;
        final r = id == null ? null : widget.store.row(id);
        final playing = remote?.playing ?? player.playing;
        final pos = remote?.livePosition ?? player.audio.position.inMilliseconds / 1000;
        final dur = remote?.duration ?? (player.audio.duration?.inMilliseconds ?? 0) / 1000;
        return Scaffold(
          backgroundColor: T.bg,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(children: [
                Row(children: [
                  IconButton(icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30), onPressed: () => Navigator.pop(context)),
                  const Spacer(),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(selectedBackgroundColor: Colors.white, selectedForegroundColor: Colors.black, textStyle: T.ui(12, FontWeight.w600)),
                    segments: const [
                      ButtonSegment(value: 'art', label: Text('Art')),
                      ButtonSegment(value: 'matrix', label: Text('Matrix')),
                      ButtonSegment(value: 'halo', label: Text('Halo')),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) async {
                      Settings.current.visualMode = s.first;
                      await Settings.current.save();
                      setState(() {});
                    },
                  ),
                  const Spacer(),
                  IconButton(tooltip: 'Equaliser', icon: const Icon(Icons.equalizer_rounded), onPressed: () => showEQSheet(context)),
                ]),
                Expanded(
                  child: r == null
                      ? Center(child: Text('Nothing playing', style: T.ui(15, FontWeight.w400, T.text2)))
                      : Center(child: _visual(r, remote == null, playing)),
                ),
                if (r != null) ...[
                  Text(r.track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(22, FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(r.track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(14, FontWeight.w400, T.text2)),
                  if (remote != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Playing on ${remote.name}', style: T.ui(12, FontWeight.w600, T.lilac))),
                  const SizedBox(height: 14),
                  Row(children: [
                    Text(_fmt(pos), style: T.dot(11, T.text3)),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(trackHeight: 3, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6), activeTrackColor: T.lilac, inactiveTrackColor: T.hairline, thumbColor: Colors.white, overlayShape: SliderComponentShape.noOverlay),
                        child: Slider(
                          value: dur > 0 ? pos.clamp(0, dur).toDouble() : 0,
                          max: dur > 0 ? dur : 1,
                          onChanged: remote != null || dur == 0 ? null : (v) => player.audio.seek(Duration(milliseconds: (v * 1000).round())),
                          onChangeEnd: remote != null && dur > 0 ? (v) => sync.command('seek', value: v) : null,
                        ),
                      ),
                    ),
                    Text(dur > 0 ? _fmt(dur) : '–:––', style: T.dot(11, T.text3)),
                  ]),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    IconButton(iconSize: 34, icon: const Icon(Icons.skip_previous_rounded), onPressed: () => remote != null ? sync.command('previous') : player.previous()),
                    const SizedBox(width: 14),
                    IconButton.filled(
                      iconSize: 38,
                      style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, minimumSize: const Size(76, 76)),
                      icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      onPressed: () => remote != null ? sync.command('toggle') : player.toggle(),
                    ),
                    const SizedBox(width: 14),
                    IconButton(iconSize: 34, icon: const Icon(Icons.skip_next_rounded), onPressed: () => remote != null ? sync.command('next') : player.next()),
                  ]),
                  Align(alignment: Alignment.centerRight, child: DevicesButton(store: widget.store)),
                ],
              ]),
            ),
          ),
        );
      },
    );
  }

  Widget _visual(TrackRow r, bool local, bool playing) {
    final art = LayoutBuilder(builder: (c, box) {
      final side = min(box.maxWidth, box.maxHeight) * 0.9;
      return Artwork(track: r.track, store: widget.store, size: side, radius: 18);
    });
    if (mode == 'art') return art;
    return StreamBuilder<List<double>>(
      // Re-subscribes when the track (BPM) or where it plays changes.
      key: ValueKey('${r.id}$local$mode'),
      stream: Spectrum.levels(local: local, bpm: r.bpm ?? 120, playing: () => local ? Player.instance.playing : (PlaybackSync.instance.remoteActive?.playing ?? false)),
      builder: (context, snap) {
        final levels = snap.data ?? List.filled(Spectrum.bands, 0.0);
        if (mode == 'halo') {
          return LayoutBuilder(builder: (c, box) {
            final side = min(box.maxWidth, box.maxHeight);
            final bump = 1 + (levels.take(4).reduce(max)) * 0.035;
            return SizedBox(
              width: side,
              height: side,
              child: Stack(alignment: Alignment.center, children: [
                RepaintBoundary(child: CustomPaint(size: Size(side, side), painter: HaloPainter(levels, side * 0.46))),
                Transform.scale(scale: bump, child: Artwork(track: r.track, store: widget.store, size: side * 0.46, radius: side * 0.23)),
              ]),
            );
          });
        }
        return RepaintBoundary(child: CustomPaint(size: const Size(double.infinity, 260), painter: MatrixPainter(levels)));
      },
    );
  }
}

/// LED columns with a peak dot per column and a faint reflection.
class MatrixPainter extends CustomPainter {
  final List<double> levels;
  final int rows;
  static final _peaks = List<double>.filled(Spectrum.bands, 0);
  MatrixPainter(this.levels, {this.rows = 16});

  @override
  void paint(Canvas canvas, Size size) {
    final cols = levels.length;
    const gap = 3.0;
    final cell = min((size.width - gap * (cols - 1)) / cols, (size.height * 0.78 - gap * (rows - 1)) / rows);
    final width = cell * cols + gap * (cols - 1), x0 = (size.width - width) / 2, floor = size.height * 0.78;
    final off = Paint()..color = Colors.white.withValues(alpha: 0.05);
    final paint = Paint();
    for (var c = 0; c < cols; c++) {
      _peaks[c] = levels[c] >= _peaks[c] ? levels[c] : max(levels[c], _peaks[c] - 0.018);
      final lit = (levels[c] * rows).round(), peak = (_peaks[c] * rows).round();
      final x = x0 + c * (cell + gap);
      for (var r = 0; r < rows; r++) {
        final y = floor - (r + 1) * cell - r * gap;
        final on = r < lit || (r == peak - 1 && peak > 0);
        final rect = RRect.fromRectAndRadius(Rect.fromLTWH(x, y, cell, cell), Radius.circular(cell * 0.22));
        final color = dotColor(r / (rows - 1));
        canvas.drawRRect(rect, on ? (paint..color = color) : off);
        if (r < 5 && r < lit) {
          final ry = floor + gap + r * (cell + gap);
          canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, ry, cell, cell), Radius.circular(cell * 0.22)),
              paint..color = color.withValues(alpha: 0.22 - r * 0.04));
        }
      }
    }
  }

  @override
  bool shouldRepaint(MatrixPainter old) => true;
}

/// Dot rays around the cover.
class HaloPainter extends CustomPainter {
  final List<double> levels;
  final double art;
  HaloPainter(this.levels, this.art);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final rays = levels.length * 2, side = min(size.width, size.height);
    final r0 = art / 2 + 12, dot = max(3.0, side / 110);
    const steps = 9;
    final off = Paint()..color = Colors.white.withValues(alpha: 0.045);
    final paint = Paint();
    for (var i = 0; i < rays; i++) {
      final b = i < levels.length ? i : rays - 1 - i;
      final a = i / rays * 2 * pi - pi / 2;
      final lit = (levels[b] * steps).round();
      for (var s = 0; s < steps; s++) {
        final rr = r0 + s * (dot + 4);
        final p = c + Offset(cos(a) * rr, sin(a) * rr);
        final rect = RRect.fromRectAndRadius(Rect.fromCenter(center: p, width: dot, height: dot), Radius.circular(dot * 0.25));
        canvas.drawRRect(rect, s < lit ? (paint..color = dotColor(s / (steps - 1))) : off);
      }
    }
  }

  @override
  bool shouldRepaint(HaloPainter old) => true;
}

// MARK: EQ

void showEQSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: T.bgRaised,
    isScrollControlled: true,
    builder: (_) => const SafeArea(child: Padding(padding: EdgeInsets.fromLTRB(16, 18, 16, 16), child: EQPanel())),
  );
}

class EQPanel extends StatelessWidget {
  const EQPanel({super.key});
  @override
  Widget build(BuildContext context) {
    final eq = PhoneEQ.instance;
    return ListenableBuilder(
      listenable: eq,
      builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const DotLabel('Equaliser', color: T.text),
          const Spacer(),
          Switch(value: eq.on, activeThumbColor: T.lilac, onChanged: eq.setOn),
        ]),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final p in PhoneEQ.presets.keys)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ChoiceChip(
                  label: Text(p, style: T.ui(12, FontWeight.w600, eq.preset == p ? Colors.black : T.text2)),
                  selected: eq.preset == p,
                  selectedColor: Colors.white,
                  showCheckmark: false,
                  onSelected: (_) => eq.choose(p),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 14),
        Opacity(
          opacity: eq.on ? 1 : 0.4,
          child: Row(children: [
            for (var i = 0; i < 10; i++)
              Expanded(
                child: Column(children: [
                  Text('${eq.gains[i] >= 0 ? '+' : ''}${eq.gains[i].round()}', style: T.dot(9, T.text3)),
                  const SizedBox(height: 4),
                  _DotSlider(value: eq.gains[i], onChanged: (v) => eq.set(i, v), onEnd: eq.save),
                  const SizedBox(height: 4),
                  Text(PhoneEQ.labels[i], style: T.dot(9, T.text3)),
                ]),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// A column of dots from -12 to +12 dB, lit from the 0 line; drag to set, double-tap for 0.
class _DotSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;
  const _DotSlider({required this.value, required this.onChanged, required this.onEnd});
  static const dots = 19, h = 7.0;

  void _at(double y) {
    final f = 1 - (y / (dots * h)).clamp(0, 1);
    onChanged(((f * 24 - 12) * 2).round() / 2);
  }

  @override
  Widget build(BuildContext context) {
    const mid = dots ~/ 2;
    final level = (value / 12 * mid).round();
    return GestureDetector(
      onVerticalDragStart: (d) => _at(d.localPosition.dy),
      onVerticalDragUpdate: (d) => _at(d.localPosition.dy),
      onVerticalDragEnd: (_) => onEnd(),
      onTapDown: (d) => _at(d.localPosition.dy),
      onTapUp: (_) => onEnd(),
      onDoubleTap: () {
        onChanged(0);
        onEnd();
      },
      child: SizedBox(
        width: 28,
        height: dots * h,
        child: Column(children: [
          for (var i = 0; i < dots; i++)
            Builder(builder: (_) {
              final k = mid - i;
              final on = (level > 0 && k > 0 && k <= level) || (level < 0 && k < 0 && k >= level);
              return Container(
                width: 9,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: 1.5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1.2),
                  color: k == 0 ? T.text3 : on ? dotColor(i / (dots - 1)) : Colors.white.withValues(alpha: 0.07),
                ),
              );
            }),
        ]),
      ),
    );
  }
}
