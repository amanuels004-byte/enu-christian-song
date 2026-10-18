import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SelamApp());
}

enum Lang { amharic, english }

class Song {
  final String id, title, artist;
  final Lang lang;
  final String? path;
  const Song({required this.id, required this.title, required this.artist, required this.lang, this.path});
  bool get isLocal => path != null && path!.isNotEmpty;
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'artist': artist, 'lang': lang.name, 'path': path};
  factory Song.fromJson(Map<String, dynamic> j) => Song(
    id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    title: j['title'] as String? ?? 'Unknown song', artist: j['artist'] as String? ?? 'Unknown artist',
    lang: Lang.values.firstWhere((x) => x.name == j['lang'], orElse: () => Lang.english), path: j['path'] as String?);
}

class LocalUser {
  String name;
  final String email;
  final String password;
  LocalUser(this.name, this.email, this.password);
  Map<String, dynamic> toJson() => {'name': name, 'email': email, 'password': password};
  factory LocalUser.fromJson(Map<String, dynamic> j) => LocalUser(j['name'] as String? ?? 'Listener', j['email'] as String, j['password'] as String? ?? '');
}

class SelamState extends ChangeNotifier {
  static const _usersKey = 'selam_users_v1', _activeKey = 'selam_active_v1', _songsKey = 'selam_songs_v1', _favsKey = 'selam_favs_v1', _themeKey = 'selam_dark_v1', _filterKey = 'selam_filter_v1', _recentKey = 'selam_recent_v1';
  final AudioPlayer player = AudioPlayer();
  final Map<String, LocalUser> _users = {};
  final List<Song> songs = [];
  final Set<String> favoriteIds = {};
  final List<String> recentIds = [];
  LocalUser? user;
  ThemeMode themeMode = ThemeMode.dark;
  Lang? filter;
  Song? current;
  bool loading = true;
  String? message;
  StreamSubscription<PlayerState>? _playerSub;
  StreamSubscription<Duration?>? _durationSub;

  bool get playing => player.playing;
  Duration get position => player.position;
  Duration get duration => player.duration ?? Duration.zero;
  List<Song> get visible => songs.where((s) => filter == null || s.lang == filter).toList();
  List<Song> get favorites => songs.where((s) => favoriteIds.contains(s.id)).toList();
  List<Song> get recents => recentIds.map((id) => songs.where((s) => s.id == id).firstOrNull).whereType<Song>().toList();

  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      final rawUsers = p.getString(_usersKey);
      if (rawUsers != null) for (final x in jsonDecode(rawUsers) as List) { final u = LocalUser.fromJson(Map<String, dynamic>.from(x as Map)); _users[u.email] = u; }
      final rawSongs = p.getString(_songsKey);
      if (rawSongs != null) for (final x in jsonDecode(rawSongs) as List) { final s = Song.fromJson(Map<String, dynamic>.from(x as Map)); if (!s.isLocal || File(s.path!).existsSync()) songs.add(s); }
      favoriteIds.addAll(p.getStringList(_favsKey) ?? const []);
      recentIds.addAll(p.getStringList(_recentKey) ?? const []);
      themeMode = p.getBool(_themeKey) == false ? ThemeMode.light : ThemeMode.dark;
      final f = p.getString(_filterKey);
      filter = f == null ? null : Lang.values.where((x) => x.name == f).firstOrNull;
      final active = p.getString(_activeKey);
      if (active != null) user = _users[active];
      _playerSub = player.playerStateStream.listen((_) => notifyListeners());
      _durationSub = player.durationStream.listen((_) => notifyListeners());
    } catch (_) {
      message = 'Some saved data could not be loaded. You can continue using the app.';
    } finally { loading = false; notifyListeners(); }
  }

  Future<void> _saveUsers() async { final p = await SharedPreferences.getInstance(); await p.setString(_usersKey, jsonEncode(_users.values.map((u) => u.toJson()).toList())); }
  Future<void> _saveSongs() async { final p = await SharedPreferences.getInstance(); await p.setString(_songsKey, jsonEncode(songs.map((s) => s.toJson()).toList())); }
  Future<void> _saveActive() async { final p = await SharedPreferences.getInstance(); if (user == null) { await p.remove(_activeKey); } else { await p.setString(_activeKey, user!.email); } }

  String? signUp(String name, String email, String password) {
    final e = email.trim().toLowerCase();
    if (name.trim().isEmpty) return 'Enter your name.';
    if (!e.contains('@') || !e.contains('.')) return 'Enter a valid email.';
    if (password.length < 6) return 'Password must be at least 6 characters.';
    if (_users.containsKey(e)) return 'An account with this email already exists.';
    user = LocalUser(name.trim(), e, password); _users[e] = user!;
    unawaited(_saveUsers()); unawaited(_saveActive()); notifyListeners(); return null;
  }
  String? logIn(String email, String password) {
    final u = _users[email.trim().toLowerCase()];
    if (u == null || u.password != password) return 'Wrong email or password.';
    user = u; unawaited(_saveActive()); notifyListeners(); return null;
  }
  Future<void> logOut() async { await stop(); user = null; await _saveActive(); notifyListeners(); }
  Future<void> deleteAccount() async { if (user != null) _users.remove(user!.email); await logOut(); await _saveUsers(); }
  void setName(String name) { if (user == null || name.trim().isEmpty) return; user!.name = name.trim(); unawaited(_saveUsers()); notifyListeners(); }
  void setTheme(bool dark) { themeMode = dark ? ThemeMode.dark : ThemeMode.light; SharedPreferences.getInstance().then((p) => p.setBool(_themeKey, dark)); notifyListeners(); }
  void setFilter(Lang? l) { filter = l; SharedPreferences.getInstance().then((p) { if (l == null) { p.remove(_filterKey); } else { p.setString(_filterKey, l.name); } }); notifyListeners(); }
  void toggleFavorite(Song s) { if (!favoriteIds.add(s.id)) favoriteIds.remove(s.id); SharedPreferences.getInstance().then((p) => p.setStringList(_favsKey, favoriteIds.toList())); notifyListeners(); }

  Future<void> importAudio() async {
    try {
      final picked = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true);
      if (picked == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final musicDir = Directory('${dir.path}/selam_music');
      if (!await musicDir.exists()) await musicDir.create(recursive: true);
      for (final item in picked.files) {
        final src = item.path;
        if (src == null) continue;
        final safe = item.name.replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '_');
        final dest = File('${musicDir.path}/${DateTime.now().microsecondsSinceEpoch}_$safe');
        await File(src).copy(dest.path);
        final title = item.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
        songs.add(Song(id: DateTime.now().microsecondsSinceEpoch.toString(), title: title.isEmpty ? 'Unknown song' : title, artist: 'Local music', lang: Lang.english, path: dest.path));
      }
      await _saveSongs(); message = null; notifyListeners();
    } catch (_) { message = 'Could not import the selected audio file.'; notifyListeners(); }
  }
  Future<void> play(Song s) async {
    if (!s.isLocal) { message = 'Import an audio file from your phone to play real music.'; notifyListeners(); return; }
    try {
      message = null; current = s; notifyListeners();
      await player.setFilePath(s.path!); await player.play();
      recentIds.remove(s.id); recentIds.insert(0, s.id); if (recentIds.length > 30) recentIds.removeRange(30, recentIds.length);
      final p = await SharedPreferences.getInstance(); await p.setStringList(_recentKey, recentIds); notifyListeners();
    } catch (_) { message = 'Unable to play this file. Import it again or try another audio format.'; notifyListeners(); }
  }
  Future<void> togglePlayback() async { try { if (player.processingState == ProcessingState.completed) { await player.seek(Duration.zero); await player.play(); } else if (player.playing) { await player.pause(); } else if (current != null) { await player.play(); } } catch (_) { message = 'Playback could not start.'; notifyListeners(); } }
  Future<void> next() async { final list = visible.where((s) => s.isLocal).toList(); if (list.isEmpty) return; final i = current == null ? -1 : list.indexWhere((s) => s.id == current!.id); await play(list[(i + 1) % list.length]); }
  Future<void> previous() async { if (position > const Duration(seconds: 3)) { await player.seek(Duration.zero); return; } final list = visible.where((s) => s.isLocal).toList(); if (list.isEmpty) return; final i = current == null ? 0 : list.indexWhere((s) => s.id == current!.id); await play(list[(i <= 0 ? list.length : i) - 1]); }
  Future<void> seek(Duration d) => player.seek(d);
  Future<void> stop() async { await player.stop(); current = null; message = null; notifyListeners(); }
  Future<void> removeSong(Song s) async { songs.removeWhere((x) => x.id == s.id); favoriteIds.remove(s.id); recentIds.remove(s.id); if (current?.id == s.id) await stop(); if (s.isLocal) { try { final f = File(s.path!); if (await f.exists()) await f.delete(); } catch (_) {} } await _saveSongs(); final p = await SharedPreferences.getInstance(); await p.setStringList(_favsKey, favoriteIds.toList()); await p.setStringList(_recentKey, recentIds); notifyListeners(); }
  @override
  Future<void> dispose() async { await _playerSub?.cancel(); await _durationSub?.cancel(); await player.dispose(); super.dispose(); }
}

extension FirstOrNull<T> on Iterable<T> { T? get firstOrNull { final i = iterator; return i.moveNext() ? i.current : null; } }
final app = SelamState();

class SelamApp extends StatefulWidget { const SelamApp({super.key}); @override State<SelamApp> createState() => _SelamAppState(); }
class _SelamAppState extends State<SelamApp> { @override void initState() { super.initState(); unawaited(app.init()); } @override Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (_, __) => MaterialApp(title: 'Selam Worship', debugShowCheckedModeBanner: false, themeMode: app.themeMode, theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFFD4A017), brightness: Brightness.light), darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFFD4A017), brightness: Brightness.dark), home: app.loading ? const Scaffold(body: Center(child: CircularProgressIndicator())) : app.user == null ? const AuthScreen() : const HomeShell())); }

class AuthScreen extends StatefulWidget { const AuthScreen({super.key}); @override State<AuthScreen> createState() => _AuthScreenState(); }
class _AuthScreenState extends State<AuthScreen> {
  final form = GlobalKey<FormState>(); final name = TextEditingController(), email = TextEditingController(), pass = TextEditingController(); bool login = true, hide = true; String? error;
  @override void dispose() { name.dispose(); email.dispose(); pass.dispose(); super.dispose(); }
  void submit() { if (!form.currentState!.validate()) return; final e = login ? app.logIn(email.text, pass.text) : app.signUp(name.text, email.text, pass.text); setState(() => error = e); }
  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme; return Scaffold(body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Form(key: form, child: Column(children: [Icon(Icons.church, size: 68, color: cs.primary), const SizedBox(height: 10), Text('Selam Worship', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)), Text('አማርኛ & English worship music'), const SizedBox(height: 28), if (!login) ...[TextFormField(controller: name, decoration: const InputDecoration(labelText: 'Full name', prefixIcon: Icon(Icons.person), border: OutlineInputBorder()), validator: (v) => v == null || v.trim().isEmpty ? 'Enter your name' : null), const SizedBox(height: 12)], TextFormField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email), border: OutlineInputBorder()), validator: (v) => v == null || !v.contains('@') ? 'Enter a valid email' : null), const SizedBox(height: 12), TextFormField(controller: pass, obscureText: hide, decoration: InputDecoration(labelText: 'Password', prefixIcon: const Icon(Icons.lock), border: const OutlineInputBorder(), suffixIcon: IconButton(icon: Icon(hide ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => hide = !hide))), validator: (v) => v == null || v.length < 6 ? 'Use at least 6 characters' : null), if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: cs.error))), const SizedBox(height: 20), SizedBox(width: double.infinity, height: 48, child: FilledButton(onPressed: submit, child: Text(login ? 'Log in' : 'Create account'))), TextButton(onPressed: () => setState(() { login = !login; error = null; }), child: Text(login ? "Don't have an account? Sign up" : 'Already have an account? Log in')), const SizedBox(height: 8), Text('Local demo account only. Do not reuse an important password.', style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center)]))))); }
}

class HomeShell extends StatefulWidget { const HomeShell({super.key}); @override State<HomeShell> createState() => _HomeShellState(); }
class _HomeShellState extends State<HomeShell> { int index = 0; @override Widget build(BuildContext context) { final pages = [const HomePage(), const SearchPage(), const LibraryPage(), const SettingsPage()]; return Scaffold(body: SafeArea(child: IndexedStack(index: index, children: pages)), bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [const MiniPlayer(), NavigationBar(selectedIndex: index, onDestinationSelected: (i) => setState(() => index = i), destinations: const [NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'), NavigationDestination(icon: Icon(Icons.search), label: 'Search'), NavigationDestination(icon: Icon(Icons.favorite_outline), label: 'Library'), NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings')])])); } }

class HomePage extends StatelessWidget { const HomePage({super.key}); @override Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (_, __) => ListView(padding: const EdgeInsets.all(16), children: [Text('Welcome, ${app.user!.name.split(' ').first} 🙏', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 12), FilledButton.icon(onPressed: app.importAudio, icon: const Icon(Icons.library_music), label: const Text('Import music from phone')), const SizedBox(height: 12), Wrap(spacing: 8, children: [ChoiceChip(label: const Text('All'), selected: app.filter == null, onSelected: (_) => app.setFilter(null)), ChoiceChip(label: const Text('አማርኛ'), selected: app.filter == Lang.amharic, onSelected: (_) => app.setFilter(Lang.amharic)), ChoiceChip(label: const Text('English'), selected: app.filter == Lang.english, onSelected: (_) => app.setFilter(Lang.english))]), if (app.message != null) ErrorMessage(app.message!), if (app.visible.isEmpty) const EmptyMessage('Your library is empty', 'Import audio files from your phone to start listening.'), for (final s in app.visible) SongTile(song: s)])); }

class SearchPage extends StatefulWidget { const SearchPage({super.key}); @override State<SearchPage> createState() => _SearchPageState(); }
class _SearchPageState extends State<SearchPage> { String q = ''; @override Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (_, __) { final found = app.visible.where((s) => s.title.toLowerCase().contains(q.toLowerCase()) || s.artist.toLowerCase().contains(q.toLowerCase())).toList(); return ListView(padding: const EdgeInsets.all(16), children: [TextField(onChanged: (v) => setState(() => q = v), decoration: const InputDecoration(hintText: 'Search song or artist / ዘፈን ፈልግ', prefixIcon: Icon(Icons.search), border: OutlineInputBorder())), const SizedBox(height: 12), if (found.isEmpty) const EmptyMessage('No songs found', 'Import music or try another search.'), for (final s in found) SongTile(song: s)]); }); }

class LibraryPage extends StatelessWidget { const LibraryPage({super.key}); @override Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (_, __) => ListView(padding: const EdgeInsets.all(16), children: [Text('Your Library', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 12), Text('Favorites', style: Theme.of(context).textTheme.titleMedium), if (app.favorites.isEmpty) const EmptyMessage('No favorites yet', 'Tap the heart beside a song to save it.'), for (final s in app.favorites) SongTile(song: s), const Divider(height: 28), Text('Recently played', style: Theme.of(context).textTheme.titleMedium), for (final s in app.recents) SongTile(song: s), const Divider(height: 28), Text('Imported songs', style: Theme.of(context).textTheme.titleMedium), for (final s in app.songs) SongTile(song: s, removable: true)])); }

class SettingsPage extends StatelessWidget { const SettingsPage({super.key});
  Future<void> editName(BuildContext context) async { final c = TextEditingController(text: app.user!.name); final result = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('Edit name'), content: TextField(controller: c), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Save'))])); c.dispose(); if (result != null && result.isNotEmpty) app.setName(result); }
  Future<void> deleteAccount(BuildContext context) async { final yes = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('Delete account?'), content: const Text('This deletes the local demo account. Imported songs remain.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete'))])); if (yes == true) await app.deleteAccount(); }
  @override Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (_, __) => ListView(children: [const Padding(padding: EdgeInsets.all(16), child: Text('Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))), ListTile(leading: const CircleAvatar(child: Icon(Icons.person)), title: Text(app.user!.name), subtitle: Text(app.user!.email), trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => editName(context))), const Divider(), SwitchListTile(secondary: const Icon(Icons.dark_mode), title: const Text('Dark mode'), value: app.themeMode == ThemeMode.dark, onChanged: app.setTheme), ListTile(leading: const Icon(Icons.language), title: const Text('Music language'), trailing: DropdownButton<Lang?>(value: app.filter, underline: const SizedBox(), items: const [DropdownMenuItem<Lang?>(value: null, child: Text('Both')), DropdownMenuItem<Lang?>(value: Lang.amharic, child: Text('አማርኛ')), DropdownMenuItem<Lang?>(value: Lang.english, child: Text('English'))], onChanged: app.setFilter)), const ListTile(leading: Icon(Icons.info_outline), title: Text('About Selam Worship'), subtitle: Text('Version 1.1 • Local music player')), const ListTile(leading: Icon(Icons.privacy_tip_outlined), title: Text('Privacy'), subtitle: Text('This demo stores account details on this device.')), ListTile(leading: const Icon(Icons.logout), title: const Text('Log out'), onTap: app.logOut), ListTile(leading: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error), title: const Text('Delete account'), onTap: () => deleteAccount(context))])); }

class SongTile extends StatelessWidget { final Song song; final bool removable; const SongTile({super.key, required this.song, this.removable = false}); @override Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (_, __) { final active = app.current?.id == song.id; final fav = app.favoriteIds.contains(song.id); return ListTile(leading: CircleAvatar(child: Icon(active && app.playing ? Icons.graphic_eq : Icons.music_note)), title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text('${song.artist} • ${song.lang == Lang.amharic ? 'አማርኛ' : 'English'}'), trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: fav ? Colors.redAccent : null), onPressed: () => app.toggleFavorite(song)), if (removable) IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => app.removeSong(song))]), onTap: () => app.play(song)); }); }

class MiniPlayer extends StatelessWidget { const MiniPlayer({super.key}); @override Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (_, __) { final s = app.current; if (s == null) return const SizedBox.shrink(); final d = app.duration.inMilliseconds; final v = d <= 0 ? 0.0 : (app.position.inMilliseconds / d).clamp(0.0, 1.0); return Material(color: Theme.of(context).colorScheme.surfaceContainerHighest, child: Column(mainAxisSize: MainAxisSize.min, children: [LinearProgressIndicator(value: v, minHeight: 2), ListTile(dense: true, leading: const Icon(Icons.music_note), title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(s.artist), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlayerPage())), trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: Icon(app.playing ? Icons.pause : Icons.play_arrow), onPressed: app.togglePlayback), IconButton(icon: const Icon(Icons.skip_next), onPressed: app.next)]))])); }); }

class PlayerPage extends StatelessWidget { const PlayerPage({super.key}); @override Widget build(BuildContext context) => ListenableBuilder(listenable: app, builder: (_, __) { final s = app.current; if (s == null) return const Scaffold(body: Center(child: Text('No song selected'))); final d = app.duration; final max = d.inMilliseconds > 0 ? d.inMilliseconds.toDouble() : 1.0; final value = app.position.inMilliseconds.toDouble().clamp(0.0, max); return Scaffold(appBar: AppBar(title: const Text('Now Playing')), body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [Expanded(child: Center(child: AspectRatio(aspectRatio: 1, child: Container(decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(24)), child: Icon(Icons.church, size: 100, color: Theme.of(context).colorScheme.primary))))), Text(s.title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center), Text(s.artist), Slider(value: value, max: max, onChanged: d == Duration.zero ? null : (v) => app.seek(Duration(milliseconds: v.toInt()))), Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(fmt(app.position.inSeconds)), Text(fmt(d.inSeconds))]), if (app.message != null) ErrorMessage(app.message!), const SizedBox(height: 8), Row(mainAxisAlignment: MainAxisAlignment.center, children: [IconButton(iconSize: 40, icon: const Icon(Icons.skip_previous), onPressed: app.previous), const SizedBox(width: 16), IconButton.filled(iconSize: 48, icon: Icon(app.playing ? Icons.pause : Icons.play_arrow), onPressed: app.togglePlayback), const SizedBox(width: 16), IconButton(iconSize: 40, icon: const Icon(Icons.skip_next), onPressed: app.next)]), const SizedBox(height: 20)])))); }); }

class EmptyMessage extends StatelessWidget { final String title, subtitle; const EmptyMessage(this.title, this.subtitle, {super.key}); @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.all(24), child: Column(children: [const Icon(Icons.music_note, size: 42), const SizedBox(height: 8), Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center), Text(subtitle, textAlign: TextAlign.center)])); }
class ErrorMessage extends StatelessWidget { final String text; const ErrorMessage(this.text, {super.key}); @override Widget build(BuildContext context) => Container(margin: const EdgeInsets.symmetric(vertical: 8), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Theme.of(context).colorScheme.errorContainer, borderRadius: BorderRadius.circular(10)), child: Text(text, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer))); }
String fmt(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
