// WreckBox account: email + password or Google sign-in, library sync through the account, and finding your
// computers from anywhere (they register their tunnel address; see tunnel.dart). Phones reach a computer with a
// short-lived ticket the account service signs for it — never the computer's own secret.
//
// The password never leaves the device: it's turned into a key with PBKDF2-HMAC-SHA256 (200,000 rounds, salted
// with the email) and only that key is sent. The server stores a salted hash of the key.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'models.dart';
import 'settings.dart';
import 'store.dart';

class AccountException implements Exception {
  final String message;
  AccountException(this.message);
  @override
  String toString() => message;
}

class RemoteComputer {
  final String id, name, platform;
  final String? url;
  final DateTime lastSeen;
  RemoteComputer(this.id, this.name, this.platform, this.url, this.lastSeen);
  /// Computers check in every few minutes while sharing.
  bool get online => url != null && DateTime.now().difference(lastSeen) < const Duration(minutes: 12);
}

class Account {
  static String get api => AppConfig.accountApi;
  static bool get signedIn => Settings.current.accountToken != null;

  static String deviceId() {
    final s = Settings.current;
    if (s.deviceId == null) {
      final r = Random.secure();
      s.deviceId = List.generate(12, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      s.save();
    }
    return s.deviceId!;
  }

  // MARK: password → key

  /// PBKDF2-HMAC-SHA256, one 32-byte block (what the server expects), run off the UI thread.
  static Future<String> deriveKey(String email, String password, {int rounds = 200000}) {
    final salt = utf8.encode('wreckbox:${email.trim().toLowerCase()}');
    final pw = utf8.encode(password);
    return Isolate.run(() => _pbkdf2(pw, salt, rounds));
  }

  static String _pbkdf2(List<int> password, List<int> salt, int rounds) {
    final mac = Hmac(sha256, password);
    var u = Uint8List.fromList(mac.convert([...salt, 0, 0, 0, 1]).bytes);
    final out = Uint8List.fromList(u);
    for (var i = 1; i < rounds; i++) {
      u = Uint8List.fromList(mac.convert(u).bytes);
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // MARK: calls

  static Map<String, String> get _headers => {
        'content-type': 'application/json',
        'x-wreckbox-device': deviceId(),
        if (Settings.current.accountToken != null) 'authorization': 'Bearer ${Settings.current.accountToken}',
      };

  static Future<Map<String, dynamic>> _call(String method, String path, [Object? body]) async {
    final uri = Uri.parse('$api$path');
    http.Response r;
    try {
      final req = http.Request(method, uri)..headers.addAll(_headers);
      if (body != null) req.body = body is String ? body : jsonEncode(body);
      r = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 30)));
    } on SocketException {
      throw AccountException('No internet connection.');
    } on TimeoutException {
      throw AccountException('The account service is not responding — try again.');
    }
    final j = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body);
    if (r.statusCode == 401 && path != '/v1/login') {
      Settings.current.accountToken = null; // session ended (password changed elsewhere, or signed out)
      await Settings.current.save();
    }
    if (r.statusCode >= 400) throw AccountException(j is Map && j['error'] != null ? j['error'] : 'Account service error ${r.statusCode}');
    return j is Map<String, dynamic> ? j : {'value': j};
  }

  static Future<void> _signedIn(Map<String, dynamic> j) async {
    final s = Settings.current;
    s.accountToken = j['token'];
    s.accountEmail = j['user']?['email'];
    s.accountName = j['user']?['name'] ?? '';
    await s.save();
  }

  static Future<void> signUp(String email, String password, String name) async {
    if (password.length < 8) throw AccountException('Use at least 8 characters for the password.');
    final key = await deriveKey(email, password);
    await _signedIn(await _call('POST', '/v1/signup', {'email': email.trim(), 'key': key, 'name': name.trim()}));
  }

  static Future<void> signIn(String email, String password) async {
    final key = await deriveKey(email, password);
    await _signedIn(await _call('POST', '/v1/login', {'email': email.trim(), 'key': key}));
  }

  static Future<void> signOut() async {
    try {
      await _call('POST', '/v1/logout');
    } catch (_) {}
    final s = Settings.current;
    s.accountToken = null;
    await s.save();
  }

  static Future<void> changePassword(String oldPassword, String newPassword) async {
    if (newPassword.length < 8) throw AccountException('Use at least 8 characters for the password.');
    final email = Settings.current.accountEmail ?? '';
    await _call('POST', '/v1/password', {'oldKey': await deriveKey(email, oldPassword), 'newKey': await deriveKey(email, newPassword)});
  }

  // MARK: library sync

  /// What a phone needs about each track: whether the computer has it, and its analysis. No file paths.
  static Map<String, dynamic> crateSummary(LibraryStore store) {
    final out = <String, dynamic>{};
    for (final t in store.library?.tracks ?? const <LibraryTrack>[]) {
      final st = store.state.tracks[t.id];
      if (st == null) continue;
      final a = st.localPath == null ? null : store.analysis[st.localPath!];
      out[t.id] = {
        's': st.status.name,
        if (a?.bpm != null) 'bpm': a!.bpm,
        if (a?.camelot != null) 'camelot': a!.camelot,
        if (a?.key != null) 'key': a!.key,
        if (a?.energy != null) 'energy': a!.energy,
      };
    }
    return {'tracks': out, 'from': deviceId(), 'at': isoSeconds(DateTime.now())};
  }

  /// Computer: upload the library and the crate summary.
  static Future<void> uploadLibrary(LibraryStore store) async {
    if (!signedIn || store.library == null) return;
    await _call('PUT', '/v1/blob/library', jsonEncode(store.library!.toJson()));
    await _call('PUT', '/v1/blob/state', jsonEncode(crateSummary(store)));
  }

  static Timer? _debounce;

  /// Upload after changes settle (downloads arrive in bursts).
  static void scheduleUpload(LibraryStore store) {
    if (!signedIn) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(minutes: 2), () => uploadLibrary(store).catchError((_) {}));
  }

  /// Phone: the account's library + what the computer has. Returns false if nothing is saved yet.
  static Future<bool> downloadLibrary(LibraryStore store) async {
    Map<String, dynamic> lib;
    try {
      lib = await _call('GET', '/v1/blob/library');
    } on AccountException catch (e) {
      if (e.message.contains('nothing saved')) return false;
      rethrow;
    }
    await store.adoptLibraryJson(jsonEncode(lib));
    try {
      final summary = await _call('GET', '/v1/blob/state');
      store.remoteCrate = Map<String, dynamic>.from(summary['tracks'] ?? {});
      await store.saveRemoteCrate();
    } catch (_) {}
    store.changed();
    return true;
  }

  // MARK: computers

  static Future<List<RemoteComputer>> computers() async {
    final j = await _call('GET', '/v1/devices');
    final now = DateTime.fromMillisecondsSinceEpoch(j['now'] ?? DateTime.now().millisecondsSinceEpoch);
    final skew = DateTime.now().difference(now); // tolerate a wrong phone clock
    final all = [
      for (final d in (j['devices'] as List? ?? const []))
        if (d['platform'] != 'android' && d['platform'] != 'ios')
          RemoteComputer(d['id'], d['name'] ?? 'Computer', d['platform'] ?? '', d['url'],
              DateTime.fromMillisecondsSinceEpoch(d['lastSeen'] ?? 0).add(skew)),
    ];
    // An offline entry with the same name as an online one is an old registration of the same computer.
    final onlineNames = {for (final c in all) if (c.online) c.name};
    return all.where((c) => c.online || !onlineNames.contains(c.name)).toList();
  }

  /// Phone: a ticket to reach `computerId` for the next few hours: {url, ticket, expires}.
  static Future<Map<String, dynamic>> ticket(String computerId) =>
      _call('POST', '/v1/devices/${Uri.encodeComponent(computerId)}/ticket');

  /// Phone: ask an offline computer for a track; it picks the request up when it's back.
  static Future<void> queueRequest(String computerId, {String? id, String? artist, String? title}) =>
      _call('POST', '/v1/requests', {'device': computerId, 'id': id, 'artist': artist, 'title': title});

  /// Signs in with the one-time code from a signed-in computer's QR code (Sync to phone).
  static Future<void> claimLink(String code) async => _signedIn(await _call('POST', '/v1/link/claim', {'code': code}));

  // MARK: Google

  /// Google sign-in runs on the account service (no Google keys in the app). The app gets a one-time code back,
  /// which only works together with a secret that never left this device (PKCE).
  static Future<void> signInWithGoogle() async {
    final r = Random.secure();
    final verifier = base64Url.encode(List.generate(32, (_) => r.nextInt(256))).replaceAll('=', '');
    final challenge = base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
    final start = Uri.parse('$api/v1/auth/google/start').replace(queryParameters: {'redirect': 'wreckbox://auth', 'challenge': challenge});
    final Uri back;
    try {
      back = Uri.parse(await FlutterWebAuth2.authenticate(url: start.toString(), callbackUrlScheme: 'wreckbox'));
    } catch (_) {
      throw AccountException('Sign-in cancelled.');
    }
    final err = back.queryParameters['error'];
    if (err != null) throw AccountException(err == 'cancelled' || err == 'access_denied' ? 'Sign-in cancelled.' : 'Google sign-in failed ($err).');
    final code = back.queryParameters['code'];
    if (code == null) throw AccountException('Google sign-in failed.');
    await _signedIn(await _call('POST', '/v1/auth/exchange', {'code': code, 'verifier': verifier}));
  }

  /// Computer: announce (or refresh) this computer's tunnel address.
  static Future<void> registerComputer({required String name, required String platform, String? url, String? syncToken}) =>
      _call('POST', '/v1/devices', {'id': deviceId(), 'name': name, 'platform': platform, 'url': url, 'syncToken': syncToken});
}
