
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

class Song {
  final String title;
  final String source;
  final bool local;
  bool favorite;

  Song({
    required this.title,
    required this.source,
    required this.local,
    this.favorite = false,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'source': source,
        'local': local,
        'favorite': favorite,
      };

  factory Song.fromJson(Map<String, dynamic> json) => Song(
        title: json['title'] as String,
        source: json['source'] as String,
        local: json['local'] as bool,
        favorite: json['favorite'] as bool? ?? false,
      );
}

class EnuApp extends StatelessWidget {
  const EnuApp({super.key});

  @override
  Widget build(BuildContext context) {
    const purple = Color(0xFF9B78FF);

    return MaterialApp(
      title: 'Enu',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: purple,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF100D1C),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF100D1C),
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
  final List<Song> _songs = [];

  Song? _current;
  bool _loading = false;
  bool _playing = false;
  bool _favoritesOnly = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _loadSongs();

    _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _playing = state.playing;
        });
      }
    });

    _player.playbackEventStream.listen(
      (_) {},
      onError: (Object error, StackTrace stack) {
        if (mounted) {
          setState(() => _message = 'Playback error: $error');
        }
      },
    );
  }

  Future<void> _loadSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('enu_songs');

    if (saved != null) {
      try {
        final items = (jsonDecode(saved) as List)
            .map((e) => Song.fromJson(Map<String, dynamic>.from(e)))
            .where((song) => song.local
                ? File(song.source).existsSync()
                : true)
            .toList();

        if (mounted) {
          setState(() => _songs.addAll(items));
        }
      } catch (_) {}
    }
  }

  Future<void> _saveSongs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'enu_songs',
      jsonEncode(_songs.map((song) => song.toJson()).toList()),
    );
  }

  List<Song> get _visibleSongs {
    final query = _search.text.trim().toLowerCase();

    return _songs.where((song) {
      final matches = song.title.toLowerCase().contains(query);
      return matches && (!_favoritesOnly || song.favorite);
    }).toList();
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
        if (path == null) continue;

        if (_songs.any((s) => s.source == path)) continue;

        _songs.add(Song(
          title: file.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
          source: path,
          local: true,
        ));
        added++;
      }

      await _saveSongs();
      if (mounted) {
        setState(() => _message = '$added song(s) added');
      }
    } catch (e) {
      _showMessage('Could not import audio: $e');
    }
  }

  Future<void> _addOnlineSong() async {
    final titleController = TextEditingController();
    final urlController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add online song'),
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
              const SizedBox(height: 8),
              const Text(
                'Use an audio link you have permission to play.',
                style: TextStyle(fontSize: 12, color: Colors.white60),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add song'),
          ),
        ],
      ),
    );

    if (result != true) return;

    final title = titleController.text.trim();
    final url = urlController.text.trim();

    if (title.isEmpty || Uri.tryParse(url)?.hasScheme != true ||
        !(url.startsWith('https://') || url.startsWith('http://'))) {
      _showMessage('Enter a title and a valid HTTP(S) audio URL.');
      return;
    }

    if (_songs.any((s) => s.source == url)) {
      _showMessage('That song is already in your library.');
      return;
    }

    setState(() {
      _songs.add(Song(title: title, source: url, local: false));
    });

    await _saveSongs();
    _showMessage('Song added to your library.');
  }

  Future<void> _playSong(Song song) async {
    setState(() {
      _loading = true;
      _message = null;
      _current = song;
    });

    try {
      if (song.local) {
        await _player.setFilePath(song.source);
      } else {
        await _player.setUrl(song.source);
      }

      await _player.play();
    } catch (e) {
      _showMessage('Could not play this song. Check the file or audio URL.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _togglePlayback() async {
    if (_current == null) {
      if (_songs.isNotEmpty) {
        await _playSong(_songs.first);
      } else {
        _showMessage('Add an audio file or online song first.');
      }
      return;
    }

    try {
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
    } catch (e) {
      _showMessage('Playback failed: $e');
    }
  }

  Future<void> _toggleFavorite(Song song) async {
    setState(() => song.favorite = !song.favorite);
    await _saveSongs();
  }

  Future<void> _downloadSong(Song song) async {
    if (song.local) {
      _showMessage('This song is already stored as a local file.');
      return;
    }

    setState(() {
      _loading = true;
      _message = 'Downloading ${song.title}…';
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      final safeName = song.title
          .replaceAll(RegExp(r'[^\w\- ]'), '_')
          .trim()
          .replaceAll(' ', '_');

      final path = '${dir.path}/$safeName-${DateTime.now().millisecondsSinceEpoch}.mp3';

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
        favorite: song.favorite,
      ));

      await _saveSongs();
      _showMessage('Downloaded for offline listening!');
    } catch (e) {
      _showMessage('Download failed. The source may block downloads.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _removeSong(Song song) async {
    if (_current == song) {
      await _player.stop();
      _current = null;
    }

    setState(() => _songs.remove(song));
    await _saveSongs();
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
    setState(() => _message = message);
  }

  String _formatDuration(Duration? duration) {
    if (duration == null) return '--:--';
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
            Icon(Icons.graphic_eq, color: Color(0xFFB69AFF), size: 30),
            SizedBox(width: 8),
            Text(
              'Enu',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 26),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Favorites only',
            onPressed: () => setState(() => _favoritesOnly = !_favoritesOnly),
            icon: Icon(
              _favoritesOnly ? Icons.favorite : Icons.favorite_border,
              color: _favoritesOnly ? Colors.pinkAccent : null,
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addOnlineSong,
        icon: const Icon(Icons.link),
        label: const Text('Add online song'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6741B8), Color(0xFF292044)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.favorite, color: Colors.white70, size: 28),
                    SizedBox(height: 14),
                    Text(
                      'Praise in every moment',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text('Your worship music, wherever you go.'),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search your songs…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    onPressed: () {
                      _search.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.close),
                  ),
                  filled: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Your music',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text('${visible.length} songs'),
                  IconButton(
                    tooltip: 'Import audio from phone',
                    onPressed: _pickSongs,
                    icon: const Icon(Icons.library_add),
                  ),
                ],
              ),
            ),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.music_note,
                              size: 58,
                              color: Color(0xFF9B78FF),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _favoritesOnly
                                  ? 'No favorite songs yet'
                                  : 'Your music starts here',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Import audio from your phone, or add an online audio link.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white60),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _pickSongs,
                              icon: const Icon(Icons.folder_open),
                              label: const Text('Import songs'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final song = visible[index];
                        final isCurrent = _current == song;

                        return Card(
                          color: isCurrent
                              ? const Color(0xFF2C2146)
                              : const Color(0xFF1A1627),
                          child: ListTile(
                            onTap: () => _playSong(song),
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF6741B8),
                              child: Icon(
                                isCurrent && _playing
                                    ? Icons.equalizer
                                    : song.local
                                        ? Icons.music_note
                                        : Icons.cloud_outlined,
                              ),
                            ),
                            title: Text(
                              song.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              song.local ? 'Available offline' : 'Online audio',
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (value) {
                                if (value == 'favorite') {
                                  _toggleFavorite(song);
                                } else if (value == 'download') {
                                  _downloadSong(song);
                                } else if (value == 'remove') {
                                  _removeSong(song);
                                } else if (value == 'play') {
                                  _playSong(song);
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'play',
                                  child: Text('Play song'),
                                ),
                                PopupMenuItem(
                                  value: 'favorite',
                                  child: Text(song.favorite
                                      ? 'Remove favorite'
                                      : 'Add to favorites'),
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
                      },
                    ),
            ),
            if (_current != null)
              Container(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
                decoration: const BoxDecoration(
                  color: Color(0xFF211A32),
                  border: Border(
                    top: BorderSide(color: Color(0xFF423456)),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.album,
                          size: 40,
                          color: Color(0xFFB69AFF),
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
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                _current!.local ? 'Offline song' : 'Online song',
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
                            _current!.favorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: _current!.favorite
                                ? Colors.pinkAccent
                                : null,
                          ),
                        ),
                      ],
                    ),
                    StreamBuilder<Duration?>(
                      stream: _player.durationStream,
                      builder: (context, snapshot) {
                        final duration = snapshot.data;
                        return StreamBuilder<Duration>(
                          stream: _player.positionStream,
                          builder: (context, positionSnapshot) {
                            final position =
                                positionSnapshot.data ?? Duration.zero;
                            final maxMs = duration?.inMilliseconds ?? 1;
                            final value = position.inMilliseconds
                                .clamp(0, maxMs)
                                .toDouble();

                            return Column(
                              children: [
                                Slider(
                                  value: value,
                                  max: maxMs.toDouble(),
                                  onChanged: duration == null
                                      ? null
                                      : (v) => _player.seek(
                                            Duration(
                                              milliseconds: v.round(),
                                            ),
                                          ),
                                ),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(_formatDuration(position),
                                        style: const TextStyle(fontSize: 11)),
                                    Text(_formatDuration(duration),
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
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          onPressed: () async {
                            final i = _songs.indexOf(_current!);
                            if (i > 0) await _playSong(_songs[i - 1]);
                          },
                          icon: const Icon(Icons.skip_previous, size: 32),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _loading ? null : _togglePlayback,
                          style: FilledButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: const EdgeInsets.all(16),
                          ),
                          child: _loading
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  _playing ? Icons.pause : Icons.play_arrow,
                                  size: 32,
                                ),
                        ),
                        const SizedBox(width: 12),
                        IconButton(
                          onPressed: () async {
                            final i = _songs.indexOf(_current!);
                            if (i >= 0 && i < _songs.length - 1) {
                              await _playSong(_songs[i + 1]);
                            }
                          },
                          icon: const Icon(Icons.skip_next, size: 32),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (_message != null && _current == null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _message!,
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
