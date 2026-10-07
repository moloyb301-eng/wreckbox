// Playback across devices, like Spotify Connect: this phone tells the computer what it plays, sees what every other
// device plays (the computer, other phones), controls any of them, and can move the music from one to another.
// The computer is the hub: states go to POST /playback/state, the list of devices comes back as "playback" events on
// the live connection (/poll), and commands for this phone arrive as "playback-command" events.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

import 'account.dart';
import 'phone_sync.dart';
import 'player.dart';

class RemoteDevice {
  final String id, name, kind;
  final String? trackID;
  final bool playing;
  final double position, duration, updatedAt;
  final List<String>? queue;
  final int? index;
  final double? volume;
  final bool shuffle;

  RemoteDevice.fromJson(Map<String, dynamic> j)
      : id = j['id'] ?? '',
        name = j['name'] ?? '',
        kind = j['kind'] ?? 'phone',
        trackID = j['trackID'],
        playing = j['playing'] == true,
        position = (j['position'] as num?)?.toDouble() ?? 0,
        duration = (j['duration'] as num?)?.toDouble() ?? 0,
        updatedAt = (j['updatedAt'] as num?)?.toDouble() ?? 0,
        queue = (j['queue'] as List?)?.cast<String>(),
        index = j['index'] as int?,
        volume = (j['volume'] as num?)?.toDouble(),
        shuffle = j['shuffle'] == true;

  /// Where it is now, counting the time since it reported.
  double get livePosition {
    if (!playing) return position;
    final p = position + (DateTime.now().millisecondsSinceEpoch - updatedAt) / 1000;
    return duration > 0 ? p.clamp(0, duration).toDouble() : p;
  }
}

class PlaybackSync extends ChangeNotifier {
  static final PlaybackSync instance = PlaybackSync._();
  PlaybackSync._();

  PhoneSyncClient? client;
  Map<String, RemoteDevice> devices = {};
  String? activeID;
  Timer? _clock, _debounce;
  bool _hooked = false;

  String get myID => Account.deviceId();
  /// The phone's own name ("Galaxy S23 Ultra"), from Android settings.
  static String myName = 'Phone';
  static Future<void> loadName() async {
    if (!Platform.isAndroid) return;
    try {
      myName = await const MethodChannel('wreckbox/direct').invokeMethod<String>('deviceName') ?? myName;
    } catch (_) {}
  }
  DateTime _startedHere = DateTime(2000);

  /// Another device is the one playing (or last played): the bar shows and controls it.
  RemoteDevice? get remoteActive {
    final a = activeID == null ? null : devices[activeID];
    return a != null && a.id != myID && a.trackID != null ? a : null;
  }

  List<RemoteDevice> get others => devices.values.where((d) => d.id != myID).toList()..sort((a, b) => a.name.compareTo(b.name));

  /// Starts reporting this phone's player to the computer.
  void attach(PhoneSyncClient c) {
    client = c;
    if (_hooked) return;
    _hooked = true;
    loadName();
    final p = Player.instance;
    var wasPlaying = false;
    p.addListener(() {
      if (p.playing && !wasPlaying) _startedHere = DateTime.now();
      wasPlaying = p.playing;
    });
    p.addListener(_changed);
    p.audio.positionDiscontinuityStream.listen((_) => _changed()); // seeks
    Timer.periodic(const Duration(seconds: 15), (_) {
      if (p.playing) report();
    });
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), report);
  }

  Map<String, dynamic> _state() {
    final p = Player.instance;
    return {
      'id': myID,
      'name': myName,
      'kind': 'phone',
      'trackID': p.currentId,
      'playing': p.playing && p.audio.processingState != ProcessingState.completed,
      'position': p.audio.position.inMilliseconds / 1000,
      'duration': (p.audio.duration?.inMilliseconds ?? 0) / 1000,
      'queue': p.fullQueue,
      'index': p.fullIndex,
      'volume': p.audio.volume,
      'shuffle': p.shuffle,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
  }

  Future<void> report() async {
    final c = client, base = c?.base;
    if (base == null) return;
    try {
      await http
          .post(Uri.parse('$base/playback/state'),
              headers: {...PhoneSyncClient.authHeaders(), 'content-type': 'application/json'}, body: jsonEncode(_state()))
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  /// The devices right after connecting (later changes come as events).
  Future<void> fetch() async {
    final base = client?.base;
    if (base == null) return;
    try {
      final r = await http.get(Uri.parse('$base/playback'), headers: PhoneSyncClient.authHeaders()).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) onEvent('playback', jsonDecode(r.body));
    } catch (_) {}
    await report();
  }

  /// From PhoneSyncClient's live connection.
  void onEvent(String event, dynamic j) {
    if (event == 'playback' && j is Map) {
      devices = {for (final d in List<Map<String, dynamic>>.from(j['devices'] ?? const [])) d['id'] as String: RemoteDevice.fromJson(d)};
      activeID = j['active'] as String?;
      // Something else started playing: this phone stops (one device plays at a time) — unless it only just started
      // itself and the computer hasn't heard yet.
      final a = activeID == null ? null : devices[activeID];
      if (a != null && a.id != myID && a.playing && Player.instance.playing && DateTime.now().difference(_startedHere).inSeconds > 3) {
        Player.instance.audio.pause();
      }
      _clock?.cancel();
      if (devices.values.any((d) => d.playing && d.id != myID)) {
        _clock = Timer.periodic(const Duration(milliseconds: 500), (_) => notifyListeners());
      }
      notifyListeners();
    } else if (event == 'playback-command' && j is Map && j['target'] == myID) {
      _run(j['action'] as String? ?? '', Map<String, dynamic>.from(j['args'] ?? const {}));
    }
  }

  Future<void> _run(String action, Map<String, dynamic> args) async {
    final p = Player.instance;
    final v = (args['value'] as num?)?.toDouble();
    switch (action) {
      case 'play':
        await p.audio.play();
      case 'pause':
        await p.audio.pause();
      case 'toggle':
        await p.toggle();
      case 'next':
        await p.next();
      case 'previous':
        await p.previous();
      case 'seek':
        await p.audio.seek(Duration(milliseconds: ((v ?? 0) * 1000).round()));
      case 'volume':
        await p.audio.setVolume(v ?? 1);
      case 'shuffle':
        await p.setShuffle(v == null ? !p.shuffle : v > 0);
      case 'load':
        final q = List<String>.from(args['queue'] ?? const []);
        final i = (args['index'] as int?) ?? 0;
        if (q.isEmpty || i >= q.length) return;
        await p.play(q[i], list: q);
        final pos = (args['position'] as num?)?.toDouble() ?? 0;
        if (pos > 0) await p.audio.seek(Duration(milliseconds: (pos * 1000).round()));
        if (args['playing'] == false) await p.audio.pause();
    }
    _changed();
  }

  /// Controls `target` (default: the active device). Controlling this phone acts on its own player directly.
  Future<void> command(String action, {String? target, double? value}) async {
    final t = target ?? activeID ?? myID;
    if (t == myID) return _run(action, {'value': ?value});
    final base = client?.base;
    if (base == null) return;
    try {
      await http
          .post(Uri.parse('$base/playback/command'),
              headers: {...PhoneSyncClient.authHeaders(), 'content-type': 'application/json'},
              body: jsonEncode({'target': t, 'action': action, 'args': {'value': ?value}}))
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  /// Moves the music to `device` (this phone included) — the computer hands over queue and position.
  /// Always through the computer, which knows what plays where (moving to this phone included).
  Future<void> transferTo(String device) async {
    final base = client?.base;
    if (base == null) return;
    try {
      await http
          .post(Uri.parse('$base/playback/command'),
              headers: {...PhoneSyncClient.authHeaders(), 'content-type': 'application/json'},
              body: jsonEncode({'target': device, 'action': 'transfer', 'args': {}}))
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }
}
