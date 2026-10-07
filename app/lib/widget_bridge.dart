// The Android home-screen widget (PlayerWidget.kt): this side tells it what's playing — here or on another device —
// and runs its buttons: transport, ±10 s, volume, "play on Mac / here", EQ on/off and presets.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'eq.dart';
import 'player.dart';
import 'remote_playback.dart';
import 'store.dart';

class WidgetBridge {
  static const _ch = MethodChannel('wreckbox/widget');
  static Timer? _debounce;
  static LibraryStore? _store;
  static String? _lastArtFor;
  static String? _artPath;

  static void start(LibraryStore store) {
    if (!Platform.isAndroid) return;
    _store = store;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'action') await _action(call.arguments as String);
    });
    void changed() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), push);
    }

    Player.instance.addListener(changed);
    Player.instance.audio.positionDiscontinuityStream.listen((_) => changed());
    PlaybackSync.instance.addListener(changed);
    PhoneEQ.instance.addListener(changed);
    push();
  }

  /// Another device is playing and this phone isn't: the widget shows and controls that one.
  static RemoteDevice? get _remote => Player.instance.playing ? null : PlaybackSync.instance.remoteActive;

  static Future<void> push() async {
    final store = _store;
    if (store == null) return;
    final p = Player.instance, remote = _remote;
    final id = remote?.trackID ?? p.currentId;
    final t = id == null ? null : store.track(id);
    if (id != _lastArtFor) {
      _lastArtFor = id;
      _artPath = null;
      if (t != null) {
        try {
          _artPath = (await store.ensureArtwork(t))?.path;
        } catch (_) {}
      }
    }
    final eq = PhoneEQ.instance;
    try {
      await _ch.invokeMethod('update', {
        'title': t?.title,
        'artist': t?.artists.join(', '),
        'playing': remote?.playing ?? p.playing,
        'positionMs': ((remote?.livePosition ?? p.audio.position.inMilliseconds / 1000) * 1000).round(),
        'durationMs': ((remote?.duration ?? (p.audio.duration?.inMilliseconds ?? 0) / 1000) * 1000).round(),
        'wallMs': DateTime.now().millisecondsSinceEpoch,
        'device': remote == null ? 'PHONE' : (remote.kind == 'mac' ? 'MAC' : remote.name.toUpperCase()),
        'format': _format(id, remote != null),
        'bpm': id == null ? null : store.row(id)?.bpm, // the widget's spectrum flips in time with it
        'track': _track(remote),
        'volume': remote?.volume ?? p.audio.volume,
        'art': _artPath,
        'eqOn': eq.on,
        'eqPreset': eq.preset,
        'gains': eq.gains.map((g) => g.toStringAsFixed(1)).join(','),
      });
    } catch (_) {}
  }

  /// The LCD's format badge: the file's own format here, or what the stream is being sent as.
  static String _format(String? id, bool elsewhere) {
    if (id == null) return '';
    final p = Player.instance;
    if (!elsewhere && !p.isRemote(id)) {
      final path = _store?.state.tracks[id]?.localPath ?? '';
      final dot = path.lastIndexOf('.');
      return dot < 0 ? '' : path.substring(dot + 1).toUpperCase();
    }
    return switch (p.quality ?? 'flac') { 'high' => 'AAC 256', 'med' => 'AAC 160', 'low' => 'AAC 96', _ => 'FLAC' };
  }

  /// "007/121", like the old players' track counters.
  static String _track(RemoteDevice? remote) {
    final q = remote?.queue ?? Player.instance.fullQueue;
    final i = remote?.index ?? Player.instance.fullIndex;
    if (q.isEmpty || i < 0) return '';
    return '${(i + 1).toString().padLeft(3, '0')}/${q.length.toString().padLeft(3, '0')}';
  }

  static Future<void> _action(String a) async {
    final p = Player.instance, sync = PlaybackSync.instance, remote = _remote;
    Future<void> cmd(String action, [double? value]) => sync.command(action, value: value);
    switch (a) {
      case 'toggle':
        remote != null ? await cmd('toggle') : await p.toggle();
      case 'next':
        remote != null ? await cmd('next') : await p.next();
      case 'previous':
        remote != null ? await cmd('previous') : await p.previous();
      case 'stop':
        if (remote != null) {
          await cmd('pause');
          await cmd('seek', 0);
        } else {
          await p.audio.pause();
          await p.audio.seek(Duration.zero);
        }
      case 'back10' || 'fwd10':
        final d = a == 'back10' ? -10.0 : 10.0;
        if (remote != null) {
          await cmd('seek', (remote.livePosition + d).clamp(0, remote.duration).toDouble());
        } else {
          final to = p.audio.position + Duration(seconds: d.toInt());
          await p.audio.seek(to < Duration.zero ? Duration.zero : to);
        }
      case 'restart':
        remote != null ? await cmd('seek', 0) : await p.audio.seek(Duration.zero);
      case 'voldown' || 'volup':
        final d = a == 'voldown' ? -0.1 : 0.1;
        if (remote != null) {
          await cmd('volume', ((remote.volume ?? 1) + d).clamp(0, 1).toDouble());
        } else {
          await p.audio.setVolume((p.audio.volume + d).clamp(0, 1).toDouble());
        }
      case 'handoff':
        // Here → the computer; elsewhere → this phone.
        if (remote != null) {
          await sync.transferTo(sync.myID);
        } else {
          final mac = sync.others.where((d) => d.kind == 'mac').firstOrNull;
          if (mac != null) await sync.transferTo(mac.id);
        }
      case 'eqtoggle':
        await PhoneEQ.instance.setOn(!PhoneEQ.instance.on);
      default:
        if (a.startsWith('preset:')) await PhoneEQ.instance.choose(a.substring(7));
    }
    await push();
  }
}
