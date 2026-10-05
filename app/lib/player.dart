// Built-in player: plays your own files (FLAC, MP3, …). On the phone, a track that isn't on the phone but is on
// the paired computer streams from the computer over Wi-Fi. No streaming from music services.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'models.dart';
import 'settings.dart';
import 'store.dart';

class Player extends ChangeNotifier {
  static late Player instance;

  final LibraryStore store;
  final AudioPlayer audio = AudioPlayer();
  List<String> queue = [];
  int index = -1;
  String? error;

  /// Track ids the paired computer can stream (phone only).
  Set<String> remoteIds = {};

  Player(this.store) {
    audio.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        next();
      } else {
        notifyListeners();
      }
    });
  }

  String? get currentId => index >= 0 && index < queue.length ? queue[index] : null;
  bool get playing => audio.playing;

  String? _localPath(String id) {
    final st = store.state.tracks[id];
    return st?.status == TrackStatus.downloaded && st?.localPath != null && File(st!.localPath!).existsSync() ? st.localPath : null;
  }

  bool canPlay(String id) => _localPath(id) != null || remoteIds.contains(id);
  bool isRemote(String id) => _localPath(id) == null && remoteIds.contains(id);

  /// Plays `id`; next / previous move through `list` (only the playable tracks in it).
  Future<void> play(String id, {List<String>? list}) async {
    final playable = (list ?? [id]).where(canPlay).toList();
    if (!playable.contains(id)) playable.insert(0, id);
    queue = playable;
    index = queue.indexOf(id);
    await _load();
  }

  Future<void> _load() async {
    final id = currentId;
    if (id == null) return;
    error = null;
    try {
      final local = _localPath(id);
      if (local != null) {
        await audio.setFilePath(local);
      } else {
        final base = Settings.current.pairedDesktop, token = Settings.current.pairToken;
        if (base == null || token == null) throw Exception('not on this device');
        await audio.setUrl('$base/file/${Uri.encodeComponent(id)}?t=$token');
      }
      notifyListeners();
      await audio.play();
    } catch (e) {
      error = "Can't play ${store.describe(id)}: $e";
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    if (audio.playing) {
      await audio.pause();
    } else {
      await audio.play();
    }
    notifyListeners();
  }

  Future<void> next() async {
    if (index + 1 < queue.length) {
      index++;
      await _load();
    } else {
      await audio.stop();
      notifyListeners();
    }
  }

  Future<void> previous() async {
    // Like most players: restart the track unless we're at its very beginning.
    if (audio.position > const Duration(seconds: 3) || index == 0) {
      await audio.seek(Duration.zero);
    } else {
      index--;
      await _load();
    }
  }

  Future<void> stop() async {
    await audio.stop();
    queue = [];
    index = -1;
    notifyListeners();
  }

  @override
  void dispose() {
    audio.dispose();
    super.dispose();
  }
}
