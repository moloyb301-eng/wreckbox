// Per-user settings (settings.json in the app's own folder — never inside the shared library folder).

import 'dart:convert';

import 'paths.dart';

class Settings {
  String spotifyClientId = '';
  String? spotifyRefreshToken;
  String googleClientId = '';
  String googleClientSecret = '';
  String? googleRefreshToken;
  String dropboxAppKey = '';
  String? dropboxRefreshToken;
  String dropboxFolder = '/Music';
  String reporterName = '';
  String reporterContact = '';
  List<String> extraScanFolders = [];
  bool organiseDownloads = true; // phone: watch Downloads and file new tracks automatically
  String? pairedDesktop; // phone: "http://ip:port" of the paired computer
  String? pairToken;
  String? desktopPairToken; // desktop: token phones must present
  bool onboarded = false;
  String? accountToken, accountEmail, deviceId, connectedComputerId;
  String accountName = '';
  bool shareRemotely = false; // desktop: keep the tunnel up so phones can reach this computer anywhere
  // Phone, connected through the account: the computer's tunnel address, and when pairToken (a ticket) runs out.
  String? remoteDesktop;
  int ticketExpires = 0; // ms since epoch; 0 = a pairing token from the QR code, which doesn't expire
  // Phone: quality to stream / download at — flac (the original), high, med, low.
  // Best quality by default (the user's rule); mobile data gets High (256k AAC) rather than the original FLAC.
  String qualityWifi = 'flac', qualityMobile = 'high', downloadQuality = 'flac';
  List<String> autoSyncPlaylists = []; // phone: bring new tracks of these playlists over automatically
  // Phone EQ (10 bands, like the computer's; mapped onto the phone's own bands) and the full-screen player's look.
  bool eqOn = true;
  String eqPreset = 'Flat', visualMode = 'matrix';
  List<double> eqGains = List.filled(10, 0);
  // Phone: the last queue and where it was, so play after a restart (or from the widget) resumes it.
  List<String> lastQueue = [];
  int lastIndex = -1, lastPositionMs = 0;

  static Settings current = Settings();

  /// A saved EQ curve, or flat if it's missing or not 10 bands.
  static List<double> _tenBands(dynamic v) {
    final l = (v is List) ? v.whereType<num>().map((e) => e.toDouble()).toList() : <double>[];
    return l.length == 10 ? l : List.filled(10, 0);
  }

  static Future<void> load() async {
    try {
      final j = jsonDecode(await AppPaths.settingsFile.readAsString()) as Map<String, dynamic>;
      current = Settings()
        ..spotifyClientId = j['spotifyClientId'] ?? ''
        ..spotifyRefreshToken = j['spotifyRefreshToken']
        ..googleClientId = j['googleClientId'] ?? ''
        ..googleClientSecret = j['googleClientSecret'] ?? ''
        ..googleRefreshToken = j['googleRefreshToken']
        ..dropboxAppKey = j['dropboxAppKey'] ?? ''
        ..dropboxRefreshToken = j['dropboxRefreshToken']
        ..dropboxFolder = j['dropboxFolder'] ?? '/Music'
        ..reporterName = j['reporterName'] ?? ''
        ..reporterContact = j['reporterContact'] ?? ''
        ..extraScanFolders = List<String>.from(j['extraScanFolders'] ?? const [])
        ..organiseDownloads = j['organiseDownloads'] ?? true
        ..pairedDesktop = j['pairedDesktop']
        ..pairToken = j['pairToken']
        ..desktopPairToken = j['desktopPairToken']
        ..onboarded = j['onboarded'] ?? false
        ..accountToken = j['accountToken']
        ..accountEmail = j['accountEmail']
        ..accountName = j['accountName'] ?? ''
        ..deviceId = j['deviceId']
        ..connectedComputerId = j['connectedComputerId']
        ..shareRemotely = j['shareRemotely'] ?? false
        ..remoteDesktop = j['remoteDesktop']
        ..ticketExpires = j['ticketExpires'] ?? 0
        ..qualityWifi = j['qualityWifi'] ?? 'flac'
        // Settings saved before 0.4 still hold the old default (Medium) without the user having picked it.
        ..qualityMobile = j['qualityV'] == null && (j['qualityMobile'] ?? 'med') == 'med' ? 'high' : j['qualityMobile'] ?? 'high'
        ..downloadQuality = j['downloadQuality'] ?? 'flac'
        ..autoSyncPlaylists = List<String>.from(j['autoSyncPlaylists'] ?? const [])
        ..eqOn = j['eqOn'] ?? true
        ..eqPreset = j['eqPreset'] ?? 'Flat'
        ..visualMode = j['visualMode'] ?? 'matrix'
        ..eqGains = _tenBands(j['eqGains'])
        ..lastQueue = List<String>.from(j['lastQueue'] ?? const [])
        ..lastIndex = j['lastIndex'] ?? -1
        ..lastPositionMs = j['lastPositionMs'] ?? 0;
    } catch (_) {
      current = Settings();
    }
  }

  Future<void> save() => writeAtomic(
        AppPaths.settingsFile,
        const JsonEncoder.withIndent('  ').convert({
          'spotifyClientId': spotifyClientId,
          'spotifyRefreshToken': spotifyRefreshToken,
          'googleClientId': googleClientId,
          'googleClientSecret': googleClientSecret,
          'googleRefreshToken': googleRefreshToken,
          'dropboxAppKey': dropboxAppKey,
          'dropboxRefreshToken': dropboxRefreshToken,
          'dropboxFolder': dropboxFolder,
          'reporterName': reporterName,
          'reporterContact': reporterContact,
          'extraScanFolders': extraScanFolders,
          'organiseDownloads': organiseDownloads,
          'pairedDesktop': pairedDesktop,
          'pairToken': pairToken,
          'desktopPairToken': desktopPairToken,
          'onboarded': onboarded,
          'accountToken': accountToken,
          'accountEmail': accountEmail,
          'accountName': accountName,
          'deviceId': deviceId,
          'connectedComputerId': connectedComputerId,
          'shareRemotely': shareRemotely,
          'remoteDesktop': remoteDesktop,
          'ticketExpires': ticketExpires,
          'qualityWifi': qualityWifi,
          'qualityMobile': qualityMobile,
          'qualityV': 2,
          'downloadQuality': downloadQuality,
          'autoSyncPlaylists': autoSyncPlaylists,
          'eqOn': eqOn,
          'eqPreset': eqPreset,
          'visualMode': visualMode,
          'eqGains': eqGains,
          'lastQueue': lastQueue,
          'lastIndex': lastIndex,
          'lastPositionMs': lastPositionMs,
        }),
      );
}
