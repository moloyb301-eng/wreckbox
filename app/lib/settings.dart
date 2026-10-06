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
  String qualityWifi = 'flac', qualityMobile = 'med', downloadQuality = 'flac';
  List<String> autoSyncPlaylists = []; // phone: bring new tracks of these playlists over automatically

  static Settings current = Settings();

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
        ..qualityMobile = j['qualityMobile'] ?? 'med'
        ..downloadQuality = j['downloadQuality'] ?? 'flac'
        ..autoSyncPlaylists = List<String>.from(j['autoSyncPlaylists'] ?? const []);
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
          'downloadQuality': downloadQuality,
          'autoSyncPlaylists': autoSyncPlaylists,
        }),
      );
}
