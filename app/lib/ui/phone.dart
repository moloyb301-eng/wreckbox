// Phone layout (Android): Library · Organise · Computer · Settings.
// The phone app is a companion: analysis, Spotify sync, organising downloads for Rekordbox, cloud and
// computer → phone syncing. Soulseek and the heavy library tools stay on the computer.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../direct_link.dart';
import '../models.dart';
import '../paths.dart';
import '../phone_sync.dart';
import '../services.dart';
import '../settings.dart';
import '../store.dart';
import 'bug_report.dart';
import 'friends_page.dart';
import 'account_ui.dart';
import '../account.dart';
import 'player_bar.dart';
import 'playlists.dart';
import 'scan_cards.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'vpn_prompt.dart';
import 'tracks.dart';

class PhoneShell extends StatefulWidget {
  final LibraryStore store;
  final DownloadsOrganiser organiser;
  final Dropbox dropbox;
  final PhoneSyncClient client;
  final UpdateInfo? update;
  const PhoneShell({super.key, required this.store, required this.organiser, required this.dropbox, required this.client, this.update});
  @override
  State<PhoneShell> createState() => _PhoneShellState();
}

class _PhoneShellState extends State<PhoneShell> with WidgetsBindingObserver {
  int tab = 0;
  bool storageOk = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.client.addListener(_onClient);
    _checkStorage();
  }

  /// The computer asked to send its library: show the Computer page, which runs the copy.
  void _onClient() {
    if (widget.client.copyAllAsked && tab != 2 && mounted) setState(() => tab = 2);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClient);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from Android's settings (file access may have just been allowed there).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !storageOk) _checkStorage();
  }

  /// Organising files in Download/ and Music/ needs "All files access" on Android 11+.
  Future<void> _checkStorage() async {
    var ok = await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted;
    if (!mounted) return;
    setState(() => storageOk = ok);
    if (ok) {
      await AppPaths.init();
      await widget.store.load();
      widget.organiser.start();
    }
  }

  // Built inside the ListenableBuilder so every store change (e.g. a track filed in the background)
  // reaches the screen — building these once outside it left the library showing stale counts.
  Widget _page() => switch (tab) {
        0 => _library(),
        1 => _OrganisePage(store: widget.store, organiser: widget.organiser, dropbox: widget.dropbox),
        2 => _ComputerPage(store: widget.store, client: widget.client),
        3 => const FriendsPage(),
        _ => SettingsPage(store: widget.store, dropbox: widget.dropbox),
      };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => Scaffold(
        backgroundColor: T.bg,
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 4),
              child: Row(children: [
                const PixelRecordLogo(size: 30),
                const SizedBox(width: 10),
                Text('WRECKBOX', style: T.dot(16).copyWith(letterSpacing: 2)),
                const Spacer(),
                if (widget.store.busy != null) Flexible(child: Text(widget.store.busy!, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(11, FontWeight.w400, T.text2))),
                IconButton(tooltip: 'Report a bug', icon: const Icon(Icons.bug_report_outlined, color: T.peach), onPressed: () => openBugReport(context, widget.store, extraLog: widget.organiser.recent.take(20).toList())),
              ]),
            ),
            if (widget.update != null)
              ListTile(
                tileColor: T.lilac.withValues(alpha: 0.15),
                title: Text('WreckBox ${widget.update!.version} is available', style: T.ui(13, FontWeight.w600)),
                trailing: const Icon(Icons.download),
                onTap: () => launchUrl(Uri.parse(widget.update!.url), mode: LaunchMode.externalApplication),
              ),
            if (!storageOk)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Glass(
                  smart: true,
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Allow file access', style: T.ui(16, FontWeight.w600)),
                    const SizedBox(height: 6),
                    Text('WreckBox files tracks from Download/ into Music/WreckBox so Rekordbox and other players can find them. Android needs "All files access" for that.',
                        style: T.ui(13, FontWeight.w400, T.text2)),
                    const SizedBox(height: 10),
                    PillButton(label: 'Allow', style: PillStyle.primary, onTap: () async {
                      await Permission.manageExternalStorage.request();
                      await _checkStorage();
                    }),
                  ]),
                ),
              ),
            Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _page())),
          ]),
        ),
        bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
          PlayerBar(store: widget.store, compact: true),
          NavigationBar(
          backgroundColor: T.bgRaised,
          indicatorColor: T.lilac.withValues(alpha: 0.25),
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.queue_music), label: 'Library'),
            NavigationDestination(icon: Icon(Icons.auto_fix_high), label: 'Organise'),
            NavigationDestination(icon: Icon(Icons.computer), label: 'Computer'),
            NavigationDestination(icon: Icon(Icons.people_outline), label: 'Friends'),
            NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
          ],
        ),
        ]),
      ),
    );
  }

  Widget _library() {
    final store = widget.store;
    if (store.library == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No library yet. Import your playlists (CSV) in Settings, or pair with your computer to use its library.',
              textAlign: TextAlign.center, style: T.ui(14, FontWeight.w400, T.text2)),
        ),
      );
    }
    return DefaultTabController(
      length: 4,
      child: Column(children: [
        TabBar(
          labelStyle: T.ui(13, FontWeight.w600),
          indicatorColor: T.lilac,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: 'Playlists ${store.library!.playlists.length}'),
            Tab(text: 'On phone ${store.count(TrackStatus.downloaded)}'),
            Tab(text: 'Missing ${store.count(TrackStatus.missing)}'),
            const Tab(text: 'All'),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: TabBarView(children: [
            PlaylistsView(store: store),
            TrackListView(store: store, filter: ListFilter.downloaded, compact: true),
            TrackListView(store: store, filter: ListFilter.missing, compact: true),
            TrackListView(store: store, compact: true),
          ]),
        ),
      ]),
    );
  }
}

class _OrganisePage extends StatefulWidget {
  final LibraryStore store;
  final DownloadsOrganiser organiser;
  final Dropbox dropbox;
  const _OrganisePage({required this.store, required this.organiser, required this.dropbox});
  @override
  State<_OrganisePage> createState() => _OrganisePageState();
}

class _OrganisePageState extends State<_OrganisePage> {
  String status = '';

  @override
  Widget build(BuildContext context) {
    final s = Settings.current;
    return ListView(children: [
      const SizedBox(height: 8),
      if (Platform.isAndroid) ...[ScanCards(store: widget.store), const SizedBox(height: 12)],
      Glass(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const DotLabel('Downloads folder', color: T.text),
          const SizedBox(height: 8),
          Text('New tracks in Download/ that are in your Spotify library are analysed (BPM, key, energy), tagged with the Spotify title, artists, album and cover, renamed "Artist - Title" and moved to Music/WreckBox/Tracks — ready for Rekordbox.',
              style: T.ui(13, FontWeight.w400, T.text2)),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: s.organiseDownloads,
            activeThumbColor: T.lilac,
            title: Text('Organise automatically', style: T.ui(14, FontWeight.w600)),
            onChanged: (v) async {
              s.organiseDownloads = v;
              await s.save();
              setState(() {});
            },
          ),
          Wrap(spacing: 8, runSpacing: 8, children: [
            PillButton(label: 'Organise now', icon: Icons.auto_fix_high, style: PillStyle.smart, onTap: () async {
              setState(() => status = 'Checking Download/…');
              final n = await widget.organiser.runOnce();
              setState(() => status = n == 0 ? 'Nothing new to file.' : 'Filed $n tracks.');
            }),
            PillButton(label: 'Rescan library', icon: Icons.graphic_eq, onTap: widget.store.busy != null ? null : () => widget.store.rescan()),
            PillButton(label: 'Write tags to all', icon: Icons.sell_outlined, onTap: widget.store.busy != null ? null : () => widget.store.writeTags()),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      Glass(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const DotLabel('Dropbox', color: T.text),
          const SizedBox(height: 8),
          Text(widget.dropbox.connected ? 'Pull new tracks from ${s.dropboxFolder}.' : 'Connect Dropbox in Settings to pull tracks from a Dropbox folder.',
              style: T.ui(13, FontWeight.w400, T.text2)),
          const SizedBox(height: 8),
          if (widget.dropbox.connected)
            PillButton(label: 'Pull from Dropbox', icon: Icons.cloud_download_outlined, onTap: () async {
              try {
                final n = await widget.dropbox.pull((l) => setState(() => status = l));
                setState(() => status = 'Dropbox: filed $n tracks.');
              } catch (e) {
                setState(() => status = '$e');
              }
            }),
        ]),
      ),
      const SizedBox(height: 12),
      if (status.isNotEmpty) Text(status, style: T.ui(13, FontWeight.w600, T.text2)),
      const SizedBox(height: 8),
      const DotLabel('Recent'),
      for (final l in widget.organiser.recent.take(30)) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text(l, style: T.ui(12, FontWeight.w400, T.text2))),
    ]);
  }
}

class _ComputerPage extends StatefulWidget {
  final LibraryStore store;
  final PhoneSyncClient client;
  const _ComputerPage({required this.store, required this.client});
  @override
  State<_ComputerPage> createState() => _ComputerPageState();
}

class _ComputerPageState extends State<_ComputerPage> {
  List<Map<String, dynamic>>? get crate => widget.client.crateById?.values.toList();
  String status = '';
  final reqArtist = TextEditingController(), reqTitle = TextEditingController();
  final picked = <String>{}; // playlist names
  bool scanning = false, working = false;
  // "Get everything": progress of the big copy.
  bool copying = false;
  String copyLine = '', copyVia = '';
  int copyDone = 0, copyTotal = 0, copyBytes = 0;
  final copyClock = Stopwatch();
  Timer? copyTick;

  static String gb(num bytes) => bytes >= 1e9 ? '${(bytes / 1e9).toStringAsFixed(1)} GB' : '${(bytes / 1e6).round()} MB';

  /// Tracks on the computer that this phone doesn't have yet.
  List<Map<String, dynamic>> _missing() {
    final have = {for (final e in widget.store.state.tracks.entries) if (e.value.status == TrackStatus.downloaded) e.key};
    return [for (final i in crate ?? const <Map<String, dynamic>>[]) if (!have.contains(i['id']) && widget.store.track(i['id'] as String) != null) i];
  }

  /// The computer's "Send library to phone" button: start the big copy here.
  void _onClient() {
    final c = widget.client;
    if (!c.copyAllAsked || !mounted) return;
    if (copying || working || crate == null) return; // already copying, or picked up once the crate is in
    c.copyAllAsked = false;
    final items = _missing();
    if (items.isEmpty) {
      setState(() => status = 'Your computer asked to send everything — this phone already has it all.');
      return;
    }
    _getEverything(items, direct: c.copyAllDirect);
  }

  @override
  void dispose() {
    widget.client.removeListener(_onClient);
    super.dispose();
  }

  /// Copies every track the computer has and this phone doesn't — over the shared Wi-Fi, or a direct link
  /// (`direct`: always the direct link).
  Future<void> _getEverything(List<Map<String, dynamic>> items, {bool direct = false}) async {
    final c = widget.client;
    setState(() {
      copying = true;
      copyDone = 0;
      copyTotal = items.length;
      copyBytes = Settings.current.downloadQuality == 'flac' ? items.fold<int>(0, (a, i) => a + ((i['size'] as num?)?.toInt() ?? 0)) : 0;
      copyVia = '';
    });
    c.stopLive();
    try {
      final via = await DirectLink.open(c, (s) => setState(() => copyLine = s), direct: direct);
      copyVia = via == 'direct' ? 'direct Wi-Fi link' : 'Wi-Fi';
      await DirectLink.keepAwake(true);
      copyClock
        ..reset()
        ..start();
      copyTick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      final n = await c.download(items, (d, t, name) {
        copyDone = d;
        copyLine = name;
      }, parallel: 3);
      if (mounted) {
        setState(() => status = c.cancelDownload
            ? 'Stopped after $n tracks.'
            : 'Copied $n of ${items.length} tracks over the $copyVia in ${(copyClock.elapsed.inSeconds / 60).toStringAsFixed(1)} min.'
                '${n < items.length && c.lastError != null ? ' Last problem: ${c.lastError}' : ''}');
      }
    } catch (e) {
      if (mounted) setState(() => status = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      copyTick?.cancel();
      copyClock.stop();
      await DirectLink.keepAwake(false);
      await DirectLink.close(c);
      if (mounted) setState(() => copying = false);
      if (Account.signedIn && Settings.current.connectedComputerId != null) {
        try {
          await AccountConnect.reconnect(); // the computer's tunnel address may have changed while it was offline
        } catch (_) {}
      }
      c.startLive();
    }
  }

  Widget _everythingCard(Map<String, Map<String, dynamic>> available, Set<String> have) {
    final missing = [for (final e in available.entries) if (!have.contains(e.key) && widget.store.track(e.key) != null) e.value];
    final size = missing.fold<int>(0, (a, i) => a + ((i['size'] as num?)?.toInt() ?? 0));
    final secs = copyClock.elapsedMilliseconds / 1000;
    final speed = secs > 2 ? widget.client.bytesDone / secs : 0.0;
    final flac = Settings.current.downloadQuality == 'flac';
    final left = flac && speed > 0 ? (copyBytes - widget.client.bytesDone) / speed : (copyDone > 0 ? secs / copyDone * (copyTotal - copyDone) : 0);
    return Glass(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const DotLabel('Everything on your computer', color: T.text),
        const SizedBox(height: 6),
        Text('${available.length} tracks there · ${missing.length} not on this phone yet${flac ? ' (${gb(size)})' : ''}',
            style: T.ui(13, FontWeight.w600, T.text2)),
        const SizedBox(height: 4),
        Text('On the same Wi-Fi it copies over that. Otherwise — or with Direct Wi-Fi link — the phone makes a direct Wi-Fi '
            'link and your computer joins it; its internet pauses until the copy is done. You can also start it from the '
            'computer: Sync to phone → Send library to phone.', style: T.ui(12, FontWeight.w400, T.text3)),
        const SizedBox(height: 10),
        if (copying) ...[
          LinearProgressIndicator(
            value: copyTotal == 0 ? null : (flac && copyBytes > 0 ? widget.client.bytesDone / copyBytes : copyDone / copyTotal).clamp(0.0, 1.0),
            color: T.lilac,
            backgroundColor: T.text3.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 8),
          Text(copyClock.isRunning
              ? '$copyDone / $copyTotal · ${gb(widget.client.bytesDone)}${flac ? ' of ${gb(copyBytes)}' : ''} · ${(speed / 1e6).toStringAsFixed(1)} MB/s'
                  '${left > 0 ? ' · ~${(left / 60).ceil()} min left' : ''} · $copyVia'
              : '', style: T.ui(12.5, FontWeight.w600)),
          Text(copyLine, maxLines: 2, overflow: TextOverflow.ellipsis, style: T.ui(12, FontWeight.w400, T.text2)),
          const SizedBox(height: 8),
          PillButton(label: 'Stop', icon: Icons.stop, onTap: () => widget.client.cancelDownload = true),
        ] else
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            PillButton(
              label: 'Get all ${missing.length} tracks',
              icon: Icons.download_for_offline,
              style: PillStyle.smart,
              onTap: missing.isEmpty || working ? null : () => _getEverything(missing),
            ),
            if (Platform.isAndroid)
              PillButton(
                label: 'Direct Wi-Fi link',
                icon: Icons.wifi_tethering,
                onTap: missing.isEmpty || working ? null : () => _getEverything(missing, direct: true),
              ),
            _qualityPicker(),
          ]),
      ]),
    );
  }

  Future<void> _load() async {
    setState(() => status = 'Connecting…');
    try {
      final info = await widget.client.info();
      if (widget.store.library == null) await widget.client.adoptLibrary();
      final c = await widget.client.crate();
      final where = (Settings.current.pairedDesktop ?? '').startsWith('https://') ? 'from anywhere' : 'on Wi-Fi';
      setState(() => status = 'Connected to ${info['name']} $where — ${c.length} tracks available');
      widget.client.startLive();
      _onClient();
    } catch (e) {
      setState(() => status = "Can't reach the computer. Same Wi-Fi? Is \"Sync to phone\" sharing on? ($e)");
    }
  }

  List<RemoteComputer>? computers;

  @override
  void initState() {
    super.initState();
    widget.client.addListener(_onClient);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onClient()); // asked before this page was open
    if (Account.signedIn) {
      _findComputers();
    } else if (Settings.current.pairedDesktop != null) {
      _load();
    }
  }

  /// Signed in: list the account's computers and connect to the remembered one (its address may have changed).
  Future<void> _findComputers() async {
    setState(() => status = 'Looking for your computers…');
    try {
      final list = await Account.computers();
      setState(() => computers = list);
      final c = await AccountConnect.reconnect();
      if (c != null) {
        await _load();
      } else {
        setState(() => status = list.isEmpty
            ? 'No computer in your account yet. On your computer: Sync to phone → sign in → Use from anywhere.'
            : 'Your computers are offline. Open WreckBox on your computer with "Use from anywhere" on.');
      }
    } catch (e) {
      setState(() => status = '$e');
    }
  }

  /// Fallback when the camera can't read the QR code: paste the link shown under it on the computer.
  Future<void> _enterLink() async {
    final c = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.bgRaised,
        title: Text('Pairing link', style: T.ui(18, FontWeight.w600)),
        content: TextField(controller: c, autofocus: true, style: T.ui(13), decoration: const InputDecoration(hintText: 'wreckbox://pair?…')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Pair')),
        ],
      ),
    );
    if (raw == null || raw.isEmpty) return;
    final info = PhoneSyncClient.parsePairing(raw);
    if (info == null) {
      setState(() => status = "That doesn't look like a WreckBox pairing link.");
      return;
    }
    setState(() => status = info['link'] != null ? 'Signing in…' : 'Pairing…');
    final problem = await PhoneLink.handle(info, widget.store);
    if (problem != null) {
      setState(() => status = problem);
    } else {
      setState(() {});
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (scanning) {
      return Column(children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: MobileScanner(onDetect: (capture) async {
              final raw = capture.barcodes.firstOrNull?.rawValue;
              final info = raw == null ? null : PhoneSyncClient.parsePairing(raw);
              if (info == null) return;
              setState(() {
                scanning = false;
                status = info['link'] != null ? 'Signing in…' : 'Pairing…';
              });
              final problem = await PhoneLink.handle(info, widget.store);
              if (problem != null) {
                setState(() => status = problem);
              } else {
                if (Account.signedIn) await _findComputers();
                await _load();
              }
            }),
          ),
        ),
        TextButton(onPressed: () => setState(() => scanning = false), child: const Text('Cancel')),
      ]);
    }
    return ListenableBuilder(listenable: widget.client, builder: (context, _) => _content());
  }

  Future<void> _requestSong() async {
    final artist = reqArtist.text.trim(), title = reqTitle.text.trim();
    if (artist.isEmpty || title.isEmpty) return;
    try {
      if (!await confirmVpn(context)) return;
      final st = await widget.client.request(artist: artist, title: title);
      reqArtist.clear();
      reqTitle.clear();
      setState(() => status = st == 'queued'
          ? 'Your computer is offline — it will look for "$title" when it\'s back.'
          : 'Your computer is looking for "$title" on Soulseek. It lands on this phone when it\'s found.');
    } catch (e) {
      setState(() => status = "Couldn't send the request: $e");
    }
  }

  Widget _qualityPicker() {
    final s = Settings.current;
    return DropdownButton<String>(
      value: s.downloadQuality,
      dropdownColor: T.bgRaised,
      style: T.ui(13, FontWeight.w600),
      underline: const SizedBox(),
      items: [for (final e in PhoneSyncClient.qualities.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
      onChanged: (v) async {
        if (v == null) return;
        s.downloadQuality = v;
        await s.save();
        setState(() {});
      },
    );
  }

  Widget _content() {
    final lib = widget.store.library;
    final have = {for (final e in widget.store.state.tracks.entries) if (e.value.status == TrackStatus.downloaded) e.key};
    final available = {for (final c in crate ?? const <Map<String, dynamic>>[]) c['id'] as String: c};
    final toGet = [
      for (final pl in lib?.playlists ?? const <LibraryPlaylist>[])
        if (picked.contains(pl.name))
          for (final id in pl.trackIDs)
            if (available.containsKey(id) && !have.contains(id)) available[id]!,
    ];
    final unique = {for (final c in toGet) c['id']: c}.values.toList();
    return ListView(children: [
      const SizedBox(height: 8),
      if (Account.signedIn) ...[
        Glass(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const DotLabel('Your computers (from anywhere)', color: T.text),
              const Spacer(),
              IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh, size: 18), onPressed: _findComputers),
            ]),
            if (computers == null) Text('Loading…', style: T.ui(12.5, FontWeight.w400, T.text2)),
            for (final c in computers ?? const <RemoteComputer>[])
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.computer, color: c.online ? T.lilac : T.text3),
                title: Text(c.name, style: T.ui(14, FontWeight.w600)),
                subtitle: Text(c.online ? (Settings.current.connectedComputerId == c.id ? 'Connected' : 'Online') : 'Offline', style: T.ui(12, FontWeight.w400, T.text3)),
                trailing: c.online && Settings.current.connectedComputerId != c.id
                    ? TextButton(onPressed: () async {
                        await AccountConnect.use(c);
                        await _load();
                      }, child: const Text('Connect'))
                    : null,
              ),
          ]),
        ),
        const SizedBox(height: 12),
      ],
      Glass(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const DotLabel('Your computer', color: T.text),
          const SizedBox(height: 8),
          Text(status.isEmpty ? 'On your computer open WreckBox → Sync to phone → Start sharing, then scan the code.' : status, style: T.ui(13, FontWeight.w400, T.text2)),
          if (widget.client.crateById != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.circle, size: 8, color: widget.client.live ? T.lilac : T.text3),
              const SizedBox(width: 6),
              Text(widget.client.live ? 'Live — new tracks show up instantly' : 'Reconnecting…', style: T.ui(12, FontWeight.w600, T.text3)),
            ]),
          ],
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            PillButton(label: Settings.current.pairedDesktop == null ? 'Scan pairing code' : 'Pair again', icon: Icons.qr_code_scanner, style: PillStyle.primary, onTap: () => setState(() => scanning = true)),
            PillButton(label: 'Enter pairing link', icon: Icons.link, onTap: _enterLink),
            if (Settings.current.pairedDesktop != null) PillButton(label: 'Refresh', icon: Icons.refresh, onTap: _load),
          ]),
        ]),
      ),
      if (crate != null) ...[
        const SizedBox(height: 12),
        _everythingCard(available, have),
        const SizedBox(height: 12),
        Glass(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const DotLabel('Request a song', color: T.text),
            const SizedBox(height: 6),
            Text('Your computer looks for it on Soulseek right away; it comes to this phone when it\'s found.', style: T.ui(12.5, FontWeight.w400, T.text2)),
            const SizedBox(height: 8),
            TextField(controller: reqArtist, style: T.ui(14), decoration: const InputDecoration(hintText: 'Artist')),
            TextField(controller: reqTitle, style: T.ui(14), decoration: const InputDecoration(hintText: 'Title'), onSubmitted: (_) => _requestSong()),
            const SizedBox(height: 8),
            PillButton(label: 'Request', icon: Icons.travel_explore, style: PillStyle.smart, onTap: _requestSong),
            for (final r in widget.client.requests.entries)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Expanded(child: Text(widget.store.describe(r.key), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(12.5, FontWeight.w600))),
                  RequestChip(status: r.value),
                ]),
              ),
          ]),
        ),
      ],
      if (crate != null && lib != null) ...[
        const SizedBox(height: 12),
        const DotLabel('Pick playlists to bring to the phone'),
        Row(children: [
          Text('Quality', style: T.ui(13, FontWeight.w400, T.text2)),
          const SizedBox(width: 10),
          _qualityPicker(),
        ]),
        const SizedBox(height: 4),
        // The button sits above the list so it's reachable without scrolling past every playlist.
        PillButton(
          label: working ? 'Downloading…' : 'Download ${unique.length} tracks',
          icon: Icons.download,
          style: PillStyle.smart,
          onTap: working || copying || unique.isEmpty
              ? null
              : () async {
                  setState(() => working = true);
                  final n = await widget.client.download(unique, (d, t, name) => setState(() => status = 'Copying ${d + 1}/$t: $name'));
                  setState(() {
                    working = false;
                    status = 'Copied $n tracks to ${Platform.isAndroid ? 'Music/WreckBox/Tracks' : 'Tracks'}.';
                  });
                },
        ),
        const SizedBox(height: 8),
        // Playlists with tracks waiting on the computer first.
        for (final pl in [...lib.playlists]..sort((a, b) => b.trackIDs.where(available.containsKey).length.compareTo(a.trackIDs.where(available.containsKey).length)))
          CheckboxListTile(
            value: picked.contains(pl.name),
            activeColor: T.lilac,
            onChanged: (v) => setState(() => v == true ? picked.add(pl.name) : picked.remove(pl.name)),
            title: Text(pl.name, style: T.ui(14, FontWeight.w600)),
            subtitle: Text('${pl.trackIDs.where(available.containsKey).length} on the computer · ${pl.trackIDs.where(have.contains).length} already here',
                style: T.ui(12, FontWeight.w400, T.text3)),
            // Auto-sync: new tracks of this playlist come over by themselves as soon as the computer has them.
            secondary: IconButton(
              tooltip: 'Keep in sync automatically',
              icon: Icon(Icons.sync, color: Settings.current.autoSyncPlaylists.contains(pl.name) ? T.lilac : T.text3),
              onPressed: () async {
                final s = Settings.current;
                s.autoSyncPlaylists.contains(pl.name) ? s.autoSyncPlaylists.remove(pl.name) : s.autoSyncPlaylists.add(pl.name);
                await s.save();
                setState(() {});
                if (s.autoSyncPlaylists.contains(pl.name)) {
                  final todo = widget.client.autoSyncMissing();
                  if (todo.isNotEmpty) {
                    setState(() => status = 'Syncing ${todo.length} tracks from ${pl.name}…');
                    final n = await widget.client.download(todo, (d, t, name) => setState(() => status = 'Copying ${d + 1}/$t: $name'));
                    setState(() => status = 'Copied $n tracks. New ones from ${pl.name} will come over automatically.');
                  }
                }
              },
            ),
          ),
      ],
    ]);
  }
}

/// Where a request from this phone stands.
class RequestChip extends StatelessWidget {
  final String status;
  const RequestChip({super.key, required this.status});
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'ready' => ('On its way', T.lilac),
      'not_found' => ('Not found', T.peach),
      'failed' => ('Failed', T.peach),
      'queued' => ('Waiting for computer', T.text3),
      _ => ('Searching…', T.text2),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: 0.6))),
      child: Text(label, style: T.ui(11.5, FontWeight.w600, color)),
    );
  }
}
