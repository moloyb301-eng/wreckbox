// "Report a bug": title, what happened, a screenshot of the app (captured automatically) plus any images the
// user adds, and recent activity. Sent through the relay → GitHub issue → email to the developer.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../services.dart';
import '../settings.dart';
import '../store.dart';
import 'theme.dart';

/// Wrap the whole app in a RepaintBoundary with this key so a report can include what the user was seeing.
final screenshotKey = GlobalKey();

Future<Uint8List?> captureApp() async {
  try {
    final boundary = screenshotKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}

Future<void> openBugReport(BuildContext context, LibraryStore store, {List<String> extraLog = const []}) async {
  final shot = await captureApp(); // before the dialog covers the screen
  if (!context.mounted) return;
  await showDialog(context: context, builder: (_) => _BugReportDialog(store: store, autoShot: shot, extraLog: extraLog));
}

class _BugReportDialog extends StatefulWidget {
  final LibraryStore store;
  final Uint8List? autoShot;
  final List<String> extraLog;
  const _BugReportDialog({required this.store, this.autoShot, required this.extraLog});
  @override
  State<_BugReportDialog> createState() => _BugReportDialogState();
}

class _BugReportDialogState extends State<_BugReportDialog> {
  final title = TextEditingController(), body = TextEditingController();
  late bool includeShot = widget.autoShot != null;
  final extra = <(Uint8List, String, String)>[]; // bytes, mime, name
  bool sending = false;
  String? result;

  Future<void> _addImages() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    for (final f in files) {
      if (extra.length >= 2) break;
      final bytes = await f.xFile.readAsBytes();
      setState(() => extra.add((bytes, (f.extension ?? '').toLowerCase().startsWith('jp') ? 'image/jpeg' : 'image/png', f.name)));
    }
  }

  Future<void> _send() async {
    if (body.text.trim().isEmpty) {
      setState(() => result = 'Please describe what happened.');
      return;
    }
    setState(() {
      sending = true;
      result = null;
    });
    try {
      final n = await BugReport.send(
        title: title.text.trim().isEmpty ? body.text.trim().split('\n').first : title.text.trim(),
        description: body.text.trim(),
        screenshots: [if (includeShot && widget.autoShot != null) (widget.autoShot!, 'image/png'), for (final (b, m, _) in extra) (b, m)],
        store: widget.store,
        extraLog: widget.extraLog,
      );
      setState(() => result = 'Sent — thank you! (report #$n)');
    } catch (e) {
      setState(() => result = "Couldn't send: $e");
    } finally {
      setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label) => InputDecoration(
          labelText: label,
          labelStyle: T.ui(13, FontWeight.w400, T.text2),
          filled: true,
          fillColor: T.glassFill,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        );
    return Dialog(
      backgroundColor: T.bgRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const DotLabel('Report a bug', color: T.text),
            const SizedBox(height: 6),
            Text('What went wrong? The more detail, the faster it gets fixed.', style: T.ui(13, FontWeight.w400, T.text2)),
            const SizedBox(height: 14),
            TextField(controller: title, style: T.ui(14), decoration: deco('Short title (optional)')),
            const SizedBox(height: 10),
            TextField(controller: body, style: T.ui(14), minLines: 4, maxLines: 10, decoration: deco('What did you do, what happened, what did you expect?')),
            const SizedBox(height: 12),
            if (widget.autoShot != null)
              CheckboxListTile(
                value: includeShot,
                onChanged: (v) => setState(() => includeShot = v ?? false),
                contentPadding: EdgeInsets.zero,
                title: Text('Include a screenshot of the app', style: T.ui(13)),
                secondary: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(widget.autoShot!, width: 64, fit: BoxFit.cover)),
              ),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (b, _, n) in extra)
                Chip(
                  avatar: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.memory(b, width: 24, height: 24, fit: BoxFit.cover)),
                  label: Text(n, style: T.ui(12)),
                  onDeleted: () => setState(() => extra.removeWhere((e) => e.$3 == n)),
                ),
              if (extra.length < 2) PillButton(label: 'Add screenshots', icon: Icons.add_photo_alternate_outlined, onTap: _addImages),
            ]),
            const SizedBox(height: 8),
            Text(
              'Also sent: app version, device type, your name from Settings${Settings.current.reporterName.isEmpty ? ' (not set)' : ''}, and recent WreckBox activity. No music files or passwords.',
              style: T.ui(11.5, FontWeight.w400, T.text3),
            ),
            const SizedBox(height: 16),
            if (result != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(result!, style: T.ui(13, FontWeight.w600, result!.startsWith('Sent') ? T.lilac : T.peach))),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(result?.startsWith('Sent') == true ? 'Close' : 'Cancel', style: T.ui(13, FontWeight.w600, T.text2))),
              const SizedBox(width: 8),
              PillButton(label: sending ? 'Sending…' : 'Send report', icon: Icons.send, style: PillStyle.primary, onTap: sending || result?.startsWith('Sent') == true ? null : _send),
            ]),
          ]),
        ),
      ),
    );
  }
}
