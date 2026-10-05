// Phone layout (Android): Library · Organise · Computer · Settings.
// The phone app is a companion: analysis, Spotify sync, organising downloads for Rekordbox, cloud and
// computer → phone syncing. Soulseek and the heavy library tools stay on the computer.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../paths.dart';
import '../phone_sync.dart';
import '../services.dart';
import '../settings.dart';
import '../store.dart';
import 'bug_report.dart';
import 'account_ui.dart';
import '../account.dart';
import 'player_bar.dart';
import 'settings_page.dart';
import 'theme.dart';
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

class _PhoneShellState extends State<PhoneShell> {
  int tab = 0;
  bool storageOk = false;

  @override
  void initState() {
    super.initState();
    _checkStorage();
  }

  /// Organising files in Download/ and Music/ needs "All files access" on Android 11+.
  Future<void> _checkStorage() async {
    var ok = await Permission.manageExternalStorage.isGranted || await Permission.storage.isGranted;
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
      length: 3,
      child: Column(children: [
        TabBar(
          labelStyle: T.ui(13, FontWeight.w600),
          indicatorColor: T.lilac,
          tabs: [
            Tab(text: 'On phone ${store.count(TrackStatus.downloaded)}'),
            Tab(text: 'Missing ${store.count(TrackStatus.missing)}'),
            const Tab(text: 'All'),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: TabBarView(children: [
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
  List<Map<String, dynamic>>? crate;
  String status = '';
  final picked = <String>{}; // playlist names
  bool scanning = false, working = false;

  Future<void> _load() async {
    setState(() => status = 'Connecting…');
    try {
      final info = await widget.client.info();
      if (widget.store.library == null) await widget.client.adoptLibrary();
      final c = await widget.client.crate();
      setState(() {
        crate = c;
        status = 'Connected to ${info['name']} — ${c.length} tracks available';
      });
    } catch (e) {
      setState(() => status = "Can't reach the computer. Same Wi-Fi? Is \"Sync to phone\" sharing on? ($e)");
    }
  }

  List<RemoteComputer>? computers;

  @override
  void initState() {
    super.initState();
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
    setState(() => status = 'Pairing…');
    final base = await PhoneSyncClient.pair(info);
    if (base == null) {
      setState(() => status = "Couldn't reach the computer — same Wi-Fi? Is sharing on?");
    } else {
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
              setState(() => scanning = false);
              final base = await PhoneSyncClient.pair(info);
              if (base == null) {
                setState(() => status = "Found the code but couldn't reach the computer — check you're on the same Wi-Fi.");
              } else {
                await _load();
              }
            }),
          ),
        ),
        TextButton(onPressed: () => setState(() => scanning = false), child: const Text('Cancel')),
      ]);
    }
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
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            PillButton(label: Settings.current.pairedDesktop == null ? 'Scan pairing code' : 'Pair again', icon: Icons.qr_code_scanner, style: PillStyle.primary, onTap: () => setState(() => scanning = true)),
            PillButton(label: 'Enter pairing link', icon: Icons.link, onTap: _enterLink),
            if (Settings.current.pairedDesktop != null) PillButton(label: 'Refresh', icon: Icons.refresh, onTap: _load),
          ]),
        ]),
      ),
      if (crate != null && lib != null) ...[
        const SizedBox(height: 12),
        const DotLabel('Pick playlists to bring to the phone'),
        const SizedBox(height: 8),
        // The button sits above the list so it's reachable without scrolling past every playlist.
        PillButton(
          label: working ? 'Downloading…' : 'Download ${unique.length} tracks',
          icon: Icons.download,
          style: PillStyle.smart,
          onTap: working || unique.isEmpty
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
          ),
      ],
    ]);
  }
}
