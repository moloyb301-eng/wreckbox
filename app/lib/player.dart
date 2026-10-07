// Built-in player: plays your own files (FLAC, MP3, …). On the phone, a track that isn't on the phone but is on
// the paired computer streams from the computer — on Wi-Fi or from anywhere through its tunnel. No streaming from
// music services.
//
// Streaming is built to feel instant: the whole queue is handed to the player at once so the next track is
// already loading before this one ends, streamed tracks are cached on the phone while they play (seeking and
// replays don't wait for the network), the computer prepares the next few tracks in the chosen quality, and on
// Android playback continues in the background with lock-screen / notification controls.

import 'dart:async';
import 'dart:io';

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'eq.dart';
import 'friends.dart';
import 'models.dart';
import 'phone_sync.dart';
import 'settings.dart';
import 'store.dart';
import 'ui/account_ui.dart' show AccountConnect;

class Player extends ChangeNotifier {
  static late Player instance;

  /// Android: lock-screen and notification controls. Call before the first Player is made.
  static Future<void> initBackground() async {
    if (!Platform.isAndroid) return;
    await JustAudioBackground.init(
      androidNotificationChannelId: 'app.wreckbox.playback',
      androidNotificationChannelName: 'Playback',
      androidNotificationOngoing: true,
    );
  }

  final LibraryStore store;
  // Android: through the EQ (eq.dart).
  final AudioPlayer audio = Platform.isAndroid ? AudioPlayer(audioPipeline: AudioPipeline(androidAudioEffects: [PhoneEQ.instance.android])) : AudioPlayer();
  List<String> queue = [];
  String? error;
  String? quality; // what the streamed tracks in this queue were asked for

  /// Track ids the paired computer can stream (phone only). Setting it refreshes the lists' play buttons.
  Set<String> _remoteIds = {};
  Set<String> get remoteIds => _remoteIds;
  set remoteIds(Set<String> ids) {
    _remoteIds = ids;
    notifyListeners();
  }

  /// Set by the phone app so the player can ask the computer to prepare upcoming tracks.
  PhoneSyncClient? client;

  /// Windows / Mac desktop keep the simple one-track-at-a-time player (unchanged); the phone gets the queue player.
  static final bool _desktop = !(Platform.isAndroid || Platform.isIOS);
  int _desktopIndex = -1;

  Player(this.store) {
    audio.playerStateStream.listen((s) {
      if (_desktop && s.processingState == ProcessingState.completed) {
        next();
      } else {
        notifyListeners();
      }
    });
    audio.currentIndexStream.listen((_) {
      notifyListeners();
      _remember();
      _prepareAhead();
      _topUp();
    });
    audio.playbackEventStream.listen((_) {}, onError: (Object e, StackTrace _) {
      error = "Can't play ${currentId == null ? 'this track' : store.describe(currentId!)}: $e";
      notifyListeners();
    });
  }

  /// The whole queue (the part handed to the player + the rest) and where we are in it, for other devices.
  List<String> get fullQueue => [...queue, ..._rest];
  int get fullIndex => index;

  int get index => _desktop ? _desktopIndex : (audio.currentIndex ?? -1);
  String? get currentId => index >= 0 && index < queue.length ? queue[index] : null;
  bool get playing => audio.playing;

  String? _localPath(String id) {
    final st = store.state.tracks[id];
    return st?.status == TrackStatus.downloaded && st?.localPath != null && File(st!.localPath!).existsSync() ? st.localPath : null;
  }

  bool canPlay(String id) => _localPath(id) != null || remoteIds.contains(id) || Friends.instance.has(id);
  bool isRemote(String id) => _localPath(id) == null && remoteIds.contains(id);

  static Directory? _cacheDir;
  Future<File> _cacheFile(String id, String q) async {
    _cacheDir ??= Directory(p.join((await getTemporaryDirectory()).path, 'stream-cache'));
    await _cacheDir!.create(recursive: true);
    return File(p.join(_cacheDir!.path, '${sha1.convert(utf8.encode('$q:$id'))}.audio'));
  }

  Future<AudioSource> _source(String id, String q) async {
    final t = store.track(id);
    final art = t?.artworkURL;
    final tag = MediaItem(
      id: id,
      title: t?.title ?? id,
      artist: t?.artists.join(', '),
      album: t?.album,
      artUri: art == null ? null : Uri.tryParse(art),
    );
    final local = _localPath(id) ?? (remoteIds.contains(id) ? null : Friends.instance.savedFile(id));
    if (local != null) return AudioSource.file(local, tag: tag);
    // A friend's track (not on this phone or your own computer): from their computer, with their share's ticket.
    if (!remoteIds.contains(id)) {
      final f = await Friends.instance.streamOf(id, q);
      if (f != null) {
        // ignore: experimental_member_use
        return LockCachingAudioSource(f.$1, headers: f.$2, cacheFile: await _cacheFile('friend:$id', q), tag: tag);
      }
    }
    final s = Settings.current;
    final base = s.pairedDesktop, token = s.pairToken;
    if (base == null || token == null) throw Exception('not on this device');
    // Cached while it plays: seeking back and replays come from the phone.
    // ignore: experimental_member_use
    return LockCachingAudioSource(
      Uri.parse('$base/file/${Uri.encodeComponent(id)}?q=$q'),
      headers: PhoneSyncClient.authHeaders(token),
      cacheFile: await _cacheFile(id, q),
      tag: tag,
    );
  }

  /// Plays `id`; next / previous move through `list` (only the playable tracks in it).
  Future<void> play(String id, {List<String>? list}) async {
    error = null;
    final playable = (list ?? [id]).where(canPlay).toList();
    if (!playable.contains(id)) playable.insert(0, id);
    _ordered = playable;
    // Shuffle on: this track first, the rest in random order.
    queue = shuffle ? [id, ...(playable.where((t) => t != id).toList()..shuffle())] : playable;
    if (_desktop) {
      _desktopIndex = queue.indexOf(id);
      return _loadDesktop();
    }
    // Only a window of the list goes to the player (this track + the next ones), so playback starts at once even
    // in a 1,000-track list; more are added as it plays.
    final start = queue.indexOf(id);
    queue = queue.sublist(start);
    try {
      await AccountConnect.refreshIfNeeded();
      quality = await PhoneSyncClient.streamQuality();
      _rest = queue.length > _window ? queue.sublist(_window) : [];
      queue = queue.take(_window).toList();
      final sources = [for (final t in queue) await _source(t, quality!)];
      await audio.setAudioSources(sources, initialIndex: 0, preload: true);
      unawaited(PhoneEQ.instance.apply()); // the equaliser's bands are known once something is loaded
      notifyListeners();
      unawaited(audio.play());
    } catch (e) {
      error = "Can't play ${store.describe(id)}: $e";
      notifyListeners();
    }
  }

  Future<void> _loadDesktop() async {
    final id = currentId;
    if (id == null) return;
    error = null;
    try {
      final local = _localPath(id);
      if (local == null) throw Exception('not on this device');
      await audio.setFilePath(local);
      notifyListeners();
      await audio.play();
    } catch (e) {
      error = "Can't play ${store.describe(id)}: $e";
      notifyListeners();
    }
  }

  /// The list in its own order, to go back to when shuffle is turned off.
  List<String> _ordered = [];
  bool get shuffle => Settings.current.shuffle;

  /// Shuffle on: the tracks after this one in random order; off: back to the list's order from here on.
  Future<void> setShuffle(bool on) async {
    Settings.current.shuffle = on;
    unawaited(Settings.current.save());
    notifyListeners();
    final id = currentId;
    if (_desktop || id == null) return;
    final full = fullQueue, at = index;
    final List<String> upcoming;
    if (on) {
      upcoming = full.sublist(at + 1)..shuffle();
    } else {
      final i = _ordered.indexOf(id);
      upcoming = i < 0 ? full.sublist(at + 1) : _ordered.sublist(i + 1);
    }
    // Swap what the player has queued after this track for the new order.
    if (at + 1 < queue.length) await audio.removeAudioSourceRange(at + 1, queue.length);
    queue = queue.take(at + 1).toList();
    _rest = upcoming;
    await _topUp();
    notifyListeners();
  }

  /// Plays a list shuffled (playlists' Shuffle button): shuffle on, a random first track.
  Future<void> playShuffled(List<String> list) async {
    final playable = list.where(canPlay).toList();
    if (playable.isEmpty) return;
    Settings.current.shuffle = true;
    unawaited(Settings.current.save());
    await play(playable[DateTime.now().microsecond % playable.length], list: playable);
  }

  static const _window = 25;
  List<String> _rest = []; // the rest of the list, added to the player as it gets close

  Future<void> _topUp() async {
    if (_desktop || _rest.isEmpty || queue.length - index > 10 || quality == null) return;
    final more = _rest.take(_window).toList();
    _rest = _rest.skip(more.length).toList();
    queue = [...queue, ...more];
    try {
      await AccountConnect.refreshIfNeeded(); // a long session outlives a ticket: new tracks get a fresh one
      await Friends.instance.refreshIfNeeded();
      await audio.addAudioSources([for (final t in more) await _source(t, quality!)]);
    } catch (_) {}
  }

  /// Asks the computer to make the next three streamed tracks ready in this queue's quality.
  void _prepareAhead() {
    final q = quality, c = client;
    if (q == null || c == null || index < 0) return;
    final next = queue.skip(index + 1).take(3).where(isRemote).toList();
    if (next.isNotEmpty) c.prepare(next, q);
  }

  Future<void> toggle() async {
    if (audio.playing) {
      await audio.pause();
      _remember();
    } else if (currentId == null) {
      await resume(); // nothing loaded (e.g. the widget after a restart): pick up the last queue
    } else {
      await audio.play();
    }
    notifyListeners();
  }

  /// Saves the queue and position, so play after a restart carries on where it was.
  void _remember() {
    if (_desktop || currentId == null) return;
    Settings.current
      ..lastQueue = fullQueue.take(500).toList()
      ..lastIndex = index
      ..lastPositionMs = audio.position.inMilliseconds;
    Settings.current.save();
  }

  /// Plays the last saved queue from where it stopped. No-op when there's none.
  Future<void> resume() async {
    final s = Settings.current;
    if (s.lastQueue.isEmpty || s.lastIndex < 0 || s.lastIndex >= s.lastQueue.length) return;
    await play(s.lastQueue[s.lastIndex], list: s.lastQueue.sublist(s.lastIndex));
    if (s.lastPositionMs > 0) await audio.seek(Duration(milliseconds: s.lastPositionMs));
  }

  Future<void> next() async {
    if (_desktop) {
      if (_desktopIndex + 1 < queue.length) {
        _desktopIndex++;
        await _loadDesktop();
      } else {
        await audio.stop();
        notifyListeners();
      }
      return;
    }
    if (audio.hasNext) {
      await audio.seekToNext();
    } else {
      await audio.stop();
    }
    notifyListeners();
  }

  Future<void> previous() async {
    // Like most players: restart the track unless we're at its very beginning.
    if (_desktop) {
      if (audio.position > const Duration(seconds: 3) || _desktopIndex <= 0) {
        await audio.seek(Duration.zero);
      } else {
        _desktopIndex--;
        await _loadDesktop();
      }
      return;
    }
    if (audio.position > const Duration(seconds: 3) || !audio.hasPrevious) {
      await audio.seek(Duration.zero);
    } else {
      await audio.seekToPrevious();
    }
    notifyListeners();
  }

  Future<void> stop() async {
    await audio.stop();
    queue = [];
    _rest = [];
    _desktopIndex = -1;
    notifyListeners();
  }

  @override
  void dispose() {
    audio.dispose();
    super.dispose();
  }
}
