// Data model. The JSON shapes match the Mac app (library.json, state.json, _cache/analysis.json) so the
// same library folder works on every platform and the Mac app can move over later.

class LibraryTrack {
  final String id; // ISRC when available, else spotify:<id>, else normalised artist+title
  final List<String> artists;
  final String title;
  final String? album;
  final String? year;
  final String? isrc;
  final List<String> spotifyIDs;
  final int? durationMs;
  final List<String> playlists;
  final String? firstAdded;
  final String fileName; // "Artist - Title" stem used for files
  final String? artworkURL;

  LibraryTrack({
    required this.id,
    required this.artists,
    required this.title,
    this.album,
    this.year,
    this.isrc,
    this.spotifyIDs = const [],
    this.durationMs,
    this.playlists = const [],
    this.firstAdded,
    required this.fileName,
    this.artworkURL,
  });

  String get artist => artists.join(', ');

  factory LibraryTrack.fromJson(Map<String, dynamic> j) => LibraryTrack(
        id: j['id'],
        artists: List<String>.from(j['artists'] ?? const []),
        title: j['title'] ?? '',
        album: j['album'],
        year: j['year'],
        isrc: j['isrc'],
        spotifyIDs: List<String>.from(j['spotifyIDs'] ?? const []),
        durationMs: j['durationMs'],
        playlists: List<String>.from(j['playlists'] ?? const []),
        firstAdded: j['firstAdded'],
        fileName: j['fileName'] ?? '',
        artworkURL: j['artworkURL'],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'artists': artists,
        'title': title,
        if (album != null) 'album': album,
        if (year != null) 'year': year,
        if (isrc != null) 'isrc': isrc,
        'spotifyIDs': spotifyIDs,
        if (durationMs != null) 'durationMs': durationMs,
        'playlists': playlists,
        if (firstAdded != null) 'firstAdded': firstAdded,
        'fileName': fileName,
        'status': 'missing', // kept for the Mac format
        if (artworkURL != null) 'artworkURL': artworkURL,
      };
}

class LibraryPlaylist {
  final String name;
  final String? spotifyID;
  final bool collaborative;
  final List<String> trackIDs;

  LibraryPlaylist({required this.name, this.spotifyID, this.collaborative = false, this.trackIDs = const []});

  factory LibraryPlaylist.fromJson(Map<String, dynamic> j) => LibraryPlaylist(
        name: j['name'] ?? '',
        spotifyID: j['spotifyID'],
        collaborative: j['collaborative'] ?? false,
        trackIDs: List<String>.from(j['trackIDs'] ?? const []),
      );

  Map<String, dynamic> toJson() =>
      {'name': name, if (spotifyID != null) 'spotifyID': spotifyID, 'collaborative': collaborative, 'trackIDs': trackIDs};
}

class Library {
  final DateTime builtAt;
  final String spotifyUser;
  final List<LibraryTrack> tracks;
  final List<LibraryPlaylist> playlists;

  Library({required this.builtAt, required this.spotifyUser, required this.tracks, required this.playlists});

  factory Library.fromJson(Map<String, dynamic> j) => Library(
        builtAt: DateTime.tryParse(j['builtAt'] ?? '') ?? DateTime.now(),
        spotifyUser: j['spotifyUser'] ?? '',
        tracks: [for (final t in (j['tracks'] as List? ?? const [])) LibraryTrack.fromJson(t)],
        playlists: [for (final p in (j['playlists'] as List? ?? const [])) LibraryPlaylist.fromJson(p)],
      );

  Map<String, dynamic> toJson() => {
        'builtAt': builtAt.toUtc().toIso8601String().split('.').first + 'Z',
        'spotifyUser': spotifyUser,
        'tracks': [for (final t in tracks) t.toJson()],
        'playlists': [for (final p in playlists) p.toJson()],
      };
}

enum TrackStatus { missing, downloaded, ignored }

class TrackState {
  final TrackStatus status;
  final String? localPath;
  final String? source; // "scan", "soulseek", "soundcloud", "organizer", "phone-sync", "dropbox", "manual"
  final DateTime updatedAt;

  TrackState({required this.status, this.localPath, this.source, DateTime? updatedAt})
      : updatedAt = updatedAt ?? DateTime.now();

  factory TrackState.fromJson(Map<String, dynamic> j) => TrackState(
        status: TrackStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => TrackStatus.missing),
        localPath: j['localPath'],
        source: j['source'],
        updatedAt: DateTime.tryParse(j['updatedAt'] ?? ''),
      );

  Map<String, dynamic> toJson() => {
        'status': status.name,
        if (localPath != null) 'localPath': localPath,
        if (source != null) 'source': source,
        'updatedAt': isoSeconds(updatedAt),
      };
}

class LogEntry {
  final String id;
  final DateTime date;
  final String event;
  final String? trackID;
  final String detail;

  LogEntry({String? id, DateTime? date, required this.event, this.trackID, required this.detail})
      : id = id ?? _uuid(),
        date = date ?? DateTime.now();

  factory LogEntry.fromJson(Map<String, dynamic> j) => LogEntry(
        id: j['id'],
        date: DateTime.tryParse(j['date'] ?? ''),
        event: j['event'] ?? '',
        trackID: j['trackID'],
        detail: j['detail'] ?? '',
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'date': isoSeconds(date), 'event': event, if (trackID != null) 'trackID': trackID, 'detail': detail};
}

/// state.json — tolerant of missing keys, like the Mac app.
class AppState {
  Map<String, TrackState> tracks = {};
  List<LogEntry> log = [];
  Map<String, String> genreOverrides = {};
  List<String> scanFolders = [];
  List<String> downloadPriority = [];
  bool priorityOnly = false;

  AppState();

  factory AppState.fromJson(Map<String, dynamic> j) {
    final s = AppState();
    (j['tracks'] as Map? ?? const {}).forEach((k, v) => s.tracks[k] = TrackState.fromJson(Map<String, dynamic>.from(v)));
    s.log = [for (final e in (j['log'] as List? ?? const [])) LogEntry.fromJson(Map<String, dynamic>.from(e))];
    s.genreOverrides = Map<String, String>.from(j['genreOverrides'] ?? const {});
    s.scanFolders = List<String>.from(j['scanFolders'] ?? const []);
    s.downloadPriority = List<String>.from(j['downloadPriority'] ?? const []);
    s.priorityOnly = j['priorityOnly'] ?? false;
    return s;
  }

  Map<String, dynamic> toJson() => {
        'tracks': tracks.map((k, v) => MapEntry(k, v.toJson())),
        'log': [for (final e in log.length > 5000 ? log.sublist(log.length - 5000) : log) e.toJson()],
        'genreOverrides': genreOverrides,
        'scanFolders': scanFolders,
        'downloadPriority': downloadPriority,
        'priorityOnly': priorityOnly,
      };
}

/// One analysed file (from the Rust engine), keyed by path in _cache/analysis.json.
class FileAnalysis {
  final String path;
  final int sizeBytes;
  final DateTime? modified;
  final String? artist;
  final String? title;
  final double? durationSec;
  final double? bpm;
  final double? bpmConfidence;
  final double? bpmAlternate;
  final List<double> bpmCandidates;
  final String? key;
  final String? camelot;
  final double? keyStrength;
  final int? keyAgreement;
  final double? energy;
  final double? loudnessLUFS;
  final String? libraryTrackID;
  final String engine;

  FileAnalysis({
    required this.path,
    required this.sizeBytes,
    this.modified,
    this.artist,
    this.title,
    this.durationSec,
    this.bpm,
    this.bpmConfidence,
    this.bpmAlternate,
    this.bpmCandidates = const [],
    this.key,
    this.camelot,
    this.keyStrength,
    this.keyAgreement,
    this.energy,
    this.loudnessLUFS,
    this.libraryTrackID,
    this.engine = 'wreckbox',
  });

  bool get bpmUnsure => (bpmConfidence ?? 1) < 0.25;
  bool get keyUnsure => keyAgreement != null ? (keyAgreement! < 2 || (keyStrength ?? 1) < 0.5) : false;

  FileAnalysis copyWith({String? libraryTrackID, double? bpm, int? sizeBytes, DateTime? modified}) => FileAnalysis(
        path: path,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        modified: modified ?? this.modified,
        artist: artist,
        title: title,
        durationSec: durationSec,
        bpm: bpm ?? this.bpm,
        bpmConfidence: bpmConfidence,
        bpmAlternate: bpmAlternate,
        bpmCandidates: bpmCandidates,
        key: key,
        camelot: camelot,
        keyStrength: keyStrength,
        keyAgreement: keyAgreement,
        energy: energy,
        loudnessLUFS: loudnessLUFS,
        libraryTrackID: libraryTrackID ?? this.libraryTrackID,
        engine: engine,
      );

  factory FileAnalysis.fromJson(Map<String, dynamic> j) => FileAnalysis(
        path: j['path'] ?? '',
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        modified: DateTime.tryParse(j['modified'] ?? ''),
        artist: j['artist'],
        title: j['title'],
        durationSec: (j['durationSec'] as num?)?.toDouble(),
        bpm: (j['bpm'] as num?)?.toDouble(),
        bpmConfidence: (j['bpmConfidence'] as num?)?.toDouble(),
        bpmAlternate: (j['bpmAlternate'] as num?)?.toDouble(),
        bpmCandidates: [for (final c in (j['bpmCandidates'] as List? ?? const [])) (c as num).toDouble()],
        key: j['key'],
        camelot: j['camelot'],
        keyStrength: ((j['keyStrength'] ?? j['keyConfidence']) as num?)?.toDouble(),
        keyAgreement: (j['keyAgreement'] as num?)?.toInt(),
        energy: (j['energy'] as num?)?.toDouble(),
        loudnessLUFS: ((j['loudnessLUFS'] ?? j['loudnessLufs']) as num?)?.toDouble(),
        libraryTrackID: j['libraryTrackID'],
        engine: j['engine'] ?? 'wreckbox',
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'sizeBytes': sizeBytes,
        if (modified != null) 'modified': isoSeconds(modified!),
        if (artist != null) 'artist': artist,
        if (title != null) 'title': title,
        if (durationSec != null) 'durationSec': durationSec,
        if (bpm != null) 'bpm': bpm,
        'bpmAmbiguous': bpmUnsure,
        if (bpmConfidence != null) 'bpmConfidence': bpmConfidence,
        if (bpmAlternate != null) 'bpmAlternate': bpmAlternate,
        'bpmCandidates': bpmCandidates,
        if (key != null) 'key': key,
        if (camelot != null) 'camelot': camelot,
        if (keyStrength != null) 'keyConfidence': keyStrength,
        if (keyAgreement != null) 'keyAgreement': keyAgreement,
        if (energy != null) 'energy': energy,
        if (loudnessLUFS != null) 'loudnessLUFS': loudnessLUFS,
        if (libraryTrackID != null) 'libraryTrackID': libraryTrackID,
        'analyzedAt': isoSeconds(DateTime.now()),
        'engine': engine,
      };
}

String isoSeconds(DateTime d) => '${d.toUtc().toIso8601String().split('.').first}Z';

int _counter = 0;
String _uuid() {
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
  return '${t.padLeft(12, '0')}-${(_counter++).toRadixString(16).padLeft(4, '0')}';
}

/// Lower-case, accent-free, words separated by single spaces (same as the Mac app's `normalized`).
String normalized(String s) {
  const accents = {'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
    'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', 'ø': 'o', 'ú': 'u',
    'ù': 'u', 'û': 'u', 'ü': 'u', 'ñ': 'n', 'ç': 'c', 'ý': 'y', 'ÿ': 'y'};
  // Drop combining marks first: macOS file names store "Ü" as "U" + U+0308, which would split words.
  final lower = s.toLowerCase().replaceAll(RegExp('[\u0300-\u036f]'), '').split('').map((c) => accents[c] ?? c).join();
  return RegExp(r'[a-z0-9]+').allMatches(lower).map((m) => m.group(0)).join(' ');
}

/// File-name-safe stem: no path separators / reserved characters, no trailing dots or spaces.
String safeFileName(String s) {
  var out = s.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), '_').trim();
  if (out.length > 180) out = out.substring(0, 180);
  out = out.replaceAll(RegExp(r'[. ]+$'), '');
  return out;
}
