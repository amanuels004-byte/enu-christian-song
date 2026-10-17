
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const EnuApp());
}

const purple = Color(0xFF9B78FF);
const background = Color(0xFF100D1C);
const surface = Color(0xFF1D1830);
const languages = ['All', 'Amharic', 'English', 'Other'];

class Song {
  final String title;
  final String source;
  final bool local;
  String language;
  bool favorite;

  Song({
    required this.title,
    required this.source,
    required this.local,
    this.language = 'Other',
    this.favorite = false,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'source': source,
        'local': local,
        'language': language,
        'favorite': favorite,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        title: json['title'] as String,
        source: json['source'] as String,
        local: json['local'] as bool,
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
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: purple,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: background,
        appBarTheme: const AppBarTheme(
          backgroundColor: background,
          surfaceTintColor: Colors.transparent,
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
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
  final List<Song> _songs = [];

  Song? _current;
  bool _loading = false;
  bool _playing = false;
  bool _favoritesOnly = false;
  String _language = 'All';
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _loadSongs();

    _player.playerStateStream.listen((state) {
      if (mounted) setState(() => _playing = state.playing);
    });

    _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _message('Playback failed. Check the audio source.');
      },
    );
  }

  Future<void> _loadSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('enu_songs');
    if (saved == null) return;

    try {
      final items = (jsonDecode(saved) as List)
          .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
          .where((s) => !s.local || File(s.source).existsSync())
          .toList();

      if (mounted) {
        setState(() {
          _songs
            ..clear()
            ..addAll(items);
        });
      }
    } catch (_) {
      _message('Some saved song details could not be loaded.');
    }
  }

  Future<void> _saveSongs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'enu_songs',
      jsonEncode(_songs.map((s) => s.toJson()).toList()),
    );
  }

  List<Song> get _visibleSongs {
    final query = _search.text.trim().toLowerCase();

    return _songs.where((song) {
      final matchesText = song.title.toLowerCase().contains(query);
      final matchesLanguage =
          _language == 'All' || song.language == _language;
      final matchesFavorite = !_favoritesOnly || song.favorite;
      return matchesText && matchesLanguage && matchesFavorite;
    }).toList();
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

      int added = 0;
      for (final file in result.files) {
        final path = file.path;
        if (path == null || _songs.any((s) => s.source == path)) continue;

        _songs.add(Song(
          title: file.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
          source: path,
          local: true,
        ));
        added++;
      }

      await _saveSongs();
      if (mounted) setState(() {});
      _message('$added song(s) imported. You can assign a language when adding online songs.');
    } catch (e) {
      _message('Could not import audio: $e');
    }
  }

  Future<void> _addOnlineSong() async {
    final titleController = TextEditingController();
    final urlController = TextEditingController();
    String selectedLanguage = 'Amharic';

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: const Text('Add an audio link'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: 'Song title',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Direct audio URL',
                    hintText: 'https://example.com/song.mp3',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: selectedLanguage,
                  decoration: const InputDecoration(labelText: 'Language'),
                  items: languages
                      .where((language) => language != 'All')
                      .map((language) => DropdownMenuItem(
                            value: language,
                            child: Text(language),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      updateDialog(() => selectedLanguage = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                const Text(
                  'Use a direct audio link you have permission to play or download. A video page URL usually is not a direct audio URL.',
                  style: TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Add song'),
            ),
          ],
        ),
      ),
    );

    if (result != true) return;

    final title = titleController.text.trim();
    final url = urlController.text.trim();
    final uri = Uri.tryParse(url);

    if (title.isEmpty ||
        uri == null ||
        !uri.hasScheme ||
        !(uri.scheme == 'https' || uri.scheme == 'http') ||
        uri.host.isEmpty) {
      _message('Enter a title and a valid HTTP(S) audio URL.');
      return;
    }

    if (_songs.any((s) => s.source == url)) {
      _message('That audio link is already in your library.');
      return;
    }

    setState(() {
      _songs.add(Song(
        title: title,
        source: url,
        local: false,
        language: selectedLanguage,
      ));
    });

    await _saveSongs();
    _message('Added to your library. Playback depends on the audio source.');
  }

  Future<void> _playSong(Song song) async {
    setState(() {
      _loading = true;
      _current = song;
    });

    try {
      if (song.local) {
        await _player.setFilePath(song.source);
      } else {
        await _player.setUrl(song.source);
      }
      await _player.play();
    } catch (_) {
      _message('Could not play this audio. The link may not be a direct audio file.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _togglePlayback() async {
    if (_current == null) {
      if (_visibleSongs.isNotEmpty) {
        await _playSong(_visibleSongs.first);
      } else {
        _message('Import a song or add a direct audio link first.');
      }
      return;
    }

    try {
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
    } catch (_) {
      _message('Playback could not start.');
    }
  }

  Future<void> _toggleFavorite(Song song) async {
    setState(() => song.favorite = !song.favorite);
    await _saveSongs();
  }

  Future<void> _downloadSong(Song song) async {
    if (song.local) {
      _message('This song is already stored locally.');
      return;
    }

    setState(() => _loading = true);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final safeName = song.title
          .replaceAll(RegExp(r'[^\w\- ]'), '_')
          .trim()
          .replaceAll(' ', '_');
      final path =
          '${dir.path}/$safeName-${DateTime.now().millisecondsSinceEpoch}.audio';

      await Dio().download(
        song.source,
        path,
        options: Options(
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 5),
        ),
      );

      _songs.add(Song(
        title: song.title,
        source: path,
        local: true,
        language: song.language,
        favorite: song.favorite,
      ));
      await _saveSongs();
      if (mounted) setState(() {});
      _message('Saved for offline listening.');
    } catch (_) {
      _message('Download failed. This source may block downloads.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeSong(Song song) async {
    if (_current == song) {
      await _player.stop();
      setState(() => _current = null);
    }

    setState(() => _songs.remove(song));
    await _saveSongs();
  }

  String _duration(Duration? duration) {
    if (duration == null) return '--:--';
    final m = duration.inMinutes;
    final s = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _player.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleSongs;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.graphic_eq, color: purple, size: 30),
            SizedBox(width: 8),
            Text(
              'Enu',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 26),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Show favorites only',
            onPressed: () => setState(() => _favoritesOnly = !_favoritesOnly),
            icon: Icon(
              _favoritesOnly ? Icons.favorite : Icons.favorite_border,
              color: _favoritesOnly ? Colors.pinkAccent : null,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  _home(visible),
                  _searchPage(visible),
                  _libraryPage(visible),
                ],
              ),
            ),
            if (_current != null) _miniPlayer(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        backgroundColor: const Color(0xFF181326),
        indicatorColor: const Color(0xFF39285E),
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
      floatingActionButton: _tab == 2
          ? FloatingActionButton.extended(
              onPressed: _pickSongs,
              icon: const Icon(Icons.add),
              label: const Text('Import music'),
            )
          : FloatingActionButton(
              onPressed: _addOnlineSong,
              tooltip: 'Add a direct audio link',
              child: const Icon(Icons.add_link),
            ),
    );
  }

  Widget _home(List<Song> visible) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: const LinearGradient(
              colors: [Color(0xFF7146C8), Color(0xFF302047), background],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.favorite, color: Colors.white, size: 28),
              SizedBox(height: 16),
              Text(
                'Praise in every moment',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 8),
              Text(
                'A place for your worship, wherever you go.',
                style: TextStyle(color: Colors.white70),
              ),
              SizedBox(height: 12),
              Text(
                'AMHARIC  •  ENGLISH  •  WORSHIP',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Explore by language',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: languages.map((language) {
            return ChoiceChip(
              label: Text(language),
              selected: _language == language,
              onSelected: (_) => setState(() => _language = language),
              selectedColor: purple,
            );
          }).toList(),
        ),
        const SizedBox(height: 26),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Your music',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            Text('${visible.length} songs',
                style: const TextStyle(color: Colors.white60)),
          ],
        ),
        const SizedBox(height: 10),
        if (visible.isEmpty)
          _emptyState(
            _favoritesOnly
                ? 'No favorites in this selection'
                : 'Your worship collection starts here',
            'Import music from your phone or add a permitted direct audio link.',
            Icons.music_note_rounded,
          )
        else
          ...visible.take(6).map(_songTile),
        if (visible.length > 6)
          TextButton(
            onPressed: () => setState(() => _tab = 2),
            child: const Text('See all songs'),
          ),
      ],
    );
  }

  Widget _searchPage(List<Song> visible) {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text(
          'Find your worship',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        const Text(
          'Search songs saved in your library.',
          style: TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 18),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search song titles...',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              onPressed: () {
                _search.clear();
                setState(() {});
              },
              icon: const Icon(Icons.close),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          children: languages.map((language) {
            return ChoiceChip(
              label: Text(language),
              selected: _language == language,
              onSelected: (_) => setState(() => _language = language),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        if (visible.isEmpty)
          _emptyState(
            'No matching songs',
            'Try another title or language, or add music to your library.',
            Icons.search_off,
          )
        else
          ...visible.map(_songTile),
      ],
    );
  }

  Widget _libraryPage(List<Song> visible) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 100),
      children: [
        const Text(
          'Your library',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        Text(
          '${_songs.length} saved songs',
          style: const TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              label: const Text('All songs'),
              selected: !_favoritesOnly,
              onSelected: (_) => setState(() => _favoritesOnly = false),
            ),
            FilterChip(
              label: const Text('Favorites'),
              selected: _favoritesOnly,
              onSelected: (_) => setState(() => _favoritesOnly = true),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (visible.isEmpty)
          _emptyState(
            'Your library is waiting',
            'Import audio or add a direct audio link to get started.',
            Icons.library_music,
          )
        else
          ...visible.map(_songTile),
      ],
    );
  }

  Widget _emptyState(String title, String subtitle, IconData icon) {
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        children: [
          Icon(icon, color: purple, size: 54),
          const SizedBox(height: 14),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _pickSongs,
            icon: const Icon(Icons.folder_open),
            label: const Text('Import songs'),
          ),
        ],
      ),
    );
  }

  Widget _songTile(Song song) {
    final isCurrent = _current == song;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isCurrent ? const Color(0xFF302349) : surface,
      child: ListTile(
        onTap: () => _playSong(song),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF45316B),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            isCurrent && _playing
                ? Icons.equalizer
                : song.local
                    ? Icons.music_note
                    : Icons.cloud_outlined,
            color: purple,
          ),
        ),
        title: Text(
          song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text('${song.language} • ${song.local ? 'Offline' : 'Online audio'}'),
        trailing: PopupMenuButton<String>(
          onSelected: (value) {
            if (value == 'favorite') _toggleFavorite(song);
            if (value == 'download') _downloadSong(song);
            if (value == 'remove') _removeSong(song);
            if (value == 'play') _playSong(song);
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'play',
              child: Text('Play song'),
            ),
            PopupMenuItem(
              value: 'favorite',
              child: Text(song.favorite ? 'Remove favorite' : 'Add to favorites'),
            ),
            if (!song.local)
              const PopupMenuItem(
                value: 'download',
                child: Text('Download for offline'),
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

  Widget _miniPlayer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: const BoxDecoration(
        color: Color(0xFF211A32),
        border: Border(top: BorderSide(color: Color(0xFF423456))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<Duration?>(
            stream: _player.durationStream,
            builder: (context, durationSnapshot) {
              final duration = durationSnapshot.data;
              return StreamBuilder<Duration>(
                stream: _player.positionStream,
                builder: (context, positionSnapshot) {
                  final position = positionSnapshot.data ?? Duration.zero;
                  final maxMs = duration?.inMilliseconds ?? 1;
                  final value =
                      position.inMilliseconds.clamp(0, maxMs).toDouble();

                  return Column(
                    children: [
                      Slider(
                        value: value,
                        max: maxMs.toDouble(),
                        onChanged: duration == null
                            ? null
                            : (v) => _player.seek(
                                  Duration(milliseconds: v.round()),
                                ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_duration(position),
                              style: const TextStyle(fontSize: 11)),
                          Text(_duration(duration),
                              style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                    ],
                  );
                },
              );
            },
          ),
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFF45316B),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.album, color: purple),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _current!.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${_current!.language} • ${_current!.local ? 'Offline' : 'Online'}',
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => _toggleFavorite(_current!),
                icon: Icon(
                  _current!.favorite ? Icons.favorite : Icons.favorite_border,
                  color: _current!.favorite ? Colors.pinkAccent : null,
                ),
              ),
              IconButton(
                onPressed: _loading ? null : _togglePlayback,
                icon: _loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(_playing ? Icons.pause_circle : Icons.play_circle,
                        size: 34),
              ),
              IconButton(
                tooltip: 'Next song',
                onPressed: () async {
                  final i = _songs.indexOf(_current!);
                  if (i >= 0 && i < _songs.length - 1) {
                    await _playSong(_songs[i + 1]);
                  }
                },
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
