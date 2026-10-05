// WreckBox design system (Flutter port of the Mac app's Theme / Glass / Components): dark glass surfaces,
// Urbanist for UI text, Doto dot-matrix for labels and readouts, pastel gradient for smart features.

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';

class T {
  static const bg = Color(0xFF08080A);
  static const bgRaised = Color(0xFF111115);
  static const text = Color(0xF0FFFFFF);
  static const text2 = Color(0x99FFFFFF);
  static const text3 = Color(0x5CFFFFFF);
  static const hairline = Color(0x14FFFFFF);
  static const glassFill = Color(0x0BFFFFFF);
  static const hover = Color(0x0FFFFFFF);
  static const peach = Color(0xFFEFAF86);
  static const lilac = Color(0xFFBB96DA);
  static const lightBlue = Color(0xFFA9C8F0); // TODO: exact value not legible in the source design – placeholder
  static const smart = LinearGradient(colors: [lightBlue, peach, lilac], begin: Alignment.topLeft, end: Alignment.bottomRight);

  static TextStyle ui(double size, [FontWeight w = FontWeight.w400, Color c = text]) =>
      TextStyle(fontFamily: 'Urbanist', fontSize: size, fontWeight: w, color: c, height: 1.2);
  static TextStyle dot(double size, [Color c = text, FontWeight w = FontWeight.w700]) =>
      TextStyle(fontFamily: 'Doto', fontSize: size, fontWeight: w, color: c, height: 1.1);

  static ThemeData theme() => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        fontFamily: 'Urbanist',
        colorScheme: const ColorScheme.dark(primary: lilac, secondary: peach, surface: bgRaised),
        splashFactory: NoSplash.splashFactory,
        useMaterial3: true,
      );

  /// Camelot wheel colour: the hue steps around the wheel like DJ software key colours.
  static Color camelot(String code) {
    final n = int.tryParse(code.isEmpty ? '' : code.substring(0, code.length - 1));
    if (n == null) return text3;
    final hue = ((n - 1) * 30 + 165) % 360;
    return code.endsWith('B')
        ? HSVColor.fromAHSV(1, hue.toDouble(), 0.55, 1.0).toColor()
        : HSVColor.fromAHSV(1, hue.toDouble(), 0.45, 0.88).toColor();
  }

  static Color tint(String seed) {
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return HSVColor.fromAHSV(1, (h % 360).toDouble(), 0.35, 0.75).toColor();
  }
}

/// Frosted glass panel.
class Glass extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final bool smart;
  final bool solid; // floating panels: opaque backing so content behind doesn't show through
  const Glass({super.key, required this.child, this.radius = 24, this.padding, this.smart = false, this.solid = false});

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: r,
            color: solid ? T.bgRaised.withValues(alpha: 0.96) : (smart ? null : T.glassFill),
            gradient: smart ? LinearGradient(colors: [T.lightBlue.withValues(alpha: 0.16), T.peach.withValues(alpha: 0.14), T.lilac.withValues(alpha: 0.18)]) : null,
            border: Border.all(color: smart ? T.lilac.withValues(alpha: 0.45) : const Color(0x1FFFFFFF)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class DotLabel extends StatelessWidget {
  final String text;
  final Color color;
  final double size;
  const DotLabel(this.text, {super.key, this.color = T.text3, this.size = 11});
  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: T.dot(size, color).copyWith(letterSpacing: 1.6));
}

class ChipButton extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final bool smart;
  final VoidCallback onTap;
  const ChipButton({super.key, required this.label, this.count, this.selected = false, this.smart = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = selected ? Colors.black : (smart ? T.text : T.text2);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? Colors.white : (smart ? null : T.glassFill),
          gradient: smart && !selected ? LinearGradient(colors: [T.lightBlue.withValues(alpha: 0.22), T.lilac.withValues(alpha: 0.22)]) : null,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: selected ? Colors.white : (smart ? T.lilac.withValues(alpha: 0.6) : T.hairline)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (selected) ...[Container(width: 6, height: 6, decoration: const BoxDecoration(color: T.lilac, shape: BoxShape.circle)), const SizedBox(width: 6)],
          Text(label, style: T.ui(12.5, FontWeight.w600, fg)),
          if (count != null) ...[const SizedBox(width: 6), Text('$count', style: T.dot(11, fg.withValues(alpha: 0.6)))],
        ]),
      ),
    );
  }
}

enum PillStyle { glass, primary, smart }

class PillButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final PillStyle style;
  final VoidCallback? onTap;
  const PillButton({super.key, required this.label, this.icon, this.style = PillStyle.glass, this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = style == PillStyle.primary ? Colors.black : T.text;
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(99),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: style == PillStyle.primary ? Colors.white : (style == PillStyle.smart ? null : T.glassFill),
            gradient: style == PillStyle.smart ? LinearGradient(colors: [T.lightBlue.withValues(alpha: 0.3), T.peach.withValues(alpha: 0.25), T.lilac.withValues(alpha: 0.3)]) : null,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: style == PillStyle.smart ? T.lilac.withValues(alpha: 0.7) : (style == PillStyle.primary ? Colors.white : T.hairline)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 15, color: fg), const SizedBox(width: 7)],
            Text(label, style: T.ui(13, FontWeight.w600, fg)),
          ]),
        ),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  final TrackStatus status;
  final double size;
  const StatusDot(this.status, {super.key, this.size = 16});
  @override
  Widget build(BuildContext context) {
    switch (status) {
      case TrackStatus.downloaded:
        return Container(
          width: size, height: size,
          decoration: const BoxDecoration(color: T.lilac, shape: BoxShape.circle),
          child: Icon(Icons.check, size: size * 0.65, color: Colors.black),
        );
      case TrackStatus.missing:
        return SizedBox(width: size, height: size, child: CustomPaint(painter: _DashedCircle()));
      case TrackStatus.ignored:
        return Icon(Icons.block, size: size, color: T.text3);
    }
  }
}

class _DashedCircle extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final paint = Paint()
      ..color = T.text3
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    final r = s.width / 2 - 1;
    for (var i = 0; i < 12; i++) {
      final a = i * math.pi / 6;
      c.drawArc(Rect.fromCircle(center: Offset(s.width / 2, s.height / 2), radius: r), a, math.pi / 12, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class BpmReadout extends StatelessWidget {
  final double? bpm;
  final bool unsure;
  final double size;
  const BpmReadout(this.bpm, {super.key, this.unsure = false, this.size = 17});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(bpm == null ? '–' : bpm!.round().toString(), style: T.dot(size, bpm == null ? T.text3 : T.text)),
        if (unsure) Text('?', style: T.dot(size * 0.7, T.peach)),
      ]);
}

class KeyBadge extends StatelessWidget {
  final String camelot;
  final bool unsure;
  final bool large;
  const KeyBadge(this.camelot, {super.key, this.unsure = false, this.large = false});
  @override
  Widget build(BuildContext context) {
    if (camelot.isEmpty) return Text('–', style: T.dot(large ? 22 : 13, T.text3));
    final c = T.camelot(camelot);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: large ? 12 : 8, vertical: large ? 5 : 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(99), border: Border.all(color: c.withValues(alpha: 0.35))),
      child: Text(camelot + (unsure ? '?' : ''), style: T.dot(large ? 22 : 13, c)),
    );
  }
}

class EnergyMeter extends StatelessWidget {
  final double? value;
  final double height;
  const EnergyMeter(this.value, {super.key, this.height = 12});
  @override
  Widget build(BuildContext context) {
    final level = value == null ? 0 : (value! * 5).ceil();
    return Opacity(
      opacity: value == null ? 0.5 : 1,
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var i = 0; i < 5; i++)
          Container(
            margin: const EdgeInsets.only(right: 2),
            width: 4,
            height: height * (0.5 + i * 0.125),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(1.5),
              gradient: i < level ? T.smart : null,
              color: i < level ? null : T.hairline,
            ),
          ),
      ]),
    );
  }
}

/// Album art from the cache (downloading the Spotify cover if needed), with a tinted placeholder.
class Artwork extends StatefulWidget {
  final LibraryTrack track;
  final LibraryStore store;
  final double size;
  final double radius;
  const Artwork({super.key, required this.track, required this.store, required this.size, this.radius = 8});
  @override
  State<Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<Artwork> {
  File? file;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant Artwork old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id) {
      file = null;
      _load();
    }
  }

  Future<void> _load() async {
    final f = await widget.store.ensureArtwork(widget.track);
    if (mounted && f != null) setState(() => file = f);
  }

  @override
  Widget build(BuildContext context) {
    final tint = T.tint(widget.track.album ?? widget.track.id);
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: file != null
            ? Image.file(file!, fit: BoxFit.cover, cacheWidth: (widget.size * 2).round(), gaplessPlayback: true)
            : DecoratedBox(
                decoration: BoxDecoration(gradient: LinearGradient(colors: [tint.withValues(alpha: 0.55), tint.withValues(alpha: 0.15)])),
                child: Icon(Icons.music_note, size: widget.size * 0.35, color: Colors.white.withValues(alpha: 0.35)),
              ),
      ),
    );
  }
}

/// The WreckBox logo: a 32×32 pixel vinyl record (same drawing as the Mac app's PixelRecord).
class PixelRecordLogo extends StatelessWidget {
  final double size;
  final bool withTile; // beige rounded square behind, like the app icon
  const PixelRecordLogo({super.key, this.size = 34, this.withTile = true});

  @override
  Widget build(BuildContext context) {
    final record = CustomPaint(size: Size.square(withTile ? size * 0.78 : size), painter: _PixelRecordPainter());
    if (!withTile) return record;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.225),
        gradient: const LinearGradient(colors: [Color(0xFFF1ECE4), Color(0xFFDCD5CA)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
      ),
      alignment: Alignment.center,
      child: record,
    );
  }
}

class _PixelRecordPainter extends CustomPainter {
  static Color? cell(int x, int y) {
    const c = 31 / 2;
    final dx = x - c, dy = y - c;
    final r = math.sqrt(dx * dx + dy * dy);
    final angle = math.atan2(dy, dx) * 180 / math.pi;
    if (r < 1.6) return null;
    if (r < 3.6) return T.lilac;
    if (r < 5.6) return T.peach;
    if (r < 6.3) return const Color(0xFF050506);
    if (r < 14.6) {
      final glint = (angle > -150 && angle < -118) || (angle > 30 && angle < 62);
      final band = ((r - 6.3) / 1.7).floor() % 2 == 0;
      if (glint) return band ? const Color(0xFF4A4A56) : const Color(0xFF5C5C6A);
      return band ? const Color(0xFF15151A) : const Color(0xFF202027);
    }
    if (r < 15.6) return const Color(0xFF34343E);
    return null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final px = size.width / 32;
    final paint = Paint()..isAntiAlias = false;
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final c = cell(x, y);
        if (c == null) continue;
        paint.color = c;
        canvas.drawRect(Rect.fromLTWH(x * px, y * px, px + 0.5, px + 0.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
