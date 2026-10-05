// Desktop layout (Windows, later Mac): sidebar | page | inspector.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import '../phone_sync.dart';
import '../services.dart';
import '../soulseek.dart';
import '../store.dart';
import 'bug_report.dart';
import 'player_bar.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'tracks.dart';

class DesktopShell extends StatefulWidget {
  final LibraryStore store;
  final Soulseek soulseek;
  final PhoneSyncServer phoneServer;
  final Dropbox dropbox;
  final UpdateInfo? update;
  const DesktopShell({super.key, required this.store, required this.soulseek, required this.phoneServer, required this.dropbox, this.update});
  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  String page = 'home';
  String? playlist;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return ListenableBuilder(
      listenable: Listenable.merge([store, widget.soulseek]),
      builder: (context, _) => LayoutBuilder(builder: (context, c) {
        final overlay = c.maxWidth < 1320;
        final showInspector = store.focus != null && !{'settings', 'soulseek', 'phone', 'queue'}.contains(page);
        return Stack(children: [
          const Positioned.fill(child: _Ambient()),
          Row(children: [
            SizedBox(width: 252, child: _sidebar()),
            Expanded(
              child: Column(children: [
                Expanded(child: Padding(padding: const EdgeInsets.fromLTRB(22, 0, 22, 10), child: _page())),
                Padding(padding: const EdgeInsets.only(left: 22), child: PlayerBar(store: store)),
              ]),
            ),
            if (showInspector && !overlay) SizedBox(width: 340, child: Inspector(store: store)),
          ]),
          if (showInspector && overlay) Positioned(right: 0, top: 0, bottom: 0, width: 340, child: Inspector(store: store, floating: true)),
          if (widget.update != null)
            Positioned(
              left: 274,
              bottom: 16,
              child: Glass(
                smart: true,
                radius: 99,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Text('WreckBox ${widget.update!.version} is available', style: T.ui(13, FontWeight.w600)),
                  const SizedBox(width: 10),
                  PillButton(label: 'Download', style: PillStyle.primary, onTap: () => launchUrl(Uri.parse(widget.update!.url), mode: LaunchMode.externalApplication)),
                ]),
              ),
            ),
        ]);
      }),
    );
  }

  Widget _sidebar() {
    final store = widget.store;
    Widget item(String id, String title, IconData icon, {int? count, String? pl, bool live = false}) {
      final selected = page == id && playlist == pl;
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() {
          page = id;
          playlist = pl;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: selected ? Colors.white.withValues(alpha: 0.10) : null),
          child: Row(children: [
            Icon(icon, size: 16, color: selected ? T.text : T.text3),
            const SizedBox(width: 10),
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(13.5, selected ? FontWeight.w600 : FontWeight.w500, selected ? T.text : T.text2))),
            if (live) Container(width: 7, height: 7, decoration: const BoxDecoration(gradient: T.smart, shape: BoxShape.circle)),
            if (count != null) Text('$count', style: T.dot(11, T.text3)),
          ]),
        ),
      );
    }

    Widget section(String s) => Padding(padding: const EdgeInsets.fromLTRB(12, 18, 12, 6), child: DotLabel(s));
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 0, 10),
      child: Glass(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 14),
            child: Row(children: [const PixelRecordLogo(size: 34), const SizedBox(width: 10), Text('WRECKBOX', style: T.dot(17).copyWith(letterSpacing: 2))]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 8), children: [
              item('home', 'Home', Icons.grid_view_rounded),
              section('Library'),
              item('all', 'All tracks', Icons.queue_music, count: store.library?.tracks.length),
              item('downloaded', 'In my crate', Icons.check_circle_outline, count: store.count(TrackStatus.downloaded)),
              item('missing', 'Missing', Icons.radio_button_unchecked, count: store.count(TrackStatus.missing)),
              item('ignored', 'Ignored', Icons.block, count: store.count(TrackStatus.ignored)),
              section('Playlists'),
              for (final p in store.library?.playlists ?? const <LibraryPlaylist>[])
                item('playlist', p.name, p.collaborative ? Icons.people_outline : Icons.music_note, count: p.trackIDs.length, pl: p.name),
              section('Tools'),
              item('queue', 'Download queue', Icons.format_list_numbered, count: store.state.downloadPriority.isEmpty ? null : store.state.downloadPriority.length),
              item('soulseek', 'Soulseek sync', Icons.download_for_offline_outlined, live: widget.soulseek.running,
                  count: widget.soulseek.notFound + widget.soulseek.failed == 0 ? null : widget.soulseek.notFound + widget.soulseek.failed),
              item('phone', 'Sync to phone', Icons.smartphone, live: widget.phoneServer.running),
              item('settings', 'Settings', Icons.settings_outlined),
              const SizedBox(height: 10),
              InkWell(
                onTap: () => openBugReport(context, store, extraLog: widget.soulseek.recent.take(20).toList()),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(children: [const Icon(Icons.bug_report_outlined, size: 16, color: T.peach), const SizedBox(width: 10), Text('Report a bug', style: T.ui(13.5, FontWeight.w500, T.peach))]),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget header(String eyebrow, String title, String subtitle, [List<Widget> actions = const []]) => Padding(
        padding: const EdgeInsets.only(top: 34, bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DotLabel(eyebrow),
              const SizedBox(height: 6),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(34, FontWeight.w500)),
              if (subtitle.isNotEmpty) Text(subtitle, style: T.ui(13, FontWeight.w400, T.text2)),
            ]),
          ),
          ...actions,
        ]),
      );

  List<Widget> libraryActions() {
    final store = widget.store;
    return [
      if (store.busy != null)
        Padding(padding: const EdgeInsets.only(right: 10), child: Text(store.busy!, style: T.ui(12, FontWeight.w400, T.text2))),
      PillButton(label: 'Rescan & analyse', icon: Icons.graphic_eq, onTap: store.busy != null ? null : () => store.rescan()),
    ];
  }

  Widget _page() {
    final store = widget.store;
    if (store.library == null && page != 'settings') {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const PixelRecordLogo(size: 96),
          const SizedBox(height: 18),
          Text('Welcome to WreckBox', style: T.ui(28, FontWeight.w500)),
          const SizedBox(height: 8),
          Text('Start by importing your Spotify and YouTube playlists (CSV files).', style: T.ui(14, FontWeight.w400, T.text2)),
          const SizedBox(height: 18),
          PillButton(label: 'Set up', icon: Icons.arrow_forward, style: PillStyle.primary, onTap: () => setState(() => page = 'settings')),
        ]),
      );
    }
    switch (page) {
      case 'settings':
        return SettingsPage(store: store, soulseek: widget.soulseek, dropbox: widget.dropbox);
      case 'soulseek':
        return _SoulseekPage(soulseek: widget.soulseek, store: store, header: header);
      case 'phone':
        return _PhonePage(server: widget.phoneServer, header: header);
      case 'queue':
        return _QueuePage(store: store, soulseek: widget.soulseek, header: header);
      case 'home':
        return _home();
      default:
        final filter = switch (page) {
          'downloaded' => ListFilter.downloaded,
          'missing' => ListFilter.missing,
          'ignored' => ListFilter.ignored,
          _ => ListFilter.all,
        };
        final title = playlist ?? switch (page) { 'downloaded' => 'In my crate', 'missing' => 'Missing', 'ignored' => 'Ignored', _ => 'All tracks' };
        final rows = store.rows(filter: filter, playlist: playlist);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          header(playlist != null ? 'Playlist' : 'Library', title, '${rows.length} tracks · ${rows.where((r) => r.status == TrackStatus.downloaded).length} in your crate', [
            if (page == 'downloaded')
              Padding(padding: const EdgeInsets.only(right: 8), child: PillButton(label: 'Write tags to files', icon: Icons.sell_outlined, style: PillStyle.smart, onTap: store.busy != null ? null : () => store.writeTags())),
            ...libraryActions(),
          ]),
          Expanded(child: TrackListView(key: ValueKey('$page/$playlist'), store: store, filter: filter, playlist: playlist)),
        ]);
    }
  }

  Widget _home() {
    final store = widget.store;
    final total = store.library?.tracks.length ?? 0, have = store.count(TrackStatus.downloaded);
    Widget stat(String label, String value, String detail, [double? progress]) => Expanded(
          child: Glass(
            radius: 20,
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DotLabel(label),
              const SizedBox(height: 10),
              Text(value, style: T.dot(34)),
              if (progress != null) ...[
                const SizedBox(height: 8),
                ClipRRect(borderRadius: BorderRadius.circular(99), child: LinearProgressIndicator(value: progress, minHeight: 4, color: T.lilac, backgroundColor: T.hairline)),
              ],
              const SizedBox(height: 6),
              Text(detail, style: T.ui(12, FontWeight.w400, T.text2)),
            ]),
          ),
        );
    final recent = [...?store.library?.tracks]..sort((a, b) => (b.firstAdded ?? '').compareTo(a.firstAdded ?? ''));
    return ListView(children: [
      header('Home', 'Your crate', '$total tracks from ${store.library?.playlists.length ?? 0} Spotify playlists', libraryActions()),
      IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        stat('Tracks', '$total', 'across all playlists'),
        const SizedBox(width: 12),
        stat('In crate', '$have', total > 0 ? '${(have * 100 / total).round()}% of your library' : '', total > 0 ? have / total : 0),
        const SizedBox(width: 12),
        stat('Missing', '${store.count(TrackStatus.missing)}', '${store.count(TrackStatus.ignored)} ignored'),
        const SizedBox(width: 12),
        stat('Analysed', '${store.analysis.length}', 'BPM · key · energy'),
      ])),
      const SizedBox(height: 22),
      const DotLabel('Recently added', color: T.text2, size: 12),
      const SizedBox(height: 12),
      SizedBox(
        height: 214,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final t in recent.take(16))
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: InkWell(
                onTap: () => store.setFocus(t.id),
                child: Glass(
                  radius: 20,
                  padding: const EdgeInsets.all(10),
                  child: SizedBox(
                    width: 140,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Artwork(track: t, store: store, size: 140, radius: 16),
                      const SizedBox(height: 8),
                      Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(13, FontWeight.w600)),
                      Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(11.5, FontWeight.w400, T.text2)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 22),
      const DotLabel('Playlists', color: T.text2, size: 12),
      const SizedBox(height: 12),
      Wrap(spacing: 14, runSpacing: 14, children: [
        for (final p in store.library?.playlists ?? const <LibraryPlaylist>[])
          InkWell(
            onTap: () => setState(() {
              page = 'playlist';
              playlist = p.name;
            }),
            child: Glass(
              radius: 20,
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: 172,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(14, FontWeight.w600)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text(p.trackIDs.length == 1 ? '1 track' : '${p.trackIDs.length} tracks', style: T.ui(11.5, FontWeight.w400, T.text2)),
                    const Spacer(),
                    Text('${store.downloadedIn(p)}/${p.trackIDs.length}', style: T.dot(11, T.text3)),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(value: p.trackIDs.isEmpty ? 0 : store.downloadedIn(p) / p.trackIDs.length, minHeight: 3, color: T.lilac, backgroundColor: T.hairline),
                  ),
                ]),
              ),
            ),
          ),
      ]),
      const SizedBox(height: 30),
    ]);
  }
}

class _Ambient extends StatelessWidget {
  const _Ambient();
  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          color: T.bg,
          gradient: RadialGradient(center: Alignment(0.9, -0.9), radius: 1.3, colors: [Color(0x29BB96DA), Color(0x00000000)]),
        ),
      );
}

class _SoulseekPage extends StatefulWidget {
  final Soulseek soulseek;
  final LibraryStore store;
  final Widget Function(String, String, String, [List<Widget>]) header;
  const _SoulseekPage({required this.soulseek, required this.store, required this.header});
  @override
  State<_SoulseekPage> createState() => _SoulseekPageState();
}

class _SoulseekPageState extends State<_SoulseekPage> {
  String tab = 'not_found';
  String? message;

  @override
  Widget build(BuildContext context) {
    final s = widget.soulseek;
    final entries = s.records.entries.where((e) => e.value.status == tab).toList()..sort((a, b) => b.value.lastTry.compareTo(a.value.lastTry));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      widget.header('Tools', 'Soulseek sync', s.running ? 'Running — checks your playlists again every 30 minutes' : 'Stopped', [
        PillButton(
          label: s.running ? 'Stop' : 'Start sync',
          icon: s.running ? Icons.stop : Icons.play_arrow,
          style: s.running ? PillStyle.glass : PillStyle.smart,
          onTap: () async {
            String? err;
            if (s.running) {
              await s.stop();
            } else {
              err = await s.start();
            }
            setState(() => message = err);
          },
        ),
      ]),
      if (!Soulseek.available || !s.configured || message != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(message ?? (!Soulseek.available ? 'The Soulseek component is missing from this install.' : 'Add your Soulseek login in Settings to start.'),
              style: T.ui(13, FontWeight.w600, T.peach)),
        ),
      Row(children: [
        for (final (id, label, n) in [('done', 'Downloaded', s.done), ('not_found', 'Not found', s.notFound), ('failed', 'Failed', s.failed)])
          Padding(padding: const EdgeInsets.only(right: 8), child: ChipButton(label: label, count: n, selected: tab == id, onTap: () => setState(() => tab = id))),
        const Spacer(),
        if (tab != 'done' && entries.isNotEmpty)
          PillButton(label: 'Retry all ${entries.length}', icon: Icons.refresh, style: PillStyle.smart, onTap: () => s.retry([for (final e in entries) e.key])),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            flex: 3,
            child: Glass(
              child: ListView(padding: const EdgeInsets.all(8), children: [
                if (entries.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text('Nothing here.', style: T.ui(13, FontWeight.w400, T.text3))),
                for (final e in entries)
                  if (widget.store.track(e.key) case final t?)
                    ListTile(
                      leading: Artwork(track: t, store: widget.store, size: 40),
                      title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(13.5, FontWeight.w600)),
                      subtitle: Text(
                        [t.artist, e.value.reason ?? '', e.value.format?.toUpperCase() ?? '', '${e.value.attempts} tr${e.value.attempts == 1 ? 'y' : 'ies'}', if (s.retryPending(e.key)) 'retry queued']
                            .where((x) => x.isNotEmpty).join(' · '),
                        maxLines: 2,
                        style: T.ui(11.5, FontWeight.w400, T.text3),
                      ),
                      trailing: tab == 'done'
                          ? null
                          : Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(tooltip: 'Retry', icon: const Icon(Icons.refresh, size: 18), onPressed: () => s.retry([e.key])),
                              IconButton(tooltip: 'Retry with your own search words', icon: const Icon(Icons.manage_search, size: 18), onPressed: () => _custom(e.key, t.artist, t.title)),
                              IconButton(tooltip: 'Ignore', icon: const Icon(Icons.block, size: 18), onPressed: () => widget.store.setStatus([e.key], TrackStatus.ignored)),
                            ]),
                      onTap: () => widget.store.setFocus(e.key),
                    ),
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Glass(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const DotLabel('Log'),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView(children: [
                    for (final l in s.recent)
                      Text(l, style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: l.contains('✓') ? T.lilac : l.contains('✗') ? T.peach : T.text2)),
                  ]),
                ),
              ]),
            ),
          ),
        ]),
      ),
    ]);
  }

  Future<void> _custom(String id, String artist, String title) async {
    final c = TextEditingController(text: '${artist.split(',').first} $title');
    final q = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.bgRaised,
        title: Text('Custom search', style: T.ui(18, FontWeight.w600)),
        content: TextField(controller: c, autofocus: true, style: T.ui(14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Search on next pass')),
        ],
      ),
    );
    if (q != null && q.trim().isNotEmpty) await widget.soulseek.retry([id], query: q);
  }
}

class _PhonePage extends StatefulWidget {
  final PhoneSyncServer server;
  final Widget Function(String, String, String, [List<Widget>]) header;
  const _PhonePage({required this.server, required this.header});
  @override
  State<_PhonePage> createState() => _PhonePageState();
}

class _PhonePageState extends State<_PhonePage> {
  String? uri;

  Future<void> _refresh() async {
    final u = await widget.server.pairingUri();
    setState(() => uri = u);
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.server.running;
    return ListView(children: [
      widget.header('Tools', 'Sync to phone', 'Send tracks from this computer to the WreckBox phone app over your Wi-Fi', [
        PillButton(
          label: on ? 'Stop sharing' : 'Start sharing',
          icon: on ? Icons.stop : Icons.wifi_tethering,
          style: on ? PillStyle.glass : PillStyle.smart,
          onTap: () async {
            on ? await widget.server.stop() : await widget.server.start();
            setState(() {});
          },
        ),
      ]),
      Glass(
        padding: const EdgeInsets.all(22),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (uri != null && on)
            Container(color: Colors.white, padding: const EdgeInsets.all(10), child: QrImageView(data: uri!, size: 200))
          else
            Container(width: 220, height: 220, alignment: Alignment.center, child: Text('Start sharing to show the pairing code', textAlign: TextAlign.center, style: T.ui(13, FontWeight.w400, T.text3))),
          const SizedBox(width: 24),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('On your phone', style: T.ui(18, FontWeight.w600)),
              const SizedBox(height: 10),
              for (final (n, s) in [
                (1, 'Connect the phone to the same Wi-Fi as this computer.'),
                (2, 'Open WreckBox → Computer → Scan pairing code.'),
                (3, 'Pick playlists and tap Download. Tracks arrive tagged and analysed.'),
              ])
                Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [Text('$n', style: T.dot(15, T.lilac)), const SizedBox(width: 10), Expanded(child: Text(s, style: T.ui(13, FontWeight.w400, T.text2)))])),
              const SizedBox(height: 10),
              if (uri != null && on) ...[
                Text('Camera won\'t read it? On the phone tap "Enter pairing link" and paste:', style: T.ui(12, FontWeight.w400, T.text2)),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: SelectableText(uri!, style: T.ui(11.5, FontWeight.w400, T.text3))),
                  IconButton(tooltip: 'Copy', icon: const Icon(Icons.copy, size: 16), onPressed: () => Clipboard.setData(ClipboardData(text: uri!))),
                ]),
                const SizedBox(height: 10),
              ],
              Text('Only phones that scanned this code can connect. Windows may ask to allow WreckBox on private networks — allow it.', style: T.ui(12, FontWeight.w400, T.text3)),
              const SizedBox(height: 12),
              PillButton(label: 'Unpair all phones', icon: Icons.link_off, onTap: () async {
                await widget.server.resetToken();
                await _refresh();
              }),
            ]),
          ),
        ]),
      ),
    ]);
  }
}

/// Download queue: playlists in priority order decide which missing tracks Soulseek fetches first
/// (same queue.json format as the Mac app).
class _QueuePage extends StatefulWidget {
  final LibraryStore store;
  final Soulseek soulseek;
  final Widget Function(String, String, String, [List<Widget>]) header;
  const _QueuePage({required this.store, required this.soulseek, required this.header});
  @override
  State<_QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<_QueuePage> {
  List<String> get prios => widget.store.state.downloadPriority;

  Future<void> _set(List<String> p, {bool? only}) async {
    widget.store.state.downloadPriority = p;
    if (only != null) widget.store.state.priorityOnly = only;
    widget.store.log('queue', p.isEmpty ? 'priorities cleared' : 'priorities: ${p.map((k) => k.substring(k.indexOf(':') + 1)).join(' → ')}');
    await widget.store.save();
    await widget.soulseek.writeQueue();
    widget.store.changed();
  }

  @override
  Widget build(BuildContext context) {
    final lib = widget.store.library;
    final missing = {for (final t in lib?.tracks ?? const <LibraryTrack>[]) if ((widget.store.state.tracks[t.id]?.status ?? TrackStatus.missing) == TrackStatus.missing) t.id};
    int missingIn(String name) => lib?.playlists.where((x) => x.name == name).firstOrNull?.trackIDs.where(missing.contains).toSet().length ?? 0;
    final available = [for (final pl in lib?.playlists ?? const <LibraryPlaylist>[]) if (!prios.contains('playlist:${pl.name}')) pl.name];
    return ListView(children: [
      widget.header('Tools', 'Download queue', 'Soulseek downloads missing tracks in this order'),
      Glass(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const DotLabel('Priority', color: T.text),
          const SizedBox(height: 10),
          if (prios.isEmpty) Text('Add playlists below. Their missing tracks go to the front of the queue, top to bottom.', style: T.ui(13, FontWeight.w400, T.text2)),
          for (var i = 0; i < prios.length; i++)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: T.glassFill, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                SizedBox(width: 26, child: Text('${i + 1}', style: T.dot(16, T.lilac))),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(prios[i].substring(prios[i].indexOf(':') + 1), style: T.ui(13.5, FontWeight.w600)),
                    Text('${missingIn(prios[i].substring(prios[i].indexOf(':') + 1))} missing', style: T.ui(11, FontWeight.w400, T.text3)),
                  ]),
                ),
                IconButton(icon: const Icon(Icons.arrow_upward, size: 16), onPressed: i == 0 ? null : () => _set([...prios]..insert(i - 1, prios[i])..removeAt(i + 1))),
                IconButton(icon: const Icon(Icons.arrow_downward, size: 16), onPressed: i == prios.length - 1 ? null : () => _set([...prios]..insert(i + 2, prios[i])..removeAt(i))),
                IconButton(icon: const Icon(Icons.close, size: 16), onPressed: () => _set([...prios]..removeAt(i))),
              ]),
            ),
          const SizedBox(height: 8),
          PopupMenuButton<String>(
            color: T.bgRaised,
            onSelected: (name) => _set([...prios, 'playlist:$name']),
            itemBuilder: (_) => [for (final n in available) PopupMenuItem(value: n, child: Text(n))],
            child: const IgnorePointer(child: PillButton(label: 'Add playlist', icon: Icons.add, onTap: _noop)),
          ),
          const Divider(height: 28, color: T.hairline),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: !widget.store.state.priorityOnly,
            activeThumbColor: T.lilac,
            title: Text('Then everything else', style: T.ui(13.5, FontWeight.w600)),
            subtitle: Text('Off: download only your priorities', style: T.ui(11.5, FontWeight.w400, T.text3)),
            onChanged: (v) => _set(prios, only: !v),
          ),
        ]),
      ),
    ]);
  }
}

void _noop() {}
