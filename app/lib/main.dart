import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'config.dart';
import 'paths.dart';
import 'phone_sync.dart';
import 'player.dart';
import 'account.dart';
import 'tunnel.dart';
import 'ui/account_ui.dart';
import 'services.dart';
import 'settings.dart';
import 'soulseek.dart';
import 'store.dart';
import 'ui/bug_report.dart';
import 'ui/desktop.dart';
import 'ui/phone.dart';
import 'ui/theme.dart';

void main() {
  // Everything runs inside the zone so unexpected errors anywhere go to the log that bug reports include.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _logError(details.exceptionAsString(), details.stack);
    };
    await AppPaths.init();
    await Settings.load();
    // just_audio has native backends on Android / Mac; Windows plays through media_kit.
    JustAudioMediaKit.ensureInitialized(windows: true, linux: true, android: false, iOS: false, macOS: false);
    final store = LibraryStore();
    await store.load();
    Player.instance = Player(store);
    runApp(WreckBoxApp(store: store));
  }, (e, s) => _logError('$e', s));
}

void _logError(String error, StackTrace? stack) {
  try {
    AppPaths.appLog.writeAsStringSync('${DateTime.now().toIso8601String()} $error\n${stack ?? ''}\n', mode: FileMode.append);
  } catch (_) {}
}

class WreckBoxApp extends StatefulWidget {
  final LibraryStore store;
  const WreckBoxApp({super.key, required this.store});
  @override
  State<WreckBoxApp> createState() => _WreckBoxAppState();
}

class _WreckBoxAppState extends State<WreckBoxApp> with WidgetsBindingObserver {
  late final soulseek = Soulseek(widget.store);
  late final phoneServer = PhoneSyncServer(widget.store);
  late final phoneClient = PhoneSyncClient(widget.store);
  late final organiser = DownloadsOrganiser(widget.store);
  late final dropbox = Dropbox(widget.store);
  late final tunnel = Tunnel(phoneServer);

  /// Phone: refresh playlists from the account, find the computer's current address, learn what it can stream.
  Future<void> _phoneStartup() async {
    if (Account.signedIn) {
      try {
        await Account.downloadLibrary(widget.store);
        await AccountConnect.reconnect();
      } catch (_) {}
    }
    if (Settings.current.pairedDesktop != null) await phoneClient.crate().catchError((_) => <Map<String, dynamic>>[]);
  }
  UpdateInfo? update;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (AppPaths.isDesktop) {
      soulseek.startWatching();
      soulseek.writeQueue();
    }
    Updates.check().then((u) => mounted ? setState(() => update = u) : null);
    if (Platform.isAndroid) _phoneStartup();
    if (AppPaths.isDesktop && Settings.current.shareRemotely && Account.signedIn) tunnel.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    // Quitting stops the Soulseek sidecar so it never keeps running orphaned.
    if (s == AppLifecycleState.detached) soulseek.dispose_();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    soulseek.dispose_();
    phoneServer.stop();
    tunnel.stop(keepWanted: Settings.current.shareRemotely);
    organiser.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: T.theme(),
      home: RepaintBoundary(
        key: screenshotKey,
        child: Platform.isAndroid || Platform.isIOS
            ? PhoneShell(store: widget.store, organiser: organiser, dropbox: dropbox, client: phoneClient, update: update)
            : Scaffold(
                backgroundColor: T.bg,
                body: DesktopShell(store: widget.store, soulseek: soulseek, phoneServer: phoneServer, dropbox: dropbox, tunnel: tunnel, update: update),
              ),
      ),
    );
  }
}
