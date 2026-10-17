
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const purple = Color(0xFF9B78FF);
const background = Color(0xFF100D1C);
const surface = Color(0xFF1D1830);

const languages = ['All', 'Amharic', 'English', 'Other'];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EnuApp());
}

class Song {
  final String title;
  final String source;
  final bool local;
  final String language;
  final bool favorite;

  const Song({
    required this.title,
    required this.source,
    required this.local,
    this.language = 'Other',
    this.favorite = false,
  });

  Song copyWith({
    String? title,
    String? source,
    bool? local,
    String? language,
    bool? favorite,
  }) {
    return Song(
      title: title ?? this.title,
      source: source ?? this.source,
      local: local ?? this.local,
      language: language ?? this.language,
      favorite: favorite ?? this.favorite,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'source': source,
        'local': local,
        'language': language,
        'favorite': favorite,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        title: json['title'] as String? ?? 'Unknown song',
        source: json['source'] as String? ?? '',
        local: json['local'] as bool? ?? true,
        language: json['language'] as String? ?? 'Other',
        favorite: json['favorite'] as bool? ?? false,
      );
}

class EnuApp extends StatelessWidget {
  const EnuApp({super.key});

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
        ),
        cardTheme: const CardThemeData(
          color: surface,
          margin: EdgeInsets.zero,
        ),
        useMaterial3: true,
      ),
      home: const EnuHome(),
    );
  }
}

class EnuHome extends StatefulWidget {
  const EnuHome({super.key});

  @override
  State<EnuHome> createState() => _EnuHomeState();
}

class _EnuHomeState extends State<EnuHome> {
  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _search = TextEditingController();

  List<Song> _songs = [];
  int _tab = 0;
  int _currentIndex = -1;
  String _language = 'All';
  String _query = '';
  bool _favoritesOnly = false;
  bool _loading = true;

  Song? get _currentSong =>
      _currentIndex >= 0 && _currentIndex < _songs.length
          ? _songs[_currentIndex]
          : null;

  List<Song> get _visibleSongs => _songs.where((song) {
        return (_language == 'All' || song.language == _language) &&
            song.title.toLowerCase().contains(_query.toLowerCase()) &&
            (!_favoritesOnly || song.favorite);
      }).toList();

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  @override
  void dispose() {
    _search.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<Directory> _musicDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/enu_music');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> _loadSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('enu_songs') ?? [];
      final loaded = <Song>[];

      for (final entry in saved) {
        try {
          final song = Song.fromJson(
            Map<String, dynamic>.from(jsonDecode(entry) as Map),
          );
          if (song.source.isEmpty) continue;
          if (song.local && !await File(song.source).exists()) continue;
          loaded.add(song);
        } catch (_) {
          // Ignore damaged saved records.
        }
      }

      if (!mounted) return;
      setState(() {
        _songs = loaded;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _message('Could not load your music library.');
    }
  }

  Future<void> _saveSongs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      'enu_songs',
      _songs.map((song) => jsonEncode(song.toJson())).toList(),
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<void> _pickSongs() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: true,
      );
      if (result == null) return;

      final dir = await _musicDirectory();
      int added = 0;

      for (final picked in result.files) {
        final path = picked.path;
        if (path == null || path.isEmpty) continue;

        final original = File(path);
        if (!await original.exists()) continue;

        final safeName = picked.name.replaceAll(
          RegExp(r'[^a-zA-Z0-9._-]'),
          '_',
        );
        final destination = File(
          '${dir.path}/${DateTime.now().microsecondsSinceEpoch}_$safeName',
        );

        await original.copy(destination.path);

        _songs.add(
          Song(
            title: picked.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
            source: destination.path,
            local: true,
          ),
        );
        added++;
      }

      await _saveSongs();
      if (mounted) setState(() {});
      _message(added > 0
          ? '$added song(s) imported.'
          : 'No audio files could be imported.');
    } catch (_) {
      _message('Import failed. Please try again.');
    }
  }

  Future<void> _playSong(Song song) async {
    final index = _songs.indexOf(song);
    if (index < 0) return;

    try {
      if (song.local) {
        await _player.setFilePath(song.source);
      } else {
        await _player.setUrl(song.source);
      }
      if (!mounted) return;
      setState(() => _currentIndex = index);
      await _player.play();
    } catch (_) {
      _message('Could not play this song. Check the audio file.');
    }
  }

  Future<void> _togglePlayback() async {
    if (_currentSong == null) {
      if (_visibleSongs.isNotEmpty) {
        await _playSong(_visibleSongs.first);
      } else {
        _message('Import music from your phone to start listening.');
      }
    } else if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> _toggleFavorite(Song song) async {
    final i = _songs.indexOf(song);
    if (i < 0) return;
    setState(() {
      _songs[i] = song.copyWith(favorite: !song.favorite);
    });
    await _saveSongs();
  }

  Future<void> _downloadSong(Song song) async {
    if (song.local) {
      _message('This song is already stored on your device.');
      return;
    }

    try {
      final dir = await _musicDirectory();
      final path =
          '${dir.path}/${DateTime.now().microsecondsSinceEpoch}_download.mp3';
      await Dio().download(song.source, path);

      final i = _songs.indexOf(song);
      if (i < 0) return;

      setState(() {
        _songs[i] = song.copyWith(source: path, local: true);
      });
      await _saveSongs();
      _message('Song saved for offline listening.');
    } catch (_) {
      _message('Download failed. The source may not allow downloads.');
    }
  }

  Future<void> _removeSong(Song song) async {
    final i = _songs.indexOf(song);
    if (i < 0) return;

    if (_currentIndex == i) {
      await _player.stop();
      _currentIndex = -1;
    } else if (_currentIndex > i) {
      _currentIndex--;
    }

    setState(() => _songs.removeAt(i));
    await _saveSongs();
    _message('Song removed from your library.');
  }

  void _openProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ProfileScreen()),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.graphic_eq, color: purple, size: 30),
            SizedBox(width: 8),
            Text('Enu', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Profile',
            onPressed: _openProfile,
            icon: const Icon(Icons.account_circle_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: 'Show favorites only',
            onPressed: () => setState(
              () => _favoritesOnly = !_favoritesOnly,
            ),
            icon: Icon(
              _favoritesOnly ? Icons.favorite : Icons.favorite_border,
              color: _favoritesOnly ? Colors.pinkAccent : null,
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : IndexedStack(
              index: _tab,
              children: [
                _homePage(),
                _searchPage(),
                _libraryPage(),
              ],
            ),
      floatingActionButton: _tab == 2
          ? FloatingActionButton.extended(
              onPressed: _pickSongs,
              icon: const Icon(Icons.add),
              label: const Text('Import music'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (index) => setState(() => _tab = index),
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
      bottomSheet: _currentSong == null
          ? null
          : _miniPlayer(),
    );
  }

  Widget _homePage() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                colors: [Color(0xFF493078), Color(0xFF211638)],
              ),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.favorite, color: purple, size: 32),
                SizedBox(height: 14),
                Text(
                  'Music for your worship',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Keep your favorite Christian songs close.',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _languageFilters(),
          const SizedBox(height: 22),
          _heading('Your music', '${_visibleSongs.length} songs'),
          const SizedBox(height: 12),
          if (_visibleSongs.isEmpty)
            _emptyState(
              'Your collection starts here',
              'Import music from your phone to begin your worship collection.',
            )
          else
            ..._visibleSongs.map(_songTile),
          const SizedBox(height: 100),
        ],
      );

  Widget _searchPage() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Search your library',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _search,
            onChanged: (value) => setState(() => _query = value),
            decoration: InputDecoration(
              hintText: 'Search song titles...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          _languageFilters(),
          const SizedBox(height: 16),
          if (_visibleSongs.isEmpty)
            _emptyState(
              'No songs found',
              'Try another title or import music from your phone.',
            )
          else
            ..._visibleSongs.map(_songTile),
          const SizedBox(height: 100),
        ],
      );

  Widget _libraryPage() {
    final favorites = _songs.where((song) => song.favorite).length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Your Library',
          style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 18),
        Card(
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFF39285E),
              child: Icon(Icons.favorite, color: purple),
            ),
            title: const Text('Favorite songs'),
            subtitle: Text('$favorites saved favorites'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              setState(() {
                _favoritesOnly = true;
                _tab = 0;
              });
            },
          ),
        ),
        const SizedBox(height: 20),
        _heading('All songs', '${_songs.length} songs'),
        const SizedBox(height: 12),
        if (_songs.isEmpty)
          _emptyState(
            'Your library is empty',
            'Import audio files from your phone to get started.',
          )
        else
          ..._songs.map(_songTile),
        const SizedBox(height: 100),
      ],
    );
  }

  Widget _languageFilters() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: languages.map((language) {
            final selected = _language == language;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(language),
                selected: selected,
                onSelected: (_) => setState(() => _language = language),
                selectedColor: purple,
                backgroundColor: surface,
                side: BorderSide.none,
              ),
            );
          }).toList(),
        ),
      );

  Widget _heading(String title, String subtitle) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          Text(subtitle, style: const TextStyle(color: Colors.white54)),
        ],
      );

  Widget _emptyState(String title, String subtitle) => Container(
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
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _pickSongs,
              icon: const Icon(Icons.add),
              label: const Text('Import music'),
            ),
          ],
        ),
      );

  Widget _songTile(Song song) {
    final current = _currentSong == song;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: () => _playSong(song),
        leading: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: const Color(0xFF39285E),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            current && _player.playing
                ? Icons.equalizer
                : Icons.music_note,
            color: purple,
          ),
        ),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${song.language} • ${song.local ? 'On device' : 'Online source'}',
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (action) async {
            if (action == 'play') await _playSong(song);
            if (action == 'favorite') await _toggleFavorite(song);
            if (action == 'download') await _downloadSong(song);
            if (action == 'remove') await _removeSong(song);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'play', child: Text('Play')),
            PopupMenuItem(
              value: 'favorite',
              child: Text(
                song.favorite ? 'Remove favorite' : 'Add to favorites',
              ),
            ),
            if (!song.local)
              const PopupMenuItem(
                value: 'download',
                child: Text('Download'),
              ),
            const PopupMenuItem(
              value: 'remove',
              child: Text('Remove from library'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniPlayer() => SafeArea(
        child: Container(
          color: const Color(0xFF302347),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.music_note, color: purple, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _currentSong!.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: _togglePlayback,
                icon: StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, snapshot) {
                    final playing = snapshot.data?.playing ?? false;
                    return Icon(
                      playing ? Icons.pause : Icons.play_arrow,
                    );
                  },
                ),
              ),
              IconButton(
                onPressed: _currentSong == null
                    ? null
                    : () => _toggleFavorite(_currentSong!),
                icon: Icon(
                  _currentSong?.favorite == true
                      ? Icons.favorite
                      : Icons.favorite_border,
                  color: _currentSong?.favorite == true
                      ? Colors.pinkAccent
                      : null,
                ),
              ),
            ],
          ),
        ),
      );
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your Profile')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 20),
          const CircleAvatar(
            radius: 42,
            backgroundColor: Color(0xFF39285E),
            child: Icon(Icons.person_outline, size: 48, color: purple),
          ),
          const SizedBox(height: 18),
          const Center(
            child: Text(
              'Welcome to Enu',
              style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text('Guest mode', style: TextStyle(color: Colors.white60)),
          ),
          const SizedBox(height: 28),
          const Card(
            child: ListTile(
              leading: Icon(Icons.music_note, color: purple),
              title: Text('Listen as a guest'),
              subtitle: Text(
                'Import and play music from your phone without an account.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Card(
            child: ListTile(
              leading: Icon(Icons.cloud_outlined, color: purple),
              title: Text('Online music'),
              subtitle: Text(
                'Online features and account services are not connected yet.',
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Online sign-in will be added in a future update.'),
                ),
              );
            },
            icon: const Icon(Icons.login),
            label: const Text('Sign in / Create account'),
          ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _backgroundPlayback = true;
  bool _autoplay = false;
  bool _shuffle = false;
  bool _repeat = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    setState(() {
      _backgroundPlayback =
          prefs.getBool('enu_background_playback') ?? true;
      _autoplay = prefs.getBool('enu_autoplay') ?? false;
      _shuffle = prefs.getBool('enu_shuffle') ?? false;
      _repeat = prefs.getBool('enu_repeat') ?? false;
      _loaded = true;
    });
  }

  Future<void> _saveSetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  void _showInfo(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const _SettingsHeading('PLAYBACK'),
                Card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        secondary: const Icon(Icons.headphones),
                        title: const Text('Background playback'),
                        subtitle: const Text(
                          'Requires the upcoming Android audio-service setup.',
                        ),
                        value: _backgroundPlayback,
                        onChanged: (value) {
                          setState(() => _backgroundPlayback = value);
                          _saveSetting('enu_background_playback', value);
                        },
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        secondary: const Icon(Icons.play_circle_outline),
                        title: const Text('Autoplay'),
                        subtitle: const Text(
                          'Preference saved; automatic next-song playback is not connected yet.',
                        ),
                        value: _autoplay,
                        onChanged: (value) {
                          setState(() => _autoplay = value);
                          _saveSetting('enu_autoplay', value);
                        },
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        secondary: const Icon(Icons.shuffle),
                        title: const Text('Shuffle'),
                        subtitle: const Text(
                          'Preference only; shuffle playback is not connected yet.',
                        ),
                        value: _shuffle,
                        onChanged: (value) {
                          setState(() => _shuffle = value);
                          _saveSetting('enu_shuffle', value);
                        },
                      ),
                      const Divider(height: 1),
                      SwitchListTile(
                        secondary: const Icon(Icons.repeat),
                        title: const Text('Repeat'),
                        subtitle: const Text(
                          'Preference only; repeat playback is not connected yet.',
                        ),
                        value: _repeat,
                        onChanged: (value) {
                          setState(() => _repeat = value);
                          _saveSetting('enu_repeat', value);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const _SettingsHeading('YOUR APP'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.language),
                        title: const Text('Music languages'),
                        subtitle: const Text('Amharic, English and Other'),
                        onTap: () => _showInfo(
                          'Music languages',
                          'Use the language filters on Home and Search to filter songs in your library. Imported songs currently start with the language Other.',
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.palette_outlined),
                        title: const Text('Appearance'),
                        subtitle: const Text('Dark purple'),
                        onTap: () => _showInfo(
                          'Appearance',
                          'Enu currently uses the dark purple theme.',
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: const Text('Profile and account'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const ProfileScreen(),
                            ),
                          );
                        },
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
                          'About Enu',
                          'Enu is a Christian music app for worship music and personal music libraries.',
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.description_outlined),
                        title: const Text('Terms of use'),
                        onTap: () => _showInfo(
                          'Terms of use',
                          'Use music you own or have permission to play and download. Online features must follow their providers’ terms. Official terms will be published when online services are ready.',
                        ),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.privacy_tip_outlined),
                        title: const Text('Privacy'),
                        onTap: () => _showInfo(
                          'Privacy',
                          'Enu saves your library details and preferences on your device. Online account and data-handling details must be explained before online services launch.',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const Center(
                  child: Text(
                    'Enu • Version 1.0.0',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
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
