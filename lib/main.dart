import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const purple = Color(0xFF8050D5);
const kBg = Color(0xFF130F1B);
const kSurface = Color(0xFF191323);
const cardBorder = Color(0xFF30243E);
const muted = Color(0xFF9A90A8);

const audioExts = ['.mp3', '.m4a', '.aac', '.wav', '.flac', '.ogg', '.opus'];

class Song {
  final String path, title, folder;
  Song(this.path, this.title, this.folder);

  factory Song.fromPath(String p) {
    final parts = p.split('/');
    final file = parts.last;
    final dot = file.lastIndexOf('.');
    final title = dot > 0 ? file.substring(0, dot) : file;
    final folder = parts.length > 1 ? parts[parts.length - 2] : '';
    return Song(p, title, folder);
  }
}

class AppState extends ChangeNotifier {
  final player = AudioPlayer();
  late SharedPreferences prefs;

  List<Song> songs = [];
  List<Song> queue = [];
  Song? current;
  bool scanning = false;
  bool permissionDenied = false;
  Set<String> favorites = {};
  List<String> recents = [];
  List<Map<String, dynamic>> notes = [];
  String name = 'Friend';
  bool shuffleDefault = false;
  int played = 0;

  int get unread => notes.where((n) => n['read'] != true).length;

  Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    name = prefs.getString('name') ?? 'Friend';
    favorites = (prefs.getStringList('favs') ?? []).toSet();
    recents = prefs.getStringList('recents') ?? [];
    shuffleDefault = prefs.getBool('shuffle') ?? false;
    played = prefs.getInt('played') ?? 0;
    notes = (prefs.getStringList('notes') ?? [])
        .map((e) => jsonDecode(e) as Map<String, dynamic>)
        .toList();
    songs = (prefs.getStringList('songs') ?? [])
        .where((p) => File(p).existsSync())
        .map(Song.fromPath)
        .toList();

    player.currentIndexStream.listen((i) {
      if (i != null && i < queue.length) {
        current = queue[i];
        _addRecent(current!.path);
        played++;
        prefs.setInt('played', played);
        notifyListeners();
      }
    });

    if (notes.isEmpty) {
      addNote('Welcome to Enu', 'Your music works offline. Songs are read straight from your phone.');
    }
    notifyListeners();
    scan();
  }

  void _addRecent(String p) {
    recents.remove(p);
    recents.insert(0, p);
    if (recents.length > 30) recents = recents.sublist(0, 30);
    prefs.setStringList('recents', recents);
  }

  void addNote(String title, String body) {
    notes.insert(0, {
      'title': title,
      'body': body,
      'time': DateTime.now().toIso8601String(),
      'read': false,
    });
    if (notes.length > 50) notes = notes.sublist(0, 50);
    _saveNotes();
  }

  void _saveNotes() =>
      prefs.setStringList('notes', notes.map(jsonEncode).toList());

  void markNotesRead() {
    for (final n in notes) {
      n['read'] = true;
    }
    _saveNotes();
    notifyListeners();
  }

  void clearNotes() {
    notes.clear();
    _saveNotes();
    notifyListeners();
  }

  Future<bool> _ensurePermission() async {
    if (await Permission.audio.request().isGranted) {
      Permission.notification.request();
      return true;
    }
    final ok = await Permission.storage.request().isGranted;
    if (ok) Permission.notification.request();
    return ok;
  }

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    permissionDenied = false;
    notifyListeners();

    if (!await _ensurePermission()) {
      scanning = false;
      permissionDenied = true;
      notifyListeners();
      return;
    }

    final found = <Song>[];
    await _walk(Directory('/storage/emulated/0'), found, 0);
    found.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    songs = found;
    prefs.setStringList('songs', found.map((s) => s.path).toList());
    scanning = false;
    addNote('Library updated', 'Found ${found.length} songs on your phone.');
    notifyListeners();
  }

  Future<void> _walk(Directory dir, List<Song> out, int depth) async {
    if (depth > 8) return;
    try {
      await for (final e in dir.list(followLinks: false)) {
        final base = e.path.split('/').last;
        if (base.startsWith('.')) continue;
        if (e is Directory) {
          if (e.path == '/storage/emulated/0/Android') continue;
          await _walk(e, out, depth + 1);
        } else if (e is File) {
          final lower = e.path.toLowerCase();
          if (audioExts.any(lower.endsWith)) out.add(Song.fromPath(e.path));
        }
      }
    } catch (_) {}
  }

  Future<void> playQueue(List<Song> list, int index, {bool? shuffle}) async {
    if (list.isEmpty) return;
    queue = list;
    final source = ConcatenatingAudioSource(
      children: list
          .map((s) => AudioSource.file(
                s.path,
                tag: MediaItem(id: s.path, title: s.title, album: s.folder, artist: 'Enu'),
              ))
          .toList(),
    );
    try {
      await player.setAudioSource(source, initialIndex: index);
      await player.setShuffleModeEnabled(shuffle ?? shuffleDefault);
      player.play();
    } catch (_) {}
  }

  void shuffleAll() {
    if (songs.isEmpty) return;
    playQueue(songs, DateTime.now().millisecond % songs.length, shuffle: true);
  }

  bool isFav(Song s) => favorites.contains(s.path);

  void toggleFav(Song s) {
    isFav(s) ? favorites.remove(s.path) : favorites.add(s.path);
    prefs.setStringList('favs', favorites.toList());
    notifyListeners();
  }

  List<Song> get favSongs => songs.where(isFav).toList();

  List<Song> get recentSongs {
    final map = {for (final s in songs) s.path: s};
    return recents.map((p) => map[p]).whereType<Song>().toList();
  }

  void setName(String n) {
    name = n.trim().isEmpty ? 'Friend' : n.trim();
    prefs.setString('name', name);
    notifyListeners();
  }

  void setShuffleDefault(bool v) {
    shuffleDefault = v;
    prefs.setBool('shuffle', v);
    notifyListeners();
  }

  void clearRecents() {
    recents.clear();
    prefs.setStringList('recents', []);
    notifyListeners();
  }

  void clearFavorites() {
    favorites.clear();
    prefs.setStringList('favs', []);
    notifyListeners();
  }
}

final app = AppState();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.enu.app.audio',
    androidNotificationChannelName: 'Enu playback',
    androidNotificationOngoing: true,
  );
  await app.init();
  runApp(const EnuApp());
}

class EnuApp extends StatelessWidget {
  const EnuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Enu',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: purple, surface: kSurface),
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: kSurface,
          indicatorColor: purple.withValues(alpha: .25),
        ),
      ),
      home: const EnuShell(),
    );
  }
}

String fmt(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return d.inHours > 0 ? '${d.inHours}:$m:$s' : '${d.inMinutes}:$s';
}

void toast(BuildContext c, String msg) {
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg)));
}

// ───────────────────────── Shell ─────────────────────────

class EnuShell extends StatefulWidget {
  const EnuShell({super.key});

  @override
  State<EnuShell> createState() => _EnuShellState();
}

class _EnuShellState extends State<EnuShell> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final pages = [
          HomePage(goLibrary: () => setState(() => tab = 1)),
          const LibraryPage(),
          const ProfilePage(),
        ];
        return Scaffold(
          appBar: AppBar(
            title: const Text('Enu', style: TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              IconButton(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const NotificationsPage())),
                icon: Badge(
                  isLabelVisible: app.unread > 0,
                  label: Text('${app.unread}'),
                  child: const Icon(Icons.notifications_rounded),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const SettingsPage())),
                icon: const Icon(Icons.settings_rounded),
              ),
            ],
          ),
          body: pages[tab],
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (app.current != null) const MiniPlayer(),
              NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: (i) => setState(() => tab = i),
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'),
                  NavigationDestination(
                      icon: Icon(Icons.library_music_rounded), label: 'Library'),
                  NavigationDestination(icon: Icon(Icons.person_rounded), label: 'Profile'),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────── Home ─────────────────────────

class HomePage extends StatelessWidget {
  final VoidCallback goLibrary;
  const HomePage({super.key, required this.goLibrary});

  @override
  Widget build(BuildContext context) {
    final recent = app.recentSongs;
    final cards = [
      _Card('Favorites', '${app.favSongs.length} songs', Icons.favorite_rounded, () {
        final f = app.favSongs;
        f.isEmpty ? toast(context, 'No favorites yet. Tap the heart on a song.') : app.playQueue(f, 0);
      }),
      _Card('Recently played', '${recent.length} songs', Icons.history_rounded, () {
        recent.isEmpty ? toast(context, 'Nothing played yet.') : app.playQueue(recent, 0);
      }),
      _Card('All songs', '${app.songs.length} on your phone', Icons.library_music_rounded,
          goLibrary),
      _Card('Shuffle all', 'Surprise me', Icons.shuffle_rounded, () {
        app.songs.isEmpty ? toast(context, 'No songs found yet.') : app.shuffleAll();
      }),
    ];

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
      children: [
        Text('Hello, ${app.name}',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        const Text('Your music, available offline.', style: TextStyle(color: muted)),
        const SizedBox(height: 18),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 14,
          crossAxisSpacing: 14,
          childAspectRatio: 1.25,
          children: cards.map((c) => _tile(c)).toList(),
        ),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 24),
          const Text('Jump back in',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          for (var i = 0; i < recent.length && i < 5; i++)
            SongTile(song: recent[i], queue: recent, index: i),
        ],
      ],
    );
  }

  Widget _tile(_Card c) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: c.onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF21172F), Color(0xFF130F1B)],
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 43,
              height: 43,
              decoration: BoxDecoration(
                color: purple.withValues(alpha: .17),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(c.icon, color: purple, size: 23),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                const SizedBox(height: 4),
                Text(c.subtitle, style: const TextStyle(color: muted, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Card {
  final String title, subtitle;
  final IconData icon;
  final VoidCallback onTap;
  _Card(this.title, this.subtitle, this.icon, this.onTap);
}

// ───────────────────────── Library ─────────────────────────

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    if (app.permissionDenied) {
      return _message(
        Icons.lock_rounded,
        'Enu needs access to your audio files to show your music.',
        [
          FilledButton(onPressed: app.scan, child: const Text('Allow access')),
          TextButton(onPressed: openAppSettings, child: const Text('Open app settings')),
        ],
      );
    }
    if (app.scanning && app.songs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (app.songs.isEmpty) {
      return _message(Icons.music_off_rounded, 'No songs found on your phone.',
          [FilledButton(onPressed: app.scan, child: const Text('Scan again'))]);
    }

    final list = app.songs
        .where((s) => s.title.toLowerCase().contains(query.toLowerCase()))
        .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
          child: TextField(
            onChanged: (v) => setState(() => query = v),
            decoration: InputDecoration(
              hintText: 'Search ${app.songs.length} songs',
              prefixIcon: const Icon(Icons.search_rounded),
              filled: true,
              fillColor: kSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (app.scanning) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: RefreshIndicator(
            onRefresh: app.scan,
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (c, i) => SongTile(song: list[i], queue: list, index: i),
            ),
          ),
        ),
      ],
    );
  }

  Widget _message(IconData icon, String text, List<Widget> actions) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 54, color: purple),
            const SizedBox(height: 14),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(color: muted)),
            const SizedBox(height: 14),
            ...actions,
          ],
        ),
      ),
    );
  }
}

class SongTile extends StatelessWidget {
  final Song song;
  final List<Song> queue;
  final int index;
  const SongTile({super.key, required this.song, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    final playing = app.current?.path == song.path;
    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: purple.withValues(alpha: playing ? .35 : .15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(playing ? Icons.equalizer_rounded : Icons.music_note_rounded,
            color: purple),
      ),
      title: Text(song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontWeight: FontWeight.w600, color: playing ? purple : Colors.white)),
      subtitle: Text(song.folder,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: muted)),
      trailing: IconButton(
        icon: Icon(app.isFav(song) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: app.isFav(song) ? purple : muted),
        onPressed: () => app.toggleFav(song),
      ),
      onTap: () => app.playQueue(queue, index),
    );
  }
}

// ───────────────────────── Mini player ─────────────────────────

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final s = app.current!;
    return InkWell(
      onTap: () => Navigator.push(
          context, MaterialPageRoute(builder: (_) => const NowPlayingPage())),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
        decoration: const BoxDecoration(
          color: Color(0xFF211830),
          border: Border(top: BorderSide(color: cardBorder)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(
                    colors: [Color(0xFF8050D5), Color(0xFF302044)]),
              ),
              child: const Icon(Icons.music_note_rounded),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  Text(s.folder,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 11)),
                ],
              ),
            ),
            StreamBuilder<bool>(
              stream: app.player.playingStream,
              builder: (c, snap) {
                final playing = snap.data ?? false;
                return IconButton(
                  onPressed: () => playing ? app.player.pause() : app.player.play(),
                  icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                      color: purple, size: 34),
                );
              },
            ),
            IconButton(
              onPressed: () => app.player.seekToNext(),
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Now playing ─────────────────────────

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final s = app.current;
        if (s == null) return const Scaffold(body: SizedBox());
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30),
              onPressed: () => Navigator.pop(context),
            ),
            title: const Text('Now playing'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                Container(
                  width: 240,
                  height: 240,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(32),
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF8050D5), Color(0xFF302044)],
                    ),
                  ),
                  child: const Icon(Icons.music_note_rounded, size: 96),
                ),
                const Spacer(),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(s.folder, style: const TextStyle(color: muted)),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => app.toggleFav(s),
                      icon: Icon(
                          app.isFav(s)
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: purple),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                StreamBuilder<Duration>(
                  stream: app.player.positionStream,
                  builder: (c, snap) {
                    final pos = snap.data ?? Duration.zero;
                    final dur = app.player.duration ?? Duration.zero;
                    final max = dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;
                    final v = pos.inMilliseconds.toDouble().clamp(0.0, max);
                    return Column(
                      children: [
                        Slider(
                          value: v,
                          max: max,
                          onChanged: dur.inMilliseconds > 0
                              ? (x) => app.player.seek(Duration(milliseconds: x.toInt()))
                              : null,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(fmt(pos), style: const TextStyle(color: muted)),
                              Text(fmt(dur), style: const TextStyle(color: muted)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    StreamBuilder<bool>(
                      stream: app.player.shuffleModeEnabledStream,
                      builder: (c, snap) {
                        final on = snap.data ?? false;
                        return IconButton(
                          onPressed: () => app.player.setShuffleModeEnabled(!on),
                          icon: Icon(Icons.shuffle_rounded, color: on ? purple : muted),
                        );
                      },
                    ),
                    IconButton(
                      iconSize: 38,
                      onPressed: () => app.player.seekToPrevious(),
                      icon: const Icon(Icons.skip_previous_rounded),
                    ),
                    StreamBuilder<bool>(
                      stream: app.player.playingStream,
                      builder: (c, snap) {
                        final playing = snap.data ?? false;
                        return IconButton(
                          iconSize: 66,
                          color: purple,
                          onPressed: () => playing ? app.player.pause() : app.player.play(),
                          icon: Icon(playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_fill),
                        );
                      },
                    ),
                    IconButton(
                      iconSize: 38,
                      onPressed: () => app.player.seekToNext(),
                      icon: const Icon(Icons.skip_next_rounded),
                    ),
                    StreamBuilder<LoopMode>(
                      stream: app.player.loopModeStream,
                      builder: (c, snap) {
                        final m = snap.data ?? LoopMode.off;
                        return IconButton(
                          onPressed: () => app.player.setLoopMode(
                              LoopMode.values[(m.index + 1) % LoopMode.values.length]),
                          icon: Icon(
                              m == LoopMode.one
                                  ? Icons.repeat_one_rounded
                                  : Icons.repeat_rounded,
                              color: m == LoopMode.off ? muted : purple),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ───────────────────────── Profile ─────────────────────────

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  Future<void> _edit(BuildContext context) async {
    final ctrl = TextEditingController(text: app.name);
    final res = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (res != null) app.setName(res);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
          child: CircleAvatar(
            radius: 46,
            backgroundColor: purple.withValues(alpha: .3),
            child: Text(app.name.characters.first.toUpperCase(),
                style: const TextStyle(fontSize: 38, fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(app.name,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ),
        Center(
          child: TextButton.icon(
            onPressed: () => _edit(context),
            icon: const Icon(Icons.edit_rounded, size: 16),
            label: const Text('Edit name'),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            _stat('Songs', '${app.songs.length}'),
            _stat('Favorites', '${app.favorites.length}'),
            _stat('Plays', '${app.played}'),
          ],
        ),
      ],
    );
  }

  Widget _stat(String label, String value) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 5),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cardBorder),
        ),
        child: Column(
          children: [
            Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Notifications ─────────────────────────

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => app.markNotesRead());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
          actions: [
            if (app.notes.isNotEmpty)
              IconButton(
                  onPressed: app.clearNotes, icon: const Icon(Icons.delete_sweep_rounded)),
          ],
        ),
        body: app.notes.isEmpty
            ? const Center(child: Text('Nothing here yet.', style: TextStyle(color: muted)))
            : ListView.builder(
                itemCount: app.notes.length,
                itemBuilder: (c, i) {
                  final n = app.notes[i];
                  final t = DateTime.tryParse(n['time'] ?? '');
                  return ListTile(
                    leading: const Icon(Icons.notifications_rounded, color: purple),
                    title: Text(n['title'] ?? ''),
                    subtitle: Text(n['body'] ?? ''),
                    trailing: t == null
                        ? null
                        : Text(
                            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(color: muted, fontSize: 12)),
                  );
                },
              ),
      ),
    );
  }
}

// ───────────────────────── Settings ─────────────────────────

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: ListView(
          children: [
            SwitchListTile(
              activeThumbColor: purple,
              secondary: const Icon(Icons.shuffle_rounded),
              title: const Text('Shuffle by default'),
              subtitle: const Text('Start new queues in shuffle mode'),
              value: app.shuffleDefault,
              onChanged: app.setShuffleDefault,
            ),
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('Rescan music'),
              subtitle: Text('${app.songs.length} songs found'),
              onTap: () {
                app.scan();
                toast(context, 'Scanning your phone…');
              },
            ),
            ListTile(
              leading: const Icon(Icons.history_rounded),
              title: const Text('Clear recently played'),
              onTap: () {
                app.clearRecents();
                toast(context, 'Recently played cleared');
              },
            ),
            ListTile(
              leading: const Icon(Icons.heart_broken_rounded),
              title: const Text('Clear favorites'),
              onTap: () {
                app.clearFavorites();
                toast(context, 'Favorites cleared');
              },
            ),
            ListTile(
              leading: const Icon(Icons.lock_open_rounded),
              title: const Text('App permissions'),
              onTap: openAppSettings,
            ),
            const ListTile(
              leading: Icon(Icons.info_outline_rounded),
              title: Text('Enu'),
              subtitle: Text('Version 1.0.0 • Works fully offline'),
            ),
          ],
        ),
      ),
    );
  }
}
