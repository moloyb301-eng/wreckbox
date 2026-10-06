// Settings and first-run setup: Spotify client id (with a step-by-step guide), Soulseek login (desktop),
// Dropbox, reporter details for bug reports, updates.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:file_picker/file_picker.dart';

import '../config.dart';
import '../csv_import.dart';
import '../engine.dart';
import '../paths.dart';
import '../services.dart';
import '../phone_sync.dart';
import '../settings.dart';
import '../soulseek.dart';
import '../spotify.dart';
import '../store.dart';
import '../youtube.dart';
import 'account_ui.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  final LibraryStore store;
  final Soulseek? soulseek;
  final Dropbox dropbox;
  const SettingsPage({super.key, required this.store, this.soulseek, required this.dropbox});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final s = Settings.current;
  late final clientId = TextEditingController(text: s.spotifyClientId);
  late final dropboxKey = TextEditingController(text: s.dropboxAppKey);
  late final googleId = TextEditingController(text: s.googleClientId);
  late final googleSecret = TextEditingController(text: s.googleClientSecret);
  late final dropboxFolder = TextEditingController(text: s.dropboxFolder);
  late final name = TextEditingController(text: s.reporterName);
  late final contact = TextEditingController(text: s.reporterContact);
  final slskUser = TextEditingController(), slskPass = TextEditingController();
  String status = '';
  bool importing = false;
  String version = '', engine = '';
  String? updateStatus;
  bool checking = false;

  @override
  void initState() {
    super.initState();
    Updates.currentVersion().then((v) => setState(() => version = v));
    Engine.version().then((v) => setState(() => engine = v));
  }

  Future<void> _saveAll() async {
    s
      ..spotifyClientId = clientId.text.trim()
      ..dropboxAppKey = dropboxKey.text.trim()
      ..googleClientId = googleId.text.trim()
      ..googleClientSecret = googleSecret.text.trim()
      ..dropboxFolder = dropboxFolder.text.trim().isEmpty ? '/Music' : dropboxFolder.text.trim()
      ..reporterName = name.text.trim()
      ..reporterContact = contact.text.trim();
    await s.save();
  }

  Future<void> _importSpotify() async {
    await _saveAll();
    setState(() {
      importing = true;
      status = 'Opening Spotify sign-in…';
    });
    try {
      await SpotifyImport.run((line) => setState(() => status = line));
      await widget.store.load();
      s.onboarded = true;
      await s.save();
    } catch (e) {
      setState(() => status = '$e');
    } finally {
      setState(() => importing = false);
    }
  }

  Widget field(String label, TextEditingController c, {String hint = '', bool obscure = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(
          controller: c,
          obscureText: obscure,
          style: T.ui(14),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            labelStyle: T.ui(13, FontWeight.w400, T.text2),
            hintStyle: T.ui(13, FontWeight.w400, T.text3),
            filled: true,
            fillColor: T.glassFill,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: T.hairline)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: T.hairline)),
          ),
        ),
      );

  Widget _qualityRow(String label, String value, void Function(String) set) => Row(children: [
        Expanded(child: Text(label, style: T.ui(13.5, FontWeight.w600))),
        DropdownButton<String>(
          value: value,
          dropdownColor: T.bgRaised,
          style: T.ui(13, FontWeight.w600),
          underline: const SizedBox(),
          items: [for (final e in PhoneSyncClient.qualities.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) async {
            if (v == null) return;
            set(v);
            await Settings.current.save();
            setState(() {});
          },
        ),
      ]);

  Widget section(String title, List<Widget> children, {bool smart = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Glass(
          smart: smart,
          radius: 20,
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [DotLabel(title, color: T.text), const SizedBox(height: 12), ...children]),
        ),
      );

  Widget step(int n, String text, {String? copy}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(n > 0 ? '$n' : '·', style: T.dot(15, T.lilac)),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: T.ui(13, FontWeight.w400, T.text2))),
          if (copy != null)
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: copy));
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Copied $copy')));
              },
              child: Text('Copy', style: T.ui(12, FontWeight.w600, T.lilac)),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final desktop = AppPaths.isDesktop;
    return ListView(padding: const EdgeInsets.fromLTRB(22, 34, 22, 30), children: [
      const DotLabel('Settings'),
      const SizedBox(height: 6),
      Text('Setup', style: T.ui(32, FontWeight.w500)),
      const SizedBox(height: 18),
      AccountSection(store: widget.store, onChanged: () => setState(() {})),
      const SizedBox(height: 16),
      if (!desktop)
        section('Streaming quality', [
          Text('Tracks you play from your computer, and tracks you bring over. Lower quality starts faster and uses less data; FLAC is the original file.',
              style: T.ui(13, FontWeight.w400, T.text2)),
          const SizedBox(height: 8),
          _qualityRow('On Wi-Fi', s.qualityWifi, (v) => s.qualityWifi = v),
          _qualityRow('On mobile data', s.qualityMobile, (v) => s.qualityMobile = v),
          _qualityRow('Downloads to phone', s.downloadQuality, (v) => s.downloadQuality = v),
        ]),
      section('Import playlists', smart: widget.store.library == null, [
        Text('Bring in your Spotify and YouTube playlists as CSV files — no accounts or developer keys needed. Re-import any time; a playlist with the same name is replaced.',
            style: T.ui(13, FontWeight.w400, T.text2)),
        const SizedBox(height: 12),
        step(1, 'Spotify: open exportify.net, log in with Spotify, click "Export All" (or export single playlists). You get one CSV per playlist.'),
        step(2, 'YouTube / YouTube Music: takeout.google.com → deselect all → tick "YouTube and YouTube Music" → choose only "playlists" → export. Or use tunemymusic.com → your service → "Export to file" (CSV).'),
        step(3, 'Click Choose CSV files and select them all at once.'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          PillButton(label: 'Open Exportify', icon: Icons.open_in_new, onTap: () => launchUrl(Uri.parse('https://exportify.net'), mode: LaunchMode.externalApplication)),
          PillButton(label: 'Open Google Takeout', icon: Icons.open_in_new, onTap: () => launchUrl(Uri.parse('https://takeout.google.com'), mode: LaunchMode.externalApplication)),
          PillButton(label: 'Open TuneMyMusic', icon: Icons.open_in_new, onTap: () => launchUrl(Uri.parse('https://www.tunemymusic.com'), mode: LaunchMode.externalApplication)),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          PillButton(
            label: importing ? 'Importing…' : 'Choose CSV files',
            icon: Icons.upload_file,
            style: PillStyle.primary,
            onTap: importing
                ? null
                : () async {
                    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv']);
                    final paths = [for (final f in files) if (f.path != null) f.path!];
                    if (paths.isEmpty) return;
                    setState(() => importing = true);
                    try {
                      await CsvImport.run(paths, (line) => setState(() => status = line));
                      await widget.store.load();
                      s.onboarded = true;
                      await s.save();
                    } catch (e) {
                      setState(() => status = 'Import failed: $e');
                    } finally {
                      setState(() => importing = false);
                    }
                  },
          ),
          if (status.isNotEmpty) Text(status, style: T.ui(12.5, FontWeight.w400, T.text2)),
        ]),
        const SizedBox(height: 6),
        Text('Each song is looked up in free music catalogues (MusicBrainz, Deezer) for its ISRC and cover. The first import of a big library takes a while — about one song per second.',
            style: T.ui(11.5, FontWeight.w400, T.text3)),
      ]),
      section('Spotify — direct (optional, needs Spotify Premium)', [
        Text('Advanced: import straight from your Spotify account instead of CSV. Spotify requires the key\'s owner to have Premium; one key can be shared with up to 5 people (add their Spotify emails under the app\'s "User Management").',
            style: T.ui(12.5, FontWeight.w400, T.text3)),
        const SizedBox(height: 10),
        Text('Spotify only lets each developer app have a few users, so everyone uses their own free key. It takes about two minutes:',
            style: T.ui(13, FontWeight.w400, T.text2)),
        const SizedBox(height: 12),
        step(1, 'Open the Spotify developer dashboard and log in with your Spotify account.'),
        step(2, 'Create an app (any name, e.g. "My WreckBox"). Tick "Web API".'),
        step(3, 'Add both of these as Redirect URIs, then save:', copy: null),
        step(0, AppConfig.spotifyDesktopRedirect, copy: AppConfig.spotifyDesktopRedirect),
        step(0, AppConfig.spotifyMobileRedirect, copy: AppConfig.spotifyMobileRedirect),
        step(4, 'Copy the app\'s Client ID and paste it here.'),
        const SizedBox(height: 6),
        PillButton(label: 'Open Spotify dashboard', icon: Icons.open_in_new, onTap: () => launchUrl(Uri.parse('https://developer.spotify.com/dashboard'), mode: LaunchMode.externalApplication)),
        const SizedBox(height: 12),
        field('Spotify Client ID', clientId, hint: '32 characters'),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          PillButton(label: importing ? 'Importing…' : 'Import my playlists', icon: Icons.download, style: PillStyle.primary, onTap: importing ? null : _importSpotify),
          if (status.isNotEmpty) Text(status, style: T.ui(12.5, FontWeight.w400, T.text2)),
        ]),
      ]),
      section('YouTube — direct (optional)', [
        Text('Bring in your YouTube and YouTube Music playlists and liked music. Songs that are also on Spotify merge into one entry. This imports the playlists only — not audio.',
            style: T.ui(13, FontWeight.w400, T.text2)),
        const SizedBox(height: 12),
        step(1, 'In Google Cloud Console create a project, then enable "YouTube Data API v3".'),
        step(2, 'OAuth consent screen: External, add yourself as a user, then set Publishing status to "In production" (otherwise Google signs you out every 7 days; the "unverified app" warning is expected — it\'s your own app).'),
        step(3, 'Credentials → Create OAuth client ID → type "Desktop app". Copy the Client ID and Client secret here.'),
        PillButton(label: 'Open Google Cloud Console', icon: Icons.open_in_new, onTap: () => launchUrl(Uri.parse('https://console.cloud.google.com/apis/library/youtube.googleapis.com'), mode: LaunchMode.externalApplication)),
        const SizedBox(height: 12),
        field('Google Client ID', googleId, hint: '….apps.googleusercontent.com'),
        field('Google Client secret', googleSecret, obscure: true),
        PillButton(
          label: importing ? 'Importing…' : 'Import my YouTube playlists',
          icon: Icons.smart_display_outlined,
          style: PillStyle.primary,
          onTap: importing
              ? null
              : () async {
                  await _saveAll();
                  setState(() => importing = true);
                  try {
                    await YouTubeImport.run((line) => setState(() => status = line));
                    await widget.store.load();
                  } catch (e) {
                    setState(() => status = '$e');
                  } finally {
                    setState(() => importing = false);
                  }
                },
        ),
      ]),
      if (desktop && widget.soulseek != null)
        section('Soulseek', [
          Text(
              widget.soulseek!.configured
                  ? 'Logged in details saved. You can change them below.'
                  : 'A Soulseek account is free — the first login with a new username creates it. If the name is taken, pick another.',
              style: T.ui(13, FontWeight.w400, T.text2)),
          const SizedBox(height: 12),
          field('Username', slskUser),
          field('Password', slskPass, obscure: true),
          PillButton(
            label: 'Save Soulseek login',
            icon: Icons.save_outlined,
            onTap: () async {
              if (slskUser.text.trim().isEmpty || slskPass.text.isEmpty) return;
              await widget.soulseek!.saveLogin(slskUser.text.trim(), slskPass.text);
              slskPass.clear();
              setState(() => status = 'Soulseek login saved.');
            },
          ),
        ]),
      section('Dropbox (optional)', [
        Text('Pull new tracks from a Dropbox folder into your library. Create a Dropbox app (Scoped access, "App folder" or "Full Dropbox", permission files.content.read), add ${AppConfig.dropboxRedirect} as a redirect URI, and paste its App key.',
            style: T.ui(13, FontWeight.w400, T.text2)),
        const SizedBox(height: 12),
        field('Dropbox App key', dropboxKey),
        field('Folder to pull from', dropboxFolder, hint: '/Music'),
        Wrap(spacing: 8, children: [
          PillButton(label: 'Open Dropbox developers', icon: Icons.open_in_new, onTap: () => launchUrl(Uri.parse('https://www.dropbox.com/developers/apps'), mode: LaunchMode.externalApplication)),
          if (Platform.isAndroid)
            PillButton(
              label: widget.dropbox.connected ? 'Reconnect Dropbox' : 'Connect Dropbox',
              icon: Icons.link,
              onTap: () async {
                await _saveAll();
                try {
                  await widget.dropbox.connect();
                  setState(() => status = 'Dropbox connected.');
                } catch (e) {
                  setState(() => status = '$e');
                }
              },
            ),
        ]),
      ]),
      section('Bug reports', [
        Text('Shown on reports you send, so the developer can follow up.', style: T.ui(13, FontWeight.w400, T.text2)),
        const SizedBox(height: 12),
        field('Your name', name),
        field('Email or contact (optional)', contact),
      ]),
      section('About', [
        Text('WreckBox $version · engine $engine', style: T.ui(13, FontWeight.w400, T.text2)),
        Text('Library folder: ${AppPaths.root.path}', style: T.ui(12, FontWeight.w400, T.text3)),
        const SizedBox(height: 10),
        PillButton(
          label: checking ? 'Checking…' : 'Check for updates',
          icon: Icons.system_update_alt,
          onTap: checking
              ? null
              : () async {
                  setState(() => checking = true);
                  final u = await Updates.check();
                  final msg = u != null
                      ? 'WreckBox ${u.version} is available — downloading it now.'
                      : Updates.lastError != null
                          ? "Couldn't check for updates: ${Updates.lastError}"
                          : "You're up to date (version $version).";
                  setState(() {
                    checking = false;
                    updateStatus = msg;
                  });
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                  if (u != null) launchUrl(Uri.parse(u.url), mode: LaunchMode.externalApplication);
                },
        ),
        if (updateStatus != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(updateStatus!, style: T.ui(12.5, FontWeight.w600, T.text2))),
      ]),
      PillButton(label: 'Save settings', icon: Icons.check, style: PillStyle.primary, onTap: () async {
        await _saveAll();
        setState(() => status = 'Saved.');
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
      }),
    ]);
  }
}
