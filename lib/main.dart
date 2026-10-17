import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const purple = Color(0xFF9B78FF);
const background = Color(0xFF100D1C);
const surface = Color(0xFF1D1830);
const surfaceHigh = Color(0xFF302347);

/// Languages a song can have. Edit this list to add more.
const languages = ['Amharic', 'English', 'Other'];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.enu.app.channel.audio',
      androidNotificationChannelName: 'Enu playback',
      androidNotificationOngoing: true,
    );
  } catch (_) {
    // Background playback needs the Android setup (see SETUP.md).
    // The app still works without it.
  }
  final app = AppState();
  await app.init();
  runApp(EnuApp(app: app));
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class Song {
  final String id;
  final String title;
  final String artist;
  final String source;
  final bool local;
  final String language;
  final bool favorite;
  final int addedAt;
  final int plays;

  const Song({
    required this.id,
    required this.title,
    required this.source,
    required this.local,
    this.artist = '',
    this.language = 'Other',
    this.favorite = false,
    this.addedAt = 0,
    this.plays = 0,
  });

  Song copyWith({
    String? title,
    String? artist,
    String? source,
    bool? local,
    String? language,
    bool? favorite,
    int? plays,
  }) {
    return Song(
      id: id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      source: source ?? this.source,
      local: local ?? this.local,
      language: language ?? this.language,
      favorite: favorite ?? this.favorite,
      addedAt: addedAt,
      plays: plays ?? this.plays,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'source': source,
        'local': local,
        'language': language,
        'favorite': favorite,
        'addedAt': addedAt,
        'plays': plays,
      };

  factory Song.fromJson(Map<String, dynamic> json) {
    final source = json['source'] as String? ?? '';
    return Song(
      id: json['id'] as String? ?? 'legacy_${source.hashCode.abs()}',
      title: json['title'] as String? ?? 'Unknown song',
      artist: json['artist'] as String? ?? '',
      source: source,
      local: json['local'] as bool? ?? true,
      language: json['language'] as String? ?? 'Other',
      favorite: json['favorite'] as bool? ?? false,
      addedAt: json['addedAt'] as int? ?? 0,
      plays: json['plays'] as int? ?? 0,
    );
  }
}

class Playlist {
  final String id;
  String name;
  final List<String> songIds;

  Playlist({required this.id, required this.name, List<String>? songIds})
      : songIds = songIds ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'songIds': songIds,
      };

  factory Playlist.fromJson(Map<String, dynamic> json) => Playlist(
        id: json['id'] as String? ?? DateTime.now().toIso8601String(),
        name: json['name'] as String? ?? 'Playlist',
        songIds: (json['songIds'] as List?)?.whereType<String>().toList(),
      );
}

enum RepeatMode { off, all, one }

enum SortMode { recent, title, plays }

List<Song> sortSongs(Iterable<Song> input, SortMode mode) {
  final list = input.toList();
  switch (mode) {
    case SortMode.recent:
      list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      break;
    case SortMode.title:
      list.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
      break;
    case SortMode.plays:
      list.sort((a, b) => b.plays.compareTo(a.plays));
      break;
  }
  return list;
}

// ---------------------------------------------------------------------------
// App state: library + player
// ---------------------------------------------------------------------------

class AppState extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  final Random _rng = Random();

  List<Song> songs = [];
  List<Playlist> playlists = [];

  List<String> queue = [];
  int queueIndex = -1;
  final List<String> _history = [];

  bool shuffle = false;
  RepeatMode repeat = RepeatMode.off;
  String userName = 'Guest';
  String defaultLanguage = 'Other';

  Timer? _sleepTimer;
  DateTime? sleepEndsAt;
  final Set<String> _downloading = {};

  void Function(String message)? onMessage;

  void _msg(String text) => onMessage?.call(text);

  Song? get current => queueIndex >= 0 && queueIndex < queue.length
      ? byId(queue[queueIndex])
      : null;

  Song? byId(String id) {
    for (final s in songs) {
      if (s.id == id) return s;
    }
    return null;
  }

  Playlist? playlistById(String id) {
    for (final p in playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  List<Song> songsOf(Playlist p) =>
      p.songIds.map(byId).whereType<Song>().toList();

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}${_rng.nextInt(9999)}';

  // ---- startup -------------------------------------------------------------

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();

    final savedSongs = prefs.getStringList('enu_songs') ?? [];
    final loaded = <Song>[];
    for (final entry in savedSongs) {
      try {
        final song = Song.fromJson(
          Map<String, dynamic>.from(jsonDecode(entry) as Map),
        );
        if (song.source.isEmpty) continue;
        if (song.local && !await File(song.source).exists()) continue;
        loaded.add(song);
      } catch (_) {
        // Ignore damaged records.
      }
    }
    songs = loaded;

    final savedLists = prefs.getStringList('enu_playlists') ?? [];
    final lists = <Playlist>[];
    for (final entry in savedLists) {
      try {
        lists.add(Playlist.fromJson(
          Map<String, dynamic>.from(jsonDecode(entry) as Map),
        ));
      } catch (_) {}
    }
    playlists = lists;

    shuffle = prefs.getBool('enu_shuffle') ?? false;
    final repeatIndex = (prefs.getInt('enu_repeat_mode') ?? 0).clamp(0, 2);
    repeat = RepeatMode.values[repeatIndex];
    userName = prefs.getString('enu_user_name') ?? 'Guest';
    defaultLanguage = prefs.getString('enu_default_language') ?? 'Other';
    if (!languages.contains(defaultLanguage)) defaultLanguage = 'Other';

    await player.setLoopMode(
      repeat == RepeatMode.one ? LoopMode.one : LoopMode.off,
    );

    player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) _onCompleted();
    });
    player.playerStateStream.listen((_) => notifyListeners());
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    player.dispose();
    super.dispose();
  }

  // ---- persistence ---------------------------------------------------------

  Future<void> _saveSongs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'enu_songs',
      songs.map((s) => jsonEncode(s.toJson())).toList(),
    );
  }

  Future<void> _savePlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'enu_playlists',
      playlists.map((p) => jsonEncode(p.toJson())).toList(),
    );
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('enu_shuffle', shuffle);
    await prefs.setInt('enu_repeat_mode', repeat.index);
    await prefs.setString('enu_user_name', userName);
    await prefs.setString('enu_default_language', defaultLanguage);
  }

  Future<Directory> _musicDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/enu_music');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ---- playback ------------------------------------------------------------

  Future<void> playQueue(List<Song> list, int start) async {
    if (list.isEmpty || start < 0 || start >= list.length) return;
    queue = list.map((s) => s.id).toList();
    queueIndex = -1;
    _history.clear();
    await _playIndex(start, pushHistory: false);
  }

  Future<void> playShuffled(List<Song> list) async {
    if (list.isEmpty) return;
    shuffle = true;
    unawaited(_savePrefs());
    await playQueue(list, _rng.nextInt(list.length));
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= queue.length) return;
    await _playIndex(index);
  }

  Future<void> _playIndex(int index, {bool pushHistory = true}) async {
    final song = byId(queue[index]);
    if (song == null) return;

    final previous = current;
    try {
      final tag = MediaItem(
        id: song.id,
        title: song.title,
        artist: song.artist.isEmpty ? 'Enu' : song.artist,
      );
      final source = song.local
          ? AudioSource.file(song.source, tag: tag)
          : AudioSource.uri(Uri.parse(song.source), tag: tag);
      await player.setAudioSource(source);

      if (pushHistory && previous != null) {
        _history.add(previous.id);
        if (_history.length > 100) _history.removeAt(0);
      }
      queueIndex = index;
      _bumpPlays(song.id);
      notifyListeners();
      unawaited(player.play());
    } catch (_) {
      _msg('Could not play "${song.title}". Check the file or link.');
    }
  }

  void _bumpPlays(String id) {
    final i = songs.indexWhere((s) => s.id == id);
    if (i < 0) return;
    songs[i] = songs[i].copyWith(plays: songs[i].plays + 1);
    unawaited(_saveSongs());
  }

  Future<void> _onCompleted() async {
    final moved = await next(auto: true);
    if (!moved) {
      await player.pause();
      await player.seek(Duration.zero);
    }
  }

  Future<bool> next({bool auto = false}) async {
    if (queue.isEmpty) return false;
    int target;
    if (shuffle && queue.length > 1) {
      do {
        target = _rng.nextInt(queue.length);
      } while (target == queueIndex);
    } else {
      target = queueIndex + 1;
      if (target >= queue.length) {
        if (repeat == RepeatMode.all) {
          target = 0;
        } else {
          return false;
        }
      }
    }
    await _playIndex(target);
    return true;
  }

  Future<void> previous() async {
    if (current == null) return;
    if (player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
      return;
    }
    if (_history.isNotEmpty) {
      final id = _history.removeLast();
      final i = queue.indexOf(id);
      if (i >= 0) {
        await _playIndex(i, pushHistory: false);
        return;
      }
    }
    if (!shuffle && queueIndex > 0) {
      await _playIndex(queueIndex - 1, pushHistory: false);
      return;
    }
    if (!shuffle && repeat == RepeatMode.all && queue.isNotEmpty) {
      await _playIndex(queue.length - 1, pushHistory: false);
      return;
    }
    await player.seek(Duration.zero);
  }

  Future<void> togglePlay() async {
    if (current == null) return;
    if (player.playing) {
      await player.pause();
    } else {
      unawaited(player.play());
    }
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    notifyListeners();
    unawaited(_savePrefs());
  }

  Future<void> cycleRepeat() async {
    repeat = RepeatMode.values[(repeat.index + 1) % RepeatMode.values.length];
    await player.setLoopMode(
      repeat == RepeatMode.one ? LoopMode.one : LoopMode.off,
    );
    notifyListeners();
    unawaited(_savePrefs());
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepEndsAt = null;
    if (duration != null) {
      sleepEndsAt = DateTime.now().add(duration);
      _sleepTimer = Timer(duration, () {
        player.pause();
        sleepEndsAt = null;
        _sleepTimer = null;
        notifyListeners();
        _msg('Sleep timer ended. Playback paused.');
      });
    }
    notifyListeners();
  }

  // ---- library -------------------------------------------------------------

  Future<void> importSongs(String language) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      if (result == null) return;

      final dir = await _musicDir();
      var added = 0;

      for (final picked in result.files) {
        final path = picked.path;
        if (path == null || path.isEmpty) continue;
        final original = File(path);
        if (!await original.exists()) continue;

        final id = _newId();
        final safeName = picked.name.replaceAll(
          RegExp(r'[^a-zA-Z0-9._-]'),
          '_',
        );
        final destination = File('${dir.path}/${id}_$safeName');
        await original.copy(destination.path);

        songs.add(Song(
          id: id,
          title: picked.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
          source: destination.path,
          local: true,
          language: language,
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ));
        added++;
      }

      await _saveSongs();
      notifyListeners();
      _msg(added > 0
          ? '$added song(s) imported.'
          : 'No audio files could be imported.');
    } catch (_) {
      _msg('Import failed. Please try again.');
    }
  }

  Future<void> addOnline({
    required String title,
    required String url,
    required String language,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      _msg('Please enter a valid link starting with http or https.');
      return;
    }
    songs.add(Song(
      id: _newId(),
      title: title.trim().isEmpty ? 'Online song' : title.trim(),
      source: uri.toString(),
      local: false,
      language: language,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    ));
    notifyListeners();
    await _saveSongs();
    _msg('Online song added.');
  }

  Future<void> updateSong(
    String id, {
    required String title,
    required String artist,
    required String language,
  }) async {
    final i = songs.indexWhere((s) => s.id == id);
    if (i < 0) return;
    songs[i] = songs[i].copyWith(
      title: title.trim().isEmpty ? songs[i].title : title.trim(),
      artist: artist.trim(),
      language: language,
    );
    notifyListeners();
    await _saveSongs();
  }

  Future<void> toggleFavorite(String id) async {
    final i = songs.indexWhere((s) => s.id == id);
    if (i < 0) return;
    songs[i] = songs[i].copyWith(favorite: !songs[i].favorite);
    notifyListeners();
    await _saveSongs();
  }

  Future<void> downloadSong(String id) async {
    final song = byId(id);
    if (song == null) return;
    if (song.local) {
      _msg('This song is already stored on your device.');
      return;
    }
    if (!_downloading.add(id)) {
      _msg('Already downloading this song.');
      return;
    }
    _msg('Downloading "${song.title}"...');
    try {
      final dir = await _musicDir();
      final ext = RegExp(r'\.([a-zA-Z0-9]{2,4})$')
              .firstMatch(Uri.tryParse(song.source)?.path ?? '')
              ?.group(1)
              ?.toLowerCase() ??
          'mp3';
      final path = '${dir.path}/${_newId()}_download.$ext';
      await Dio().download(song.source, path);

      final i = songs.indexWhere((s) => s.id == id);
      if (i >= 0) {
        songs[i] = songs[i].copyWith(source: path, local: true);
        notifyListeners();
        await _saveSongs();
      }
      _msg('Saved for offline listening.');
    } catch (_) {
      _msg('Download failed. The source may not allow downloads.');
    } finally {
      _downloading.remove(id);
    }
  }

  Future<void> deleteSong(String id) async {
    final song = byId(id);
    if (song == null) return;

    final qi = queue.indexOf(id);
    if (qi >= 0) {
      if (qi == queueIndex) {
        await player.stop();
        queue.clear();
        queueIndex = -1;
      } else {
        queue.removeAt(qi);
        if (qi < queueIndex) queueIndex--;
      }
    }
    _history.removeWhere((h) => h == id);
    songs.removeWhere((s) => s.id == id);
    for (final p in playlists) {
      p.songIds.remove(id);
    }

    if (song.local) {
      try {
        final file = File(song.source);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    notifyListeners();
    await _saveSongs();
    await _savePlaylists();
    _msg('Song removed from your library.');
  }

  // ---- playlists -----------------------------------------------------------

  Playlist createPlaylist(String name) {
    final playlist = Playlist(id: _newId(), name: name.trim());
    playlists.add(playlist);
    notifyListeners();
    unawaited(_savePlaylists());
    return playlist;
  }

  void renamePlaylist(String id, String name) {
    final p = playlistById(id);
    if (p == null || name.trim().isEmpty) return;
    p.name = name.trim();
    notifyListeners();
    unawaited(_savePlaylists());
  }

  void deletePlaylist(String id) {
    playlists.removeWhere((p) => p.id == id);
    notifyListeners();
    unawaited(_savePlaylists());
  }

  void addToPlaylist(String playlistId, String songId, {bool quiet = false}) {
    final p = playlistById(playlistId);
    if (p == null) return;
    if (p.songIds.contains(songId)) {
      if (!quiet) _msg('Already in "${p.name}".');
      return;
    }
    p.songIds.add(songId);
    notifyListeners();
    unawaited(_savePlaylists());
    if (!quiet) _msg('Added to "${p.name}".');
  }

  void removeFromPlaylist(String playlistId, String songId) {
    final p = playlistById(playlistId);
    if (p == null) return;
    p.songIds.remove(songId);
    notifyListeners();
    unawaited(_savePlaylists());
  }

  // ---- profile / settings --------------------------------------------------

  void setUserName(String name) {
    userName = name.trim().isEmpty ? 'Guest' : name.trim();
    notifyListeners();
    unawaited(_savePrefs());
  }

  void setDefaultLanguage(String language) {
    defaultLanguage = language;
    notifyListeners();
    unawaited(_savePrefs());
  }
}

// ---------------------------------------------------------------------------
// App + shell
// ---------------------------------------------------------------------------

class EnuApp extends StatelessWidget {
  final AppState app;

  const EnuApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Enu',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: purple,
          secondary: purple,
          surface: surface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: const CardThemeData(
          color: surface,
          margin: EdgeInsets.zero,
        ),
        dialogTheme: const DialogThemeData(backgroundColor: surface),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: surface,
        ),
        popupMenuTheme: const PopupMenuThemeData(color: surfaceHigh),
        sliderTheme: const SliderThemeData(
          activeTrackColor: purple,
          inactiveTrackColor: Colors.white24,
          thumbColor: Colors.white,
          trackHeight: 3,
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        useMaterial3: true,
      ),
      home: Shell(app: app),
    );
  }
}

class Shell extends StatefulWidget {
  final AppState app;

  const Shell({super.key, required this.app});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.onMessage = _toast;
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _openProfile() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ProfileScreen(app: app)),
      );

  void _openSettings() => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => SettingsScreen(app: app)),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Expanded(
                  child: IndexedStack(
                    index: _tab,
                    children: [
                      HomePage(
                        app: app,
                        onProfile: _openProfile,
                        onSettings: _openSettings,
                      ),
                      SearchPage(app: app),
                      LibraryPage(app: app),
                    ],
                  ),
                ),
                if (app.current != null) MiniPlayer(app: app),
              ],
            ),
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            backgroundColor: surface,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.search),
                label: 'Search',
              ),
              NavigationDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: 'Library',
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers and small widgets
// ---------------------------------------------------------------------------

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString();
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.padLeft(2, '0')}:$s' : '$m:$s';
}

String greeting(String name) {
  final hour = DateTime.now().hour;
  final base = hour < 12
      ? 'Good morning'
      : hour < 17
          ? 'Good afternoon'
          : 'Good evening';
  return name == 'Guest' ? base : '$base, $name';
}

Color artColor(String seed, {int shift = 0}) {
  final hash = seed.codeUnits.fold<int>(0, (h, c) => (h * 31 + c) & 0x7fffffff);
  final hue = ((hash + shift) % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.45, 0.32).toColor();
}

class Artwork extends StatelessWidget {
  final String seed;
  final double size;
  final double radius;

  const Artwork({
    super.key,
    required this.seed,
    required this.size,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [artColor(seed), artColor(seed, shift: 50)],
        ),
      ),
      child: Icon(Icons.music_note, color: Colors.white70, size: size * 0.45),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String title;
  final String? trailing;

  const SectionTitle(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 22, bottom: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          if (trailing != null)
            Text(trailing!, style: const TextStyle(color: Colors.white54)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  const EmptyState({
    super.key,
    required this.title,
    required this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          const Icon(Icons.music_note_outlined, size: 48, color: purple),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: const TextStyle(color: Colors.white60),
            textAlign: TextAlign.center,
          ),
          if (actionLabel != null) ...[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add),
              label: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class LanguageChips extends StatelessWidget {
  final String selected;
  final ValueChanged<String> onSelected;

  const LanguageChips({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: ['All', ...languages].map((language) {
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(language),
              selected: selected == language,
              onSelected: (_) => onSelected(language),
              selectedColor: purple,
              backgroundColor: surface,
              side: BorderSide.none,
            ),
          );
        }).toList(),
      ),
    );
  }
}

class PlayPauseButton extends StatelessWidget {
  final AppState app;
  final double size;
  final bool filled;

  const PlayPauseButton({
    super.key,
    required this.app,
    this.size = 28,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: app.player.playerStateStream,
      builder: (context, snapshot) {
        final state = snapshot.data;
        final processing = state?.processingState;
        final playing = state?.playing ?? false;
        final busy = processing == ProcessingState.loading ||
            processing == ProcessingState.buffering;
        final color = filled ? background : Colors.white;

        final Widget child = busy
            ? SizedBox(
                width: size * 0.8,
                height: size * 0.8,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: color),
              )
            : Icon(
                playing ? Icons.pause : Icons.play_arrow,
                size: size,
                color: color,
              );

        if (filled) {
          return Material(
            color: Colors.white,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => app.togglePlay(),
              child: Padding(padding: const EdgeInsets.all(14), child: child),
            ),
          );
        }
        return IconButton(onPressed: () => app.togglePlay(), icon: child);
      },
    );
  }
}

class _TextDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String hint;

  const _TextDialog({
    required this.title,
    required this.initial,
    required this.hint,
  });

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

Future<String?> askText(
  BuildContext context,
  String title, {
  String initial = '',
  String hint = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextDialog(title: title, initial: initial, hint: hint),
  );
}

Future<bool> confirm(BuildContext context, String title, String message) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<String?> pickLanguage(BuildContext context, String initial) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Language of these songs',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
          ),
          for (final language in languages)
            ListTile(
              title: Text(language),
              trailing: language == initial
                  ? const Icon(Icons.check, color: purple)
                  : null,
              onTap: () => Navigator.pop(c, language),
            ),
        ],
      ),
    ),
  );
}

class _LinkDialog extends StatefulWidget {
  final String initialLanguage;

  const _LinkDialog({required this.initialLanguage});

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final _title = TextEditingController();
  final _url = TextEditingController();
  late String _language = widget.initialLanguage;

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add from link'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(hintText: 'Song title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'Direct audio link (https://...)',
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _language,
              items: [
                for (final l in languages)
                  DropdownMenuItem(value: l, child: Text(l)),
              ],
              onChanged: (v) => setState(() => _language = v ?? _language),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'title': _title.text,
            'url': _url.text,
            'language': _language,
          }),
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _EditSongDialog extends StatefulWidget {
  final Song song;

  const _EditSongDialog({required this.song});

  @override
  State<_EditSongDialog> createState() => _EditSongDialogState();
}

class _EditSongDialogState extends State<_EditSongDialog> {
  late final TextEditingController _title =
      TextEditingController(text: widget.song.title);
  late final TextEditingController _artist =
      TextEditingController(text: widget.song.artist);
  late String _language = languages.contains(widget.song.language)
      ? widget.song.language
      : 'Other';

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit details'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(hintText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _artist,
              decoration: const InputDecoration(hintText: 'Artist / singer'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _language,
              items: [
                for (final l in languages)
                  DropdownMenuItem(value: l, child: Text(l)),
              ],
              onChanged: (v) => setState(() => _language = v ?? _language),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'title': _title.text,
            'artist': _artist.text,
            'language': _language,
          }),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

Future<void> importFlow(BuildContext context, AppState app) async {
  final language = await pickLanguage(context, app.defaultLanguage);
  if (language == null) return;
  await app.importSongs(language);
}

Future<void> linkFlow(BuildContext context, AppState app) async {
  final result = await showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _LinkDialog(initialLanguage: app.defaultLanguage),
  );
  if (result == null) return;
  await app.addOnline(
    title: result['title'] ?? '',
    url: result['url'] ?? '',
    language: result['language'] ?? 'Other',
  );
}

Future<void> editSong(BuildContext context, AppState app, Song song) async {
  final result = await showDialog<Map<String, String>>(
    context: context,
    builder: (_) => _EditSongDialog(song: song),
  );
  if (result == null) return;
  await app.updateSong(
    song.id,
    title: result['title'] ?? song.title,
    artist: result['artist'] ?? '',
    language: result['language'] ?? song.language,
  );
}

void showAddMusicSheet(BuildContext context, AppState app) {
  showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.folder_open, color: purple),
            title: const Text('Import from your phone'),
            onTap: () {
              Navigator.pop(sheet);
              importFlow(context, app);
            },
          ),
          ListTile(
            leading: const Icon(Icons.link, color: purple),
            title: const Text('Add from link'),
            onTap: () {
              Navigator.pop(sheet);
              linkFlow(context, app);
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> showAddToPlaylist(
  BuildContext context,
  AppState app,
  Song song,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: ListenableBuilder(
        listenable: app,
        builder: (_, __) => ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Add to playlist',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline, color: purple),
              title: const Text('New playlist'),
              onTap: () async {
                final name = await askText(
                  sheet,
                  'New playlist',
                  hint: 'Playlist name',
                );
                if (name == null || name.isEmpty) return;
                final playlist = app.createPlaylist(name);
                app.addToPlaylist(playlist.id, song.id);
                if (sheet.mounted) Navigator.pop(sheet);
              },
            ),
            for (final p in app.playlists)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(p.name),
                subtitle: Text('${p.songIds.length} songs'),
                trailing: p.songIds.contains(song.id)
                    ? const Icon(Icons.check, color: purple)
                    : null,
                onTap: () {
                  app.addToPlaylist(p.id, song.id);
                  Navigator.pop(sheet);
                },
              ),
          ],
        ),
      ),
    ),
  );
}

void showSleepSheet(BuildContext context, AppState app) {
  showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Sleep timer',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
            ),
          ),
          for (final minutes in [15, 30, 45, 60])
            ListTile(
              leading: const Icon(Icons.bedtime_outlined),
              title: Text('$minutes minutes'),
              onTap: () {
                app.setSleepTimer(Duration(minutes: minutes));
                Navigator.pop(sheet);
                app.onMessage?.call('Playback will pause in $minutes minutes.');
              },
            ),
          if (app.sleepEndsAt != null)
            ListTile(
              leading: const Icon(Icons.timer_off_outlined),
              title: const Text('Turn off timer'),
              onTap: () {
                app.setSleepTimer(null);
                Navigator.pop(sheet);
              },
            ),
        ],
      ),
    ),
  );
}

void showQueueSheet(BuildContext context, AppState app) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.65,
      child: ListenableBuilder(
        listenable: app,
        builder: (_, __) {
          final items = app.queue.map(app.byId).whereType<Song>().toList();
          return Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Up next',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final song = items[i];
                    final isCurrent = app.current?.id == song.id;
                    return ListTile(
                      leading: Artwork(seed: song.id, size: 42),
                      title: Text(
                        song.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: isCurrent ? purple : null),
                      ),
                      subtitle: Text(
                        song.artist.isEmpty ? song.language : song.artist,
                      ),
                      onTap: () => app.jumpTo(i),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

void openNowPlaying(BuildContext context, AppState app) {
  Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => NowPlayingScreen(app: app),
    ),
  );
}

// ---------------------------------------------------------------------------
// Song tile + card
// ---------------------------------------------------------------------------

class SongTile extends StatelessWidget {
  final AppState app;
  final Song song;
  final List<Song> queueSource;
  final int index;
  final String? playlistId;

  const SongTile({
    super.key,
    required this.app,
    required this.song,
    required this.queueSource,
    required this.index,
    this.playlistId,
  });

  @override
  Widget build(BuildContext context) {
    final isCurrent = app.current?.id == song.id;
    final subtitle = [
      if (song.artist.isNotEmpty) song.artist,
      song.language,
      if (!song.local) 'Online',
    ].join(' • ');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => app.playQueue(queueSource, index),
        leading: Stack(
          alignment: Alignment.center,
          children: [
            Artwork(seed: song.id, size: 46),
            if (isCurrent && app.player.playing)
              const Icon(Icons.equalizer, color: Colors.white),
          ],
        ),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: isCurrent ? purple : null),
        ),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: PopupMenuButton<String>(
          onSelected: (action) async {
            switch (action) {
              case 'favorite':
                await app.toggleFavorite(song.id);
              case 'playlist':
                await showAddToPlaylist(context, app, song);
              case 'edit':
                await editSong(context, app, song);
              case 'download':
                await app.downloadSong(song.id);
              case 'remove_playlist':
                app.removeFromPlaylist(playlistId!, song.id);
              case 'delete':
                final ok = await confirm(
                  context,
                  'Remove song?',
                  'This removes "${song.title}" from your library.',
                );
                if (ok) await app.deleteSong(song.id);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'favorite',
              child: Text(
                song.favorite ? 'Remove favorite' : 'Add to favorites',
              ),
            ),
            const PopupMenuItem(
              value: 'playlist',
              child: Text('Add to playlist'),
            ),
            const PopupMenuItem(value: 'edit', child: Text('Edit details')),
            if (!song.local)
              const PopupMenuItem(value: 'download', child: Text('Download')),
            if (playlistId != null)
              const PopupMenuItem(
                value: 'remove_playlist',
                child: Text('Remove from this playlist'),
              ),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Remove from library'),
            ),
          ],
        ),
      ),
    );
  }
}

class SongCard extends StatelessWidget {
  final AppState app;
  final Song song;
  final List<Song> queueSource;
  final int index;

  const SongCard({
    super.key,
    required this.app,
    required this.song,
    required this.queueSource,
    required this.index,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => app.playQueue(queueSource, index),
      child: SizedBox(
        width: 140,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Artwork(seed: song.id, size: 140, radius: 16),
            const SizedBox(height: 8),
            Text(
              song.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              song.artist.isEmpty ? song.language : song.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayShuffleRow extends StatelessWidget {
  final AppState app;
  final List<Song> songs;

  const PlayShuffleRow({super.key, required this.app, required this.songs});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: songs.isEmpty ? null : () => app.playQueue(songs, 0),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Play'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: songs.isEmpty ? null : () => app.playShuffled(songs),
            icon: const Icon(Icons.shuffle),
            label: const Text('Shuffle'),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Mini player
// ---------------------------------------------------------------------------

class MiniPlayer extends StatelessWidget {
  final AppState app;

  const MiniPlayer({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final song = app.current;
    if (song == null) return const SizedBox.shrink();

    return Material(
      color: surfaceHigh,
      child: InkWell(
        onTap: () => openNowPlaying(context, app),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 6),
              child: Row(
                children: [
                  Artwork(seed: song.id, size: 44, radius: 8),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          song.artist.isEmpty ? song.language : song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => app.toggleFavorite(song.id),
                    icon: Icon(
                      song.favorite ? Icons.favorite : Icons.favorite_border,
                      color: song.favorite ? Colors.pinkAccent : null,
                    ),
                  ),
                  PlayPauseButton(app: app),
                  IconButton(
                    onPressed: () => app.next(),
                    icon: const Icon(Icons.skip_next),
                  ),
                ],
              ),
            ),
            _ProgressLine(player: app.player),
          ],
        ),
      ),
    );
  }
}

class _ProgressLine extends StatelessWidget {
  final AudioPlayer player;

  const _ProgressLine({required this.player});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: player.durationStream,
      builder: (context, durationSnap) {
        final total = durationSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, positionSnap) {
            final position = positionSnap.data ?? Duration.zero;
            final ratio = total.inMilliseconds <= 0
                ? 0.0
                : (position.inMilliseconds / total.inMilliseconds)
                    .clamp(0.0, 1.0);
            return LinearProgressIndicator(
              value: ratio,
              minHeight: 2,
              backgroundColor: Colors.white12,
              color: purple,
            );
          },
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Now Playing
// ---------------------------------------------------------------------------

class SeekBar extends StatefulWidget {
  final AudioPlayer player;

  const SeekBar({super.key, required this.player});

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: widget.player.durationStream,
      builder: (context, durationSnap) {
        final total = durationSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: widget.player.positionStream,
          builder: (context, positionSnap) {
            final position = positionSnap.data ?? Duration.zero;
            final maxMs = max(total.inMilliseconds, 1).toDouble();
            final value =
                (_drag ?? position.inMilliseconds.toDouble()).clamp(0, maxMs);
            final shown = Duration(milliseconds: value.round());

            return Column(
              children: [
                Slider(
                  value: value.toDouble(),
                  max: maxMs,
                  onChanged: total == Duration.zero
                      ? null
                      : (v) => setState(() => _drag = v),
                  onChangeEnd: (v) async {
                    await widget.player.seek(
                      Duration(milliseconds: v.round()),
                    );
                    if (mounted) setState(() => _drag = null);
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatDuration(shown),
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        formatDuration(total),
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class NowPlayingScreen extends StatelessWidget {
  final AppState app;

  const NowPlayingScreen({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final song = app.current;
        if (song == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          });
          return const Scaffold();
        }

        final side = min(MediaQuery.of(context).size.width - 64, 340.0);
        final repeatActive = app.repeat != RepeatMode.off;

        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down, size: 32),
              onPressed: () => Navigator.pop(context),
            ),
            title: const Text('Now playing', style: TextStyle(fontSize: 15)),
            centerTitle: true,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              const SizedBox(height: 12),
              Center(child: Artwork(seed: song.id, size: side, radius: 24)),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          song.artist.isEmpty ? song.language : song.artist,
                          style: const TextStyle(color: Colors.white60),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => app.toggleFavorite(song.id),
                    icon: Icon(
                      song.favorite ? Icons.favorite : Icons.favorite_border,
                      color: song.favorite ? Colors.pinkAccent : null,
                      size: 28,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SeekBar(player: app.player),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    onPressed: app.toggleShuffle,
                    icon: Icon(
                      Icons.shuffle,
                      color: app.shuffle ? purple : Colors.white70,
                    ),
                  ),
                  IconButton(
                    iconSize: 38,
                    onPressed: () => app.previous(),
                    icon: const Icon(Icons.skip_previous),
                  ),
                  PlayPauseButton(app: app, size: 38, filled: true),
                  IconButton(
                    iconSize: 38,
                    onPressed: () => app.next(),
                    icon: const Icon(Icons.skip_next),
                  ),
                  IconButton(
                    onPressed: () => app.cycleRepeat(),
                    icon: Icon(
                      app.repeat == RepeatMode.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                      color: repeatActive ? purple : Colors.white70,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  TextButton.icon(
                    onPressed: () => showSleepSheet(context, app),
                    icon: Icon(
                      Icons.bedtime_outlined,
                      color: app.sleepEndsAt != null ? purple : Colors.white70,
                    ),
                    label: Text(
                      app.sleepEndsAt != null ? 'Timer on' : 'Sleep timer',
                      style: TextStyle(
                        color:
                            app.sleepEndsAt != null ? purple : Colors.white70,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => showAddToPlaylist(context, app, song),
                    icon: const Icon(
                      Icons.playlist_add,
                      color: Colors.white70,
                    ),
                    label: const Text(
                      'Playlist',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => showQueueSheet(context, app),
                    icon: const Icon(Icons.queue_music, color: Colors.white70),
                    label: const Text(
                      'Queue',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Home
// ---------------------------------------------------------------------------

class HomePage extends StatelessWidget {
  final AppState app;
  final VoidCallback onProfile;
  final VoidCallback onSettings;

  const HomePage({
    super.key,
    required this.app,
    required this.onProfile,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final songs = app.songs;
    final recent = sortSongs(songs, SortMode.recent);
    final favorites = songs.where((s) => s.favorite).toList();
    final mostPlayed =
        sortSongs(songs.where((s) => s.plays > 0), SortMode.plays)
            .take(5)
            .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                greeting(app.userName),
                style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Profile',
              onPressed: onProfile,
              icon: const Icon(Icons.account_circle_outlined),
            ),
            IconButton(
              tooltip: 'Settings',
              onPressed: onSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (songs.isEmpty)
          EmptyState(
            title: 'Your collection starts here',
            subtitle: 'Add worship songs from your phone to get started.',
            actionLabel: 'Add music',
            onAction: () => showAddMusicSheet(context, app),
          )
        else ...[
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                colors: [Color(0xFF493078), Color(0xFF211638)],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.favorite, color: purple, size: 30),
                const SizedBox(height: 12),
                const Text(
                  'Music for your worship',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  '${songs.length} songs in your library',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 16),
                PlayShuffleRow(app: app, songs: recent),
              ],
            ),
          ),
          SectionTitle('Recently added', trailing: '${recent.length} songs'),
          SizedBox(
            height: 210,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: min(recent.length, 10),
              separatorBuilder: (_, __) => const SizedBox(width: 12),
              itemBuilder: (_, i) => SongCard(
                app: app,
                song: recent[i],
                queueSource: recent,
                index: i,
              ),
            ),
          ),
          if (favorites.isNotEmpty) ...[
            SectionTitle('Your favorites', trailing: '${favorites.length}'),
            SizedBox(
              height: 210,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: favorites.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (_, i) => SongCard(
                  app: app,
                  song: favorites[i],
                  queueSource: favorites,
                  index: i,
                ),
              ),
            ),
          ],
          if (mostPlayed.isNotEmpty) ...[
            const SectionTitle('Most played'),
            for (var i = 0; i < mostPlayed.length; i++)
              SongTile(
                app: app,
                song: mostPlayed[i],
                queueSource: mostPlayed,
                index: i,
              ),
          ],
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

class SearchPage extends StatefulWidget {
  final AppState app;

  const SearchPage({super.key, required this.app});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  String _query = '';
  String _language = 'All';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.trim().toLowerCase();
    final results = widget.app.songs.where((s) {
      final languageOk = _language == 'All' || s.language == _language;
      final textOk = q.isEmpty ||
          s.title.toLowerCase().contains(q) ||
          s.artist.toLowerCase().contains(q);
      return languageOk && textOk;
    }).toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Search',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          onChanged: (v) => setState(() => _query = v),
          decoration: InputDecoration(
            hintText: 'Song title or artist...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      _controller.clear();
                      setState(() => _query = '');
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const SizedBox(height: 14),
        LanguageChips(
          selected: _language,
          onSelected: (l) => setState(() => _language = l),
        ),
        const SizedBox(height: 16),
        if (results.isEmpty)
          const EmptyState(
            title: 'No songs found',
            subtitle: 'Try another title, artist or language.',
          )
        else
          for (var i = 0; i < results.length; i++)
            SongTile(
              app: widget.app,
              song: results[i],
              queueSource: results,
              index: i,
            ),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

class LibraryPage extends StatefulWidget {
  final AppState app;

  const LibraryPage({super.key, required this.app});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  int _segment = 0;
  SortMode _sort = SortMode.recent;
  String _language = 'All';

  AppState get app => widget.app;

  Future<void> _newPlaylist() async {
    final name = await askText(context, 'New playlist', hint: 'Playlist name');
    if (name == null || name.isEmpty) return;
    app.createPlaylist(name);
  }

  void _openPlaylist(Playlist p) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlaylistScreen(app: app, playlistId: p.id),
      ),
    );
  }

  Widget _songList(List<Song> list, String emptyTitle, String emptySub) {
    if (list.isEmpty) {
      return EmptyState(title: emptyTitle, subtitle: emptySub);
    }
    return Column(
      children: [
        PlayShuffleRow(app: app, songs: list),
        const SizedBox(height: 14),
        for (var i = 0; i < list.length; i++)
          SongTile(app: app, song: list[i], queueSource: list, index: i),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_segment == 0) {
      final filtered = sortSongs(
        app.songs.where(
          (s) => _language == 'All' || s.language == _language,
        ),
        _sort,
      );
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LanguageChips(
            selected: _language,
            onSelected: (l) => setState(() => _language = l),
          ),
          const SizedBox(height: 14),
          if (app.songs.isEmpty)
            EmptyState(
              title: 'Your library is empty',
              subtitle: 'Add audio files from your phone to get started.',
              actionLabel: 'Add music',
              onAction: () => showAddMusicSheet(context, app),
            )
          else
            _songList(
              filtered,
              'No songs in this language',
              'Change the filter or edit a song\'s language from its menu.',
            ),
        ],
      );
    } else if (_segment == 1) {
      body = Column(
        children: [
          Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: surfaceHigh,
                child: Icon(Icons.add, color: purple),
              ),
              title: const Text('New playlist'),
              onTap: _newPlaylist,
            ),
          ),
          const SizedBox(height: 10),
          if (app.playlists.isEmpty)
            const EmptyState(
              title: 'No playlists yet',
              subtitle: 'Create one for a service, prayer time or mood.',
            )
          else
            for (final p in app.playlists)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    leading: Artwork(seed: p.id, size: 46),
                    title: Text(p.name),
                    subtitle: Text('${p.songIds.length} songs'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openPlaylist(p),
                  ),
                ),
              ),
        ],
      );
    } else {
      final favorites = sortSongs(app.songs.where((s) => s.favorite), _sort);
      body = _songList(
        favorites,
        'No favorites yet',
        'Tap the heart on any song to keep it here.',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Your Library',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
              ),
            ),
            PopupMenuButton<SortMode>(
              tooltip: 'Sort',
              icon: const Icon(Icons.sort),
              onSelected: (m) => setState(() => _sort = m),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: SortMode.recent,
                  child: Text('Recently added'),
                ),
                PopupMenuItem(value: SortMode.title, child: Text('A to Z')),
                PopupMenuItem(
                  value: SortMode.plays,
                  child: Text('Most played'),
                ),
              ],
            ),
            IconButton(
              tooltip: 'Add music',
              onPressed: () => showAddMusicSheet(context, app),
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('Songs')),
              ButtonSegment(value: 1, label: Text('Playlists')),
              ButtonSegment(value: 2, label: Text('Favorites')),
            ],
            selected: {_segment},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _segment = s.first),
          ),
        ),
        const SizedBox(height: 16),
        body,
        const SizedBox(height: 24),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Playlist screen
// ---------------------------------------------------------------------------

class PlaylistScreen extends StatelessWidget {
  final AppState app;
  final String playlistId;

  const PlaylistScreen({
    super.key,
    required this.app,
    required this.playlistId,
  });

  void _addSongs(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheet) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: ListenableBuilder(
          listenable: app,
          builder: (_, __) {
            final playlist = app.playlistById(playlistId);
            if (playlist == null) return const SizedBox.shrink();
            return Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Add songs',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
                Expanded(
                  child: app.songs.isEmpty
                      ? const Center(child: Text('Your library is empty.'))
                      : ListView(
                          children: [
                            for (final song in app.songs)
                              CheckboxListTile(
                                value: playlist.songIds.contains(song.id),
                                activeColor: purple,
                                title: Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  song.artist.isEmpty
                                      ? song.language
                                      : song.artist,
                                ),
                                onChanged: (checked) {
                                  if (checked == true) {
                                    app.addToPlaylist(
                                      playlistId,
                                      song.id,
                                      quiet: true,
                                    );
                                  } else {
                                    app.removeFromPlaylist(playlistId, song.id);
                                  }
                                },
                              ),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final playlist = app.playlistById(playlistId);
        if (playlist == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          });
          return const Scaffold();
        }
        final songs = app.songsOf(playlist);

        return Scaffold(
          appBar: AppBar(
            title: Text(playlist.name),
            actions: [
              PopupMenuButton<String>(
                onSelected: (action) async {
                  if (action == 'rename') {
                    final name = await askText(
                      context,
                      'Rename playlist',
                      initial: playlist.name,
                    );
                    if (name != null && name.isNotEmpty) {
                      app.renamePlaylist(playlist.id, name);
                    }
                  } else if (action == 'delete') {
                    final ok = await confirm(
                      context,
                      'Delete playlist?',
                      'Your songs stay in the library.',
                    );
                    if (ok) app.deletePlaylist(playlist.id);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(child: Artwork(seed: playlist.id, size: 140, radius: 20)),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  '${songs.length} songs',
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
              const SizedBox(height: 16),
              PlayShuffleRow(app: app, songs: songs),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _addSongs(context),
                icon: const Icon(Icons.add),
                label: const Text('Add songs'),
              ),
              const SizedBox(height: 16),
              if (songs.isEmpty)
                const EmptyState(
                  title: 'This playlist is empty',
                  subtitle: 'Tap "Add songs" to fill it.',
                )
              else
                for (var i = 0; i < songs.length; i++)
                  SongTile(
                    app: app,
                    song: songs[i],
                    queueSource: songs,
                    index: i,
                    playlistId: playlist.id,
                  ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Profile
// ---------------------------------------------------------------------------

class ProfileScreen extends StatelessWidget {
  final AppState app;

  const ProfileScreen({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final totalPlays = app.songs.fold<int>(0, (sum, s) => sum + s.plays);
        final favorites = app.songs.where((s) => s.favorite).length;
        final initial =
            app.userName.isEmpty ? '?' : app.userName[0].toUpperCase();

        Widget stat(IconData icon, String label, String value) => Card(
              child: ListTile(
                leading: Icon(icon, color: purple),
                title: Text(label),
                trailing: Text(
                  value,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );

        return Scaffold(
          appBar: AppBar(title: const Text('Your Profile')),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SizedBox(height: 12),
              Center(
                child: CircleAvatar(
                  radius: 44,
                  backgroundColor: surfaceHigh,
                  child: Text(
                    initial,
                    style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.bold,
                      color: purple,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  app.userName,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Center(
                child: TextButton.icon(
                  onPressed: () async {
                    final name = await askText(
                      context,
                      'Your name',
                      initial: app.userName == 'Guest' ? '' : app.userName,
                      hint: 'Enter your name',
                    );
                    if (name != null) app.setUserName(name);
                  },
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text('Edit name'),
                ),
              ),
              const SizedBox(height: 18),
              stat(Icons.music_note, 'Songs', '${app.songs.length}'),
              const SizedBox(height: 8),
              stat(Icons.favorite, 'Favorites', '$favorites'),
              const SizedBox(height: 8),
              stat(Icons.queue_music, 'Playlists', '${app.playlists.length}'),
              const SizedBox(height: 8),
              stat(Icons.play_circle_outline, 'Total plays', '$totalPlays'),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class SettingsScreen extends StatelessWidget {
  final AppState app;

  const SettingsScreen({super.key, required this.app});

  void _showInfo(BuildContext context, String title, String message) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _SettingsHeading('PLAYBACK'),
              Card(
                child: Column(
                  children: [
                    const ListTile(
                      leading: Icon(Icons.headphones),
                      title: Text('Background playback'),
                      subtitle: Text(
                        'Music keeps playing with the screen off, with controls on the lock screen and notification.',
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.bedtime_outlined),
                      title: const Text('Sleep timer'),
                      subtitle: Text(
                        app.sleepEndsAt == null
                            ? 'Off. Set it from the Now Playing screen.'
                            : 'On',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const _SettingsHeading('YOUR LIBRARY'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.language),
                      title: const Text('Default import language'),
                      subtitle: Text(app.defaultLanguage),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () async {
                        final language =
                            await pickLanguage(context, app.defaultLanguage);
                        if (language != null) app.setDefaultLanguage(language);
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.palette_outlined),
                      title: const Text('Appearance'),
                      subtitle: const Text('Dark purple'),
                      onTap: () => _showInfo(
                        context,
                        'Appearance',
                        'Enu currently uses the dark purple theme.',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const _SettingsHeading('INFORMATION'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('About Enu'),
                      onTap: () => _showInfo(
                        context,
                        'About Enu',
                        'Enu is a Christian music app for worship music and personal music libraries.',
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.description_outlined),
                      title: const Text('Terms of use'),
                      onTap: () => _showInfo(
                        context,
                        'Terms of use',
                        'Use music you own or have permission to play and download. Links you add must follow their providers\' terms.',
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.privacy_tip_outlined),
                      title: const Text('Privacy'),
                      onTap: () => _showInfo(
                        context,
                        'Privacy',
                        'Enu saves your library, playlists and preferences on your device only. Nothing is uploaded.',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Center(
                child: Text(
                  'Enu • Version 2.0.0',
                  style: TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }
}

class _SettingsHeading extends StatelessWidget {
  final String text;

  const _SettingsHeading(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: const TextStyle(
          color: purple,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}
