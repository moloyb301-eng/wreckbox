// Big copies from the computer (e.g. the whole library): over the Wi-Fi both are on, or — when they aren't on the
// same Wi-Fi — over a direct link. Computers can't do Wi-Fi Direct themselves, so the phone hosts a Wi-Fi Direct
// group (a network named DIRECT-WB-WreckBox, 5 GHz when it can) and tells the computer, through its tunnel, to
// join it. While the computer is on the phone's link it has no internet; it goes back to its usual Wi-Fi when the
// copy is done (or after a few idle minutes by itself).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';

import 'config.dart';
import 'phone_sync.dart';
import 'settings.dart';

class DirectLink {
  static const _ch = MethodChannel('wreckbox/direct');

  /// Wi-Fi Direct group owners are 192.168.49.1 and hand out the rest of 192.168.49.x.
  static const _subnet = '192.168.49.';
  static Map<String, dynamic>? group; // {ssid, pass, freq} while the phone hosts one

  /// Gets a connection fit for a big copy. Returns 'wifi' (same network) or 'direct'; `say` reports progress.
  /// `direct`: skip the shared Wi-Fi and always make the direct link (faster than most home routers).
  /// Throws with a message for the user when neither works.
  static Future<String> open(PhoneSyncClient c, void Function(String) say, {bool direct = false}) async {
    say('Checking the connection…');
    if (!direct && await _onLan(c.base)) return 'wifi';
    if (!direct && Settings.current.remoteDesktop != null) {
      await PhoneSyncClient.preferLan(); // home Wi-Fi address, if this phone can reach it
      if (await _onLan(c.base)) return 'wifi';
    }
    if (!Platform.isAndroid) throw Exception('Connect this device to the same Wi-Fi as the computer.');

    if (!await Permission.nearbyWifiDevices.request().isGranted && !await Permission.locationWhenInUse.request().isGranted) {
      throw Exception('WreckBox needs "Nearby devices" to make a direct Wi-Fi link.');
    }
    if (await _ch.invokeMethod<bool>('wifiOn') != true) {
      await _ch.invokeMethod('openWifi');
      throw Exception('Turn Wi-Fi on (it doesn\'t need to join a network), then tap again.');
    }
    say('Starting the direct link…');
    final g = Map<String, dynamic>.from(await _ch.invokeMethod('start') as Map);
    group = g;
    final band = (g['freq'] as int? ?? 0) > 4000 ? '5 GHz' : '2.4 GHz';

    // Ask the computer to join through the connection we already have (its tunnel when on mobile data).
    var asked = false;
    final control = Settings.current.remoteDesktop ?? Settings.current.pairedDesktop;
    if (control != null) {
      say('Asking your computer to join the direct link ($band)…');
      try {
        final r = await http
            .post(
              Uri.parse('$control/direct/join'),
              headers: {...PhoneSyncClient.authHeaders(), 'content-type': 'application/json'},
              body: jsonEncode({'ssid': g['ssid'], 'pass': g['pass']}),
            )
            .timeout(const Duration(seconds: 15));
        asked = r.statusCode == 200;
      } catch (_) {}
    }
    say(
      asked
          ? 'Your computer is joining the phone\'s Wi-Fi ($band)…'
          : 'On your computer, join the Wi-Fi network "${g['ssid']}" — password ${g['pass']}',
    );
    final found = await _find(asked ? const Duration(seconds: 90) : const Duration(minutes: 5));
    if (found == null) {
      await close(c);
      throw Exception(
        asked
            ? 'Your computer didn\'t show up on the direct link. Is its WreckBox up to date?'
            : 'Your computer didn\'t join "${g['ssid']}".',
      );
    }
    c.directBase = found;
    return 'direct';
  }

  /// Done: send the computer back to its usual Wi-Fi and take the link down.
  static Future<void> close(PhoneSyncClient c) async {
    final d = c.directBase;
    c.directBase = null;
    if (d != null) {
      try {
        await http.post(Uri.parse('$d/direct/leave'), headers: PhoneSyncClient.authHeaders()).timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    if (group != null) {
      group = null;
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        await _ch.invokeMethod('stop');
      } catch (_) {}
    }
  }

  /// Keeps the screen on while copying (a sleeping phone stalls the copy).
  static Future<void> keepAwake(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('keepAwake', on);
    } catch (_) {}
  }

  /// A plain-http (local) address that answers.
  static Future<bool> _onLan(String? base) async {
    if (base == null || !base.startsWith('http://')) return false;
    try {
      final r = await http.get(Uri.parse('$base/info'), headers: PhoneSyncClient.authHeaders()).timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Looks for the computer on the phone's link until it answers or `timeout` runs out.
  static Future<String?> _find(Duration timeout) async {
    final until = DateTime.now().add(timeout);
    const port = AppConfig.phoneSyncPort;
    while (DateTime.now().isBefore(until)) {
      final open = <String>[];
      await Future.wait([
        for (var i = 2; i < 255; i++)
          Socket.connect('$_subnet$i', port, timeout: const Duration(milliseconds: 900)).then((s) {
            s.destroy();
            open.add('$_subnet$i');
          }, onError: (_) {}),
      ]);
      for (final ip in open) {
        final base = 'http://$ip:$port';
        if (await _onLan(base)) return base;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    return null;
  }
}
