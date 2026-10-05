import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'config.dart';
import 'paths.dart';
import 'phone_sync.dart';
import 'services.dart';
import 'settings.dart';
import 'soulseek.dart';
import 'store.dart';
import 'ui/bug_report.dart';
import 'ui/desktop.dart';
import 'ui/phone.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppPaths.init();
  await Settings.load();
  final store = LibraryStore();
  await store.load();

  // Unexpected errors go to a log file that bug reports can include.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _logError(details.exceptionAsString(), details.stack);
  };
  runZonedGuarded(() => runApp(WreckBoxApp(store: store)), (e, s) => _logError('$e', s));
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
                body: DesktopShell(store: widget.store, soulseek: soulseek, phoneServer: phoneServer, dropbox: dropbox, update: update),
              ),
      ),
    );
  }
}
