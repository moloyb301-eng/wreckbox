// Per-user settings (settings.json in the app's own folder — never inside the shared library folder).

import 'dart:convert';

import 'paths.dart';

class Settings {
  String spotifyClientId = '';
  String? spotifyRefreshToken;
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

  static Settings current = Settings();

  static Future<void> load() async {
    try {
      final j = jsonDecode(await AppPaths.settingsFile.readAsString()) as Map<String, dynamic>;
      current = Settings()
        ..spotifyClientId = j['spotifyClientId'] ?? ''
        ..spotifyRefreshToken = j['spotifyRefreshToken']
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
        ..onboarded = j['onboarded'] ?? false;
    } catch (_) {
      current = Settings();
    }
  }

  Future<void> save() => writeAtomic(
        AppPaths.settingsFile,
        const JsonEncoder.withIndent('  ').convert({
          'spotifyClientId': spotifyClientId,
          'spotifyRefreshToken': spotifyRefreshToken,
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
        }),
      );
}
