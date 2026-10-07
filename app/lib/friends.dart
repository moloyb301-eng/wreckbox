// Friends' music: a key (WBX-XXXXX-XXXXX-XXXXX) or share link a friend made on their Mac opens their whole
// library or one playlist. The account service hands out the friend's computer address and a 6-hour ticket signed
// by that computer, which lets this phone list, stream and download what was shared — nothing else. Tracks stream
// through the normal player (cached while they play); Download saves a copy to Music/WreckBox/Friends/<friend>/.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'config.dart';
import 'models.dart';
import 'paths.dart';

class FriendShare {
  final String id, key, kind, owner, computer;
  final String? playlist;
  String? url, ticket;
  int expires; // ms since 1970
  bool online;

  FriendShare({required this.id, required this.key, required this.kind, required this.owner, required this.computer,
      this.playlist, this.url, this.ticket, this.expires = 0, this.online = false});

  String get title => kind == 'playlist' ? (playlist ?? 'Playlist') : "$owner's library";

  factory FriendShare.fromJson(Map<String, dynamic> j, {String? key}) => FriendShare(
        id: j['id'] as String,
        key: key ?? j['key'] as String,
        kind: j['kind'] as String? ?? 'library',
        owner: j['owner'] as String? ?? 'A friend',
        computer: j['computer'] as String? ?? '',
        playlist: j['playlist'] as String?,
        url: j['url'] as String?,
        ticket: j['ticket'] as String?,
        expires: (j['expires'] as num?)?.toInt() ?? 0,
        online: j['online'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id, 'key': key, 'kind': kind, 'owner': owner, 'computer': computer, 'playlist': playlist,
        'url': url, 'ticket': ticket, 'expires': expires, 'online': online,
      };
}

class FriendTrack {
  final LibraryTrack track;
  final String share, ext;
  final String? quality;
  FriendTrack(this.track, this.share, this.ext, this.quality);
  String get id => track.id;
}

class Friends extends ChangeNotifier {
  static final Friends instance = Friends._();
  Friends._();

  List<FriendShare> shares = [];
  final Map<String, List<FriendTrack>> tracks = {}; // share id → tracks
  final Map<String, String> status = {}; // share id → "Loading…" / error
  final Map<String, String> jobs = {}; // track id → "downloading" / "done" / error
  final Map<String, FriendTrack> _byId = {};
  Map<String, String> _saved = {}; // track id → downloaded file

  static File get _file => File(p.join(AppPaths.settingsDir.path, 'friends.json'));

  Future<void> init() async {
    try {
      final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      shares = [for (final s in (j['shares'] as List? ?? const [])) FriendShare.fromJson(Map<String, dynamic>.from(s))];
      _saved = Map<String, String>.from(j['saved'] ?? const {});
    } catch (_) {}
  }

  Future<void> _save() => writeAtomic(_file, jsonEncode({'shares': [for (final s in shares) s.toJson()], 'saved': _saved}));

  /// The key in a pasted key, share link or wreckbox://share link.
  static String? keyFrom(String text) => RegExp(r'WBX-[0-9A-Z]{5}-[0-9A-Z]{5}-[0-9A-Z]{5}').firstMatch(text.toUpperCase())?.group(0);

  Future<FriendShare> _open(String key) async {
    final res = await http
        .post(Uri.parse('${AppConfig.accountApi}/v1/shares/open'), headers: {'content-type': 'application/json'}, body: jsonEncode({'key': key}))
        .timeout(const Duration(seconds: 20));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) throw Exception(j['error'] ?? "Couldn't open that key.");
    return FriendShare.fromJson(j, key: key);
  }

  Future<void> add(String text) async {
    final key = keyFrom(text);
    if (key == null) throw Exception("That doesn't look like a WreckBox key (WBX-…).");
    final s = await _open(key);
    shares.removeWhere((x) => x.id == s.id);
    shares.insert(0, s);
    await _save();
    notifyListeners();
    await load(s.id);
  }

  Future<void> remove(String id) async {
    shares.removeWhere((s) => s.id == id);
    tracks.remove(id)?.forEach((t) => _byId.remove(t.id));
    await _save();
    notifyListeners();
  }

  /// The share with a ticket good for 10 more minutes (reopened with its key when it's older).
  Future<FriendShare> fresh(String id) async {
    final i = shares.indexWhere((s) => s.id == id);
    if (i < 0) throw Exception('not added');
    final s = shares[i];
    if (s.ticket != null && s.url != null && s.expires > DateTime.now().millisecondsSinceEpoch + 600000) return s;
    final n = await _open(s.key);
    shares[i] = n;
    await _save();
    return n;
  }

  /// Fresh tickets for every share in the queue (the player calls this before adding more tracks).
  Future<void> refreshIfNeeded() async {
    for (final s in [...shares]) {
      try {
        await fresh(s.id);
      } catch (_) {}
    }
  }

  static Map<String, String> headers(FriendShare s) => {'authorization': 'Bearer ${s.ticket ?? ''}'};

  Future<dynamic> _get(FriendShare s, String path) async {
    if (s.url == null) throw Exception("${s.owner}'s computer is offline.");
    final res = await http.get(Uri.parse('${s.url}$path'), headers: headers(s)).timeout(const Duration(seconds: 30));
    if (res.statusCode == 403) throw Exception('${s.owner} stopped sharing this.');
    if (res.statusCode != 200) throw Exception("${s.owner}'s computer didn't answer (${res.statusCode}).");
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<void> load(String id) async {
    status[id] = 'Loading…';
    notifyListeners();
    try {
      final s = await fresh(id);
      final lib = await _get(s, '/library.json') as Map<String, dynamic>;
      final crate = {for (final c in (await _get(s, '/crate') as List)) c['id'] as String: Map<String, dynamic>.from(c)};
      final all = {for (final t in (lib['tracks'] as List)) t['id'] as String: LibraryTrack.fromJson(Map<String, dynamic>.from(t))};
      final lists = (lib['playlists'] as List? ?? const []);
      final List<String> order;
      if (s.kind == 'playlist' && lists.isNotEmpty) {
        order = List<String>.from(lists.first['trackIDs'] ?? const []);
      } else {
        order = (all.values.toList()..sort((a, b) => (b.firstAdded ?? '').compareTo(a.firstAdded ?? ''))).map((t) => t.id).toList();
      }
      tracks[id] = [
        for (final tid in order)
          if (all[tid] != null && crate[tid] != null) FriendTrack(all[tid]!, id, crate[tid]!['ext'] as String? ?? '', crate[tid]!['quality'] as String?)
      ];
      for (final t in tracks[id]!) {
        _byId[t.id] = t;
      }
      status.remove(id);
    } catch (e) {
      status[id] = '$e'.replaceFirst('Exception: ', '');
    }
    notifyListeners();
  }

  // MARK: for the player and the library store

  bool has(String id) => _byId.containsKey(id);
  LibraryTrack? track(String id) => _byId[id]?.track;

  /// A copy downloaded from a friend, if it's still there.
  String? savedFile(String id) {
    final f = _saved[id];
    return f != null && File(f).existsSync() ? f : null;
  }

  /// Where to stream `id` from, and with which headers.
  Future<(Uri, Map<String, String>)?> streamOf(String id, String q) async {
    final t = _byId[id];
    if (t == null) return null;
    final s = await fresh(t.share);
    if (s.url == null) return null;
    return (Uri.parse('${s.url}/file/${Uri.encodeComponent(id)}?q=$q'), headers(s));
  }

  /// Saves the original file to Music/WreckBox/Friends/<friend>/Artist - Title.ext.
  Future<void> download(String id) async {
    final t = _byId[id];
    if (t == null) return;
    jobs[id] = 'downloading';
    notifyListeners();
    try {
      final s = await fresh(t.share);
      final dir = Directory(p.join(AppPaths.root.path, 'Friends', _safe(s.owner)));
      await dir.create(recursive: true);
      final dest = File(p.join(dir.path, '${_safe('${t.track.artists.join(', ')} - ${t.track.title}')}${t.ext}'));
      final part = File('${dest.path}.part');
      final client = http.Client();
      try {
        final res = await client.send(http.Request('GET', Uri.parse('${s.url}/file/${Uri.encodeComponent(id)}'))..headers.addAll(headers(s)));
        if (res.statusCode != 200) throw Exception("${s.owner}'s computer said ${res.statusCode}");
        await res.stream.pipe(part.openWrite());
        await part.rename(dest.path);
      } finally {
        client.close();
      }
      _saved[id] = dest.path;
      await _save();
      jobs[id] = 'done';
    } catch (e) {
      jobs[id] = '$e'.replaceFirst('Exception: ', '');
    }
    notifyListeners();
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
}
