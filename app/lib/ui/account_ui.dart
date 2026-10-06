// Account sign-in / sign-up (shared by phone and desktop) and the phone's "Your computers" list.

import 'dart:io';

import 'package:flutter/material.dart';

import '../account.dart';
import '../config.dart';
import '../phone_sync.dart';
import '../settings.dart';
import '../store.dart';
import 'theme.dart';

class AccountSection extends StatefulWidget {
  final LibraryStore store;
  final VoidCallback? onChanged;
  const AccountSection({super.key, required this.store, this.onChanged});
  @override
  State<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<AccountSection> {
  final email = TextEditingController(text: Settings.current.accountEmail ?? '');
  final password = TextEditingController(), name = TextEditingController();
  bool creating = false, busy = false;
  String? message;

  Future<void> _submit() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (creating) {
        await Account.signUp(email.text, password.text, name.text);
      } else {
        await Account.signIn(email.text, password.text);
      }
      password.clear();
      // Phone: bring in the account's playlists. Computer: put this library in the account.
      if (Platform.isAndroid || Platform.isIOS) {
        final had = await Account.downloadLibrary(widget.store);
        message = had ? 'Signed in — your playlists are loaded.' : 'Signed in. Your library appears here once your computer has synced it.';
      } else {
        await Account.uploadLibrary(widget.store);
        message = 'Signed in — your library is saved to your account.';
      }
    } catch (e) {
      message = '$e';
    } finally {
      setState(() => busy = false);
      widget.onChanged?.call();
    }
  }

  Future<void> _google() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await Account.signInWithGoogle();
      if (Platform.isAndroid || Platform.isIOS) {
        final had = await Account.downloadLibrary(widget.store);
        message = had ? 'Signed in — your playlists are loaded.' : 'Signed in. Your library appears here once your computer has synced it.';
      } else {
        await Account.uploadLibrary(widget.store);
        message = 'Signed in — your library is saved to your account.';
      }
    } catch (e) {
      message = '$e';
    } finally {
      setState(() => busy = false);
      widget.onChanged?.call();
    }
  }

  InputDecoration _deco(String label) => InputDecoration(
        labelText: label,
        labelStyle: T.ui(13, FontWeight.w400, T.text2),
        filled: true,
        fillColor: T.glassFill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      );

  @override
  Widget build(BuildContext context) {
    final s = Settings.current;
    return Glass(
      smart: !Account.signedIn,
      radius: 20,
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const DotLabel('WreckBox account', color: T.text),
        const SizedBox(height: 10),
        if (Account.signedIn) ...[
          Text('Signed in as ${s.accountEmail}', style: T.ui(14, FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            Platform.isAndroid || Platform.isIOS
                ? 'Your playlists come from your account, and your computer can stream to this phone from anywhere while it\'s on.'
                : 'This library is saved to your account. Turn on "Use from anywhere" (Sync to phone) so your phone can reach this computer away from home.',
            style: T.ui(12.5, FontWeight.w400, T.text2),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: [
            PillButton(
              label: busy ? 'Syncing…' : (Platform.isAndroid ? 'Refresh playlists' : 'Sync library now'),
              icon: Icons.sync,
              onTap: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        if (Platform.isAndroid || Platform.isIOS) {
                          await Account.downloadLibrary(widget.store);
                        } else {
                          await Account.uploadLibrary(widget.store);
                        }
                        message = 'Up to date.';
                      } catch (e) {
                        message = '$e';
                      }
                      setState(() => busy = false);
                    },
            ),
            PillButton(label: 'Sign out', icon: Icons.logout, onTap: () async {
              await Account.signOut();
              setState(() => message = 'Signed out.');
              widget.onChanged?.call();
            }),
          ]),
        ] else ...[
          Text(
            creating ? 'Create an account to use your library on every device.' : 'Sign in to get your playlists on this device and reach your computer from anywhere.',
            style: T.ui(12.5, FontWeight.w400, T.text2),
          ),
          const SizedBox(height: 10),
          if (Platform.isAndroid || Platform.isIOS) ...[
            Text('Easiest: on your computer open WreckBox → Sync to phone, then here go to Computer → Scan pairing code. '
                'That signs this phone in and connects it — no password needed.', style: T.ui(12.5, FontWeight.w600, T.lilac)),
            const SizedBox(height: 10),
            if (AppConfig.googleSignIn) ...[
              PillButton(label: 'Continue with Google', icon: Icons.account_circle, style: PillStyle.smart, onTap: busy ? null : _google),
              const SizedBox(height: 10),
            ],
            Text('or with email', style: T.ui(12, FontWeight.w400, T.text3)),
            const SizedBox(height: 8),
          ],
          if (creating) ...[TextField(controller: name, style: T.ui(14), decoration: _deco('Your name')), const SizedBox(height: 8)],
          TextField(controller: email, style: T.ui(14), keyboardType: TextInputType.emailAddress, decoration: _deco('Email')),
          const SizedBox(height: 8),
          TextField(controller: password, style: T.ui(14), obscureText: true, decoration: _deco('Password (8+ characters)'), onSubmitted: (_) => _submit()),
          const SizedBox(height: 10),
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            PillButton(label: busy ? 'Please wait…' : (creating ? 'Create account' : 'Sign in'), icon: Icons.person, style: PillStyle.primary, onTap: busy ? null : _submit),
            TextButton(
              onPressed: () => setState(() => creating = !creating),
              child: Text(creating ? 'I have an account' : 'Create an account', style: T.ui(12.5, FontWeight.w600, T.text2)),
            ),
          ]),
        ],
        if (message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(message!, style: T.ui(12.5, FontWeight.w600, T.text2))),
      ]),
    );
  }
}

/// Phone: picks the current address of a computer from the account and connects to it.
/// Phone: everything a scanned code from a computer can do — sign in with its one-time code, connect through the
/// account (works anywhere), or fall back to pairing on the same Wi-Fi. Returns a status line.
class PhoneLink {
  static Future<String?> handle(Map<String, String> info, LibraryStore store) async {
    final link = info['link'], computer = info['computer'];
    String? linkProblem;
    if (link != null) {
      try {
        await Account.claimLink(link);
        await Account.downloadLibrary(store).catchError((_) => false);
      } catch (e) {
        linkProblem = '$e';
      }
    }
    if (Account.signedIn && computer != null) {
      Settings.current.connectedComputerId = computer;
      await Settings.current.save();
      try {
        if (await AccountConnect.reconnect() != null) return null;
      } catch (_) {}
    }
    if (info['hosts']!.isEmpty) return linkProblem ?? 'Signed in. Turn on "Use from anywhere" on your computer to connect away from home.';
    if (await PhoneSyncClient.pair(info) != null) return null;
    if (linkProblem != null) return linkProblem;
    if (Account.signedIn) return 'Signed in, but your computer isn\'t reachable yet — on the computer turn on "Use from anywhere" (Sync to phone), then tap Refresh.';
    return 'This code only works on the same Wi-Fi. To connect from anywhere: on your computer sign in under Sync to phone '
        '(the code then signs this phone in too), and scan it again.';
  }
}

class AccountConnect {
  /// Re-resolves the remembered computer (tunnel addresses change when the computer restarts).
  /// Returns the computer if it's online and now connected.
  static Future<RemoteComputer?> reconnect() async {
    final s = Settings.current;
    if (!Account.signedIn) return null;
    final list = await Account.computers();
    final c = list.where((c) => c.id == s.connectedComputerId && c.online).firstOrNull ?? list.where((c) => c.online).firstOrNull;
    if (c == null) return null;
    await use(c);
    return c;
  }

  /// Connects through the account: a fresh ticket for `c`, then the home Wi-Fi address if the phone can reach it.
  static Future<void> use(RemoteComputer c) async {
    final t = await Account.ticket(c.id);
    final s = Settings.current;
    s.remoteDesktop = t['url'] ?? c.url;
    s.pairedDesktop = s.remoteDesktop;
    s.pairToken = t['ticket'];
    s.ticketExpires = t['expires'] ?? 0;
    s.connectedComputerId = c.id;
    await s.save();
    await PhoneSyncClient.preferLan();
  }

  /// Gets a new ticket when the current one is close to running out (no-op for QR-code pairings).
  static Future<void> refreshIfNeeded() async {
    final s = Settings.current;
    if (!Account.signedIn || s.connectedComputerId == null || s.ticketExpires == 0) return;
    if (DateTime.now().millisecondsSinceEpoch < s.ticketExpires - 30 * 60 * 1000) return;
    await reconnect();
  }
}
