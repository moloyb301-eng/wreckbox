// Phone: your Spotify playlists (from the computer's library, kept current by its daily Spotify sync), played from
// your own files — the ones on the phone, the rest streamed from the computer in the chosen quality.

import 'dart:math';

import 'package:flutter/material.dart';

import '../models.dart';
import '../player.dart';
import '../store.dart';
import 'player_bar.dart';
import 'theme.dart';
import 'tracks.dart';

class PlaylistsView extends StatelessWidget {
  final LibraryStore store;
  const PlaylistsView({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    final lists = store.library?.playlists ?? const <LibraryPlaylist>[];
    return ListenableBuilder(
      listenable: Player.instance, // which tracks can stream changes when the computer connects
      builder: (context, _) => ListView.builder(
        itemCount: lists.length,
        itemBuilder: (context, i) {
          final pl = lists[i];
          final playable = pl.trackIDs.where(Player.instance.canPlay).length;
          final first = pl.trackIDs.map(store.row).firstWhere((r) => r != null, orElse: () => null);
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            leading: first != null
                ? Artwork(track: first.track, store: store, size: 48, radius: 8)
                : Container(width: 48, height: 48, decoration: BoxDecoration(color: T.glassFill, borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.queue_music, color: T.text3)),
            title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: T.ui(14.5, FontWeight.w600)),
            subtitle: Text('${pl.trackIDs.length} tracks · $playable playable', style: T.ui(12, FontWeight.w400, T.text3)),
            trailing: IconButton(
              tooltip: 'Play',
              icon: const Icon(Icons.play_circle_fill_rounded, color: T.lilac, size: 30),
              onPressed: playable == 0 ? null : () => playPlaylist(pl),
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PlaylistPage(store: store, playlist: pl))),
          );
        },
      ),
    );
  }

  /// Plays the playlist's tracks that this phone has or the computer can stream.
  static void playPlaylist(LibraryPlaylist pl, {bool shuffle = false}) {
    final ids = pl.trackIDs.where(Player.instance.canPlay).toList();
    if (ids.isEmpty) return;
    if (shuffle) ids.shuffle(Random());
    Player.instance.play(ids.first, list: ids);
  }
}

class PlaylistPage extends StatelessWidget {
  final LibraryStore store;
  final LibraryPlaylist playlist;
  const PlaylistPage({super.key, required this.store, required this.playlist});

  @override
  Widget build(BuildContext context) {
    final playable = playlist.trackIDs.where(Player.instance.canPlay).length;
    return Scaffold(
      backgroundColor: T.bg,
      appBar: AppBar(backgroundColor: T.bg, title: Text(playlist.name, style: T.ui(17, FontWeight.w600))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${playlist.trackIDs.length} tracks · $playable playable from your own files', style: T.ui(12.5, FontWeight.w400, T.text2)),
            const SizedBox(height: 10),
            Row(children: [
              PillButton(label: 'Play', icon: Icons.play_arrow_rounded, style: PillStyle.primary, onTap: playable == 0 ? null : () => PlaylistsView.playPlaylist(playlist)),
              const SizedBox(width: 8),
              PillButton(label: 'Shuffle', icon: Icons.shuffle_rounded, onTap: playable == 0 ? null : () => PlaylistsView.playPlaylist(playlist, shuffle: true)),
            ]),
            const SizedBox(height: 10),
            Expanded(child: TrackListView(store: store, playlist: playlist.name, compact: true)),
          ]),
        ),
      ),
      bottomNavigationBar: PlayerBar(store: store, compact: true),
    );
  }
}
