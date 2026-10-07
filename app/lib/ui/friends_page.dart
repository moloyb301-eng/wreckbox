// Friends tab: add a friend's key / link, browse what they shared, stream it (tap) or download it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../friends.dart';
import '../player.dart';
import 'theme.dart';
import 'vpn_prompt.dart';

class FriendsPage extends StatefulWidget {
  const FriendsPage({super.key});
  @override
  State<FriendsPage> createState() => _FriendsPageState();
}

class _FriendsPageState extends State<FriendsPage> {
  final f = Friends.instance;
  final key = TextEditingController();
  String? selected, error;
  bool adding = false;

  @override
  void initState() {
    super.initState();
    selected = f.shares.isEmpty ? null : f.shares.first.id;
    if (selected != null && f.tracks[selected] == null) f.load(selected!);
    _fromClipboard();
  }

  /// A key just copied from a friend's message fills itself in.
  Future<void> _fromClipboard() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final k = Friends.keyFrom(text);
    if (k != null && !f.shares.any((s) => s.key == k) && mounted) setState(() => key.text = k);
  }

  Future<void> _add() async {
    if (adding) return;
    setState(() {
      adding = true;
      error = null;
    });
    try {
      await f.add(key.text);
      key.clear();
      if (mounted) FocusScope.of(context).unfocus();
      selected = f.shares.first.id;
    } catch (e) {
      error = '$e'.replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => adding = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([f, Player.instance]),
      builder: (context, _) {
        final share = f.shares.where((s) => s.id == selected).firstOrNull;
        final list = selected == null ? const <FriendTrack>[] : (f.tracks[selected] ?? const <FriendTrack>[]);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 6),
          Text('Friends', style: T.ui(26, FontWeight.w500)),
          Text('Stream and download what friends share with you', style: T.ui(12.5, FontWeight.w400, T.text2)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: key,
                style: T.ui(14),
                textCapitalization: TextCapitalization.characters,
                onSubmitted: (_) => _add(),
                decoration: InputDecoration(
                  hintText: "Friend's key or link (WBX-…)",
                  hintStyle: T.ui(14, FontWeight.w400, T.text3),
                  filled: true,
                  fillColor: T.glassFill,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: T.hairline)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: T.hairline)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            PillButton(label: adding ? 'Opening…' : 'Add', icon: Icons.add, style: PillStyle.smart, onTap: adding ? null : _add),
          ]),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: T.ui(12.5, FontWeight.w500, T.peach))),
          const SizedBox(height: 12),
          if (f.shares.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('When a friend shares their library or a playlist from WreckBox on their Mac, paste the key here to stream and download it.',
                      textAlign: TextAlign.center, style: T.ui(14, FontWeight.w400, T.text2)),
                ),
              ),
            )
          else ...[
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final s in f.shares)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: GestureDetector(
                      onLongPress: () => _confirmRemove(s),
                      child: PillButton(
                        label: s.title,
                        icon: s.kind == 'playlist' ? Icons.queue_music : Icons.library_music,
                        style: s.id == selected ? PillStyle.primary : PillStyle.glass,
                        onTap: () {
                          setState(() => selected = s.id);
                          if (f.tracks[s.id] == null) f.load(s.id);
                        },
                      ),
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 10),
            if (share != null)
              Row(children: [
                Expanded(
                  child: Text(f.status[share.id] ?? '${list.length} tracks · from ${share.owner}',
                      maxLines: 2,
                      style: T.ui(12.5, FontWeight.w500, f.status[share.id] == null || f.status[share.id] == 'Loading…' ? T.text2 : T.peach)),
                ),
                if (list.isNotEmpty) ...[
                  IconButton(
                      tooltip: 'Shuffle',
                      icon: const Icon(Icons.shuffle, color: T.text),
                      onPressed: () => Player.instance.playShuffled([for (final t in list) t.id])),
                  IconButton(
                      tooltip: 'Play',
                      icon: const Icon(Icons.play_circle_fill, color: T.lilac, size: 30),
                      onPressed: () => Player.instance.play(list.first.id, list: [for (final t in list) t.id])),
                ],
                IconButton(tooltip: 'Reload', icon: const Icon(Icons.refresh, color: T.text2), onPressed: () => f.load(share.id)),
              ]),
            Expanded(
              child: ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) => _row(list[i], list),
              ),
            ),
          ],
        ]);
      },
    );
  }

  Widget _row(FriendTrack t, List<FriendTrack> list) {
    final playing = Player.instance.currentId == t.id;
    final job = f.jobs[t.id];
    final q = t.quality ?? t.ext.replaceFirst('.', '').toUpperCase();
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Player.instance.play(t.id, list: [for (final x in list) x.id]),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 44,
              height: 44,
              child: t.track.artworkURL == null
                  ? Container(color: T.glassFill, child: const Icon(Icons.music_note, color: T.text3))
                  : Image.network(t.track.artworkURL!, fit: BoxFit.cover, errorBuilder: (_, _, _) => Container(color: T.glassFill)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(13.5, FontWeight.w600, playing ? T.lilac : T.text)),
              const SizedBox(height: 2),
              Row(children: [
                Flexible(child: Text(t.track.artists.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(12, FontWeight.w400, T.text2))),
                const SizedBox(width: 6),
                Text(q, style: T.dot(9.5, q.startsWith('FLAC') ? T.lilac : T.text3)),
              ]),
            ]),
          ),
          switch (job) {
            'downloading' => const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: T.lilac))),
            'done' => const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.download_done, color: T.lilac, size: 20)),
            null => IconButton(
                tooltip: 'Download',
                icon: Icon(f.savedFile(t.id) != null ? Icons.download_done : Icons.download, color: f.savedFile(t.id) != null ? T.lilac : T.text2, size: 20),
                onPressed: f.savedFile(t.id) != null
                    ? null
                    : () async {
                        if (await confirmVpn(context)) await f.download(t.id);
                      }),
            final e => IconButton(tooltip: e, icon: const Icon(Icons.error_outline, color: T.peach, size: 20), onPressed: () => f.download(t.id)),
          },
        ]),
      ),
    );
  }

  Future<void> _confirmRemove(FriendShare s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.bgRaised,
        title: Text('Remove ${s.title}?', style: T.ui(17, FontWeight.w700)),
        content: Text('Downloaded tracks stay on your phone. You can add it again with the key.', style: T.ui(13, FontWeight.w400, T.text2)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await f.remove(s.id);
      setState(() => selected = f.shares.isEmpty ? null : f.shares.first.id);
    }
  }
}
