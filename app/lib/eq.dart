// Phone EQ: the same 10 bands and presets as the computer's player. Android's equaliser has its own bands
// (usually 5); each gets the 10-band curve's value at its centre frequency.

import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'settings.dart';

class PhoneEQ extends ChangeNotifier {
  static final PhoneEQ instance = PhoneEQ._();
  PhoneEQ._();

  /// Handed to the player's audio pipeline (Android only).
  final AndroidEqualizer android = AndroidEqualizer();

  static const frequencies = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];
  static const labels = ['32', '64', '125', '250', '500', '1K', '2K', '4K', '8K', '16K'];
  static const presets = <String, List<double>>{
    'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Bass boost': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
    'Club': [4, 3, 2, 0, -1, -1, 0, 2, 3, 3],
    'Hip-hop': [5, 4, 1, 2, -1, -1, 1, 0, 2, 3],
    'Electronic': [4, 3, 1, 0, -2, 1, 0, 1, 3, 4],
    'Vocal': [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1],
    'Treble': [0, 0, 0, 0, 0, 1, 2, 4, 5, 6],
    'Loudness': [5, 3, 0, 0, -1, 0, -1, 0, 3, 4],
  };

  bool get on => Settings.current.eqOn;
  String get preset => Settings.current.eqPreset;
  List<double> get gains => Settings.current.eqGains;

  Future<void> setOn(bool v) async {
    Settings.current.eqOn = v;
    await _changed();
  }

  Future<void> choose(String name) async {
    final p = presets[name];
    if (p == null) return;
    Settings.current
      ..eqGains = List.of(p)
      ..eqPreset = name;
    await _changed();
  }

  Future<void> set(int band, double gain) async {
    Settings.current
      ..eqGains[band] = gain.clamp(-12, 12).toDouble()
      ..eqPreset = 'Custom';
    await _changed(save: false);
  }

  /// Saves (unless dragging) and pushes the curve to the phone's equaliser.
  Future<void> _changed({bool save = true}) async {
    notifyListeners();
    if (save) await Settings.current.save();
    await apply();
  }

  Future<void> save() => Settings.current.save();

  /// The 10-band curve at `hz` (linear between bands on a log-frequency axis).
  static double curveAt(List<double> g, double hz) {
    final x = log(hz.clamp(frequencies.first, frequencies.last)) ;
    for (var i = 0; i < frequencies.length - 1; i++) {
      final a = log(frequencies[i]), b = log(frequencies[i + 1]);
      if (x <= b) return g[i] + (g[i + 1] - g[i]) * ((x - a) / (b - a));
    }
    return g.last;
  }

  /// Once the player has something loaded, the equaliser's bands are known.
  Future<void> apply() async {
    if (!Platform.isAndroid) return;
    try {
      await android.setEnabled(on);
      final params = await android.parameters.timeout(const Duration(seconds: 3));
      for (final b in params.bands) {
        final db = curveAt(gains, b.centerFrequency).clamp(params.minDecibels, params.maxDecibels).toDouble();
        await b.setGain(db);
      }
    } catch (_) {}
  }
}
