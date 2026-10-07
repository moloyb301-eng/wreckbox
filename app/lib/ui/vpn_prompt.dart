// Before a download starts (here: asking the computer to fetch a song from Soulseek / YouTube): a reminder to turn
// a VPN on. Soulseek shows the downloader's IP address to other users. "Don't ask again today" quiets it until
// tomorrow. It only appears when a download is about to start.

import 'package:flutter/material.dart';

import '../settings.dart';
import 'theme.dart';

Future<bool> confirmVpn(BuildContext context) async {
  final today = DateTime.now().toIso8601String().substring(0, 10);
  if (Settings.current.vpnAcknowledged == today) return true;
  var quiet = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        backgroundColor: T.bgRaised,
        title: Text('Turn on your VPN before downloading', style: T.ui(17, FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Soulseek shows the IP address of whoever downloads to the people they download from, and YouTube downloads come from that connection too. Connect your VPN first, then carry on.',
              style: T.ui(13, FontWeight.w400, T.text2)),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: quiet,
            activeColor: T.lilac,
            onChanged: (v) => set(() => quiet = v ?? false),
            title: Text("Don't ask again today", style: T.ui(13, FontWeight.w600)),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('My VPN is on — download')),
        ],
      ),
    ),
  );
  if (ok == true && quiet) {
    Settings.current.vpnAcknowledged = today;
    await Settings.current.save();
  }
  return ok == true;
}
