// Spectrum for the full-screen player's visualisers. On Android, the phone's own audio through Android's
// Visualizer (needs the microphone permission — Android counts reading the output as recording; nothing is
// recorded or sent anywhere). Without it, or for music playing on another device, a beat-synced estimate from the
// track's BPM keeps it moving.

import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'player.dart';

class Spectrum {
  static const bands = 32;
  static const _control = MethodChannel('wreckbox/visualizer');
  static const _data = EventChannel('wreckbox/visualizer/fft');

  /// Smoothed 0…1 levels, ~30 times a second, while someone listens.
  static Stream<List<double>> levels({required bool local, required double bpm, required bool Function() playing}) {
    late StreamController<List<double>> out;
    StreamSubscription? sub;
    Timer? tick;
    var smooth = List<double>.filled(bands, 0);
    var target = List<double>.filled(bands, 0);
    var real = false;
    final start = DateTime.now();

    Future<void> begin() async {
      if (local && await Permission.microphone.request().isGranted) {
        final session = Player.instance.audio.androidAudioSessionId;
        if (session != null) {
          try {
            await _control.invokeMethod('start', session);
            real = true;
            sub = _data.receiveBroadcastStream().listen((e) {
              target = List<double>.from((e as List).map((v) => (v as num).toDouble()));
            });
          } catch (_) {}
        }
      }
      tick = Timer.periodic(const Duration(milliseconds: 33), (_) {
        if (!real) target = estimate(DateTime.now().difference(start).inMilliseconds / 1000, bpm, playing());
        for (var i = 0; i < bands; i++) {
          smooth[i] = target[i] > smooth[i] ? smooth[i] + (target[i] - smooth[i]) * 0.6 : smooth[i] * 0.86 + target[i] * 0.14;
        }
        if (!out.isClosed) out.add(List.of(smooth));
      });
    }

    out = StreamController<List<double>>(
      onListen: begin,
      onCancel: () async {
        tick?.cancel();
        await sub?.cancel();
        if (real) {
          try {
            await _control.invokeMethod('stop');
          } catch (_) {}
        }
      },
    );
    return out.stream;
  }

  static List<double> estimate(double t, double bpm, bool playing) {
    if (!playing) return List.filled(bands, 0);
    final beat = t * max(bpm, 60) / 60;
    final kick = pow(max(0, cos(beat * pi * 2)), 6).toDouble();
    return List.generate(bands, (b) {
      final f = b / bands;
      final wobble = 0.5 + 0.5 * sin(t * (1.3 + b * 0.37) + b);
      return ((1 - f) * 0.55 * kick + 0.25 * wobble * (1 - f * 0.6) + 0.08).clamp(0, 1).toDouble();
    });
  }
}
