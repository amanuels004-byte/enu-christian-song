import 'dart:async';
import 'package:flutter/material.dart';

void main() => runApp(const SelamApp());

// ───────────── MODELS ─────────────
enum Lang { amharic, english }

class Song {
  final String title, artist;
  final Lang lang;
  final int seconds;
  const Song(this.title, this.artist, this.lang, this.seconds);
}

class AppUser {
  String name;
  final String email, password;
  AppUser(this.name, this.email, this.password);
}

// Placeholder songs. Replace with your own list or backend later.
const songs = <Song>[
  Song('እግዚአብሔር ታላቅ ነው', 'Sample Artist', Lang.amharic, 215),
  Song('ምስጋና ለአንተ', 'Sample Artist', Lang.amharic, 198),
  Song('ኢየሱስ ጌታዬ', 'Sample Artist', Lang.amharic, 240),
  Song('አንተ ብቻ', 'Sample Artist', Lang.amharic, 187),
  Song('Amazing Grace', 'Sample Choir', Lang.english, 230),
  Song('How Great Is Our God', 'Sample Artist', Lang.english, 205),
  Song('Be Still My Soul', 'Sample Artist', Lang.english, 192),
  Song('Great Is Thy Faithfulness', 'Sample Choir', Lang.english, 250),
];

String fmt(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

// ───────────── APP STATE ─────────────
class AppState extends ChangeNotifier {
  final Map<String, AppUser> _users = {};
  AppUser? user;
  ThemeMode themeMode = ThemeMode.dark;
  Lang? filter; // null = both languages
  final Set<Song> favorites = {};
  Song? current;
  bool playing = false;
  int position = 0;
  Timer? _timer;

  List<Song> get visible =>
      filter == null ? songs : songs.where((s) => s.lang == filter).toList();

  // Auth (local only, in memory)
  String? signUp(String name, String email, String pass) {
    final e = email.trim().toLowerCase();
    if (_users.containsKey(e)) return 'An account with this email already exists';
    user = _users[e] = AppUser(name.trim(), e, pass);
    notifyListeners();
    return null;
  }

  String? logIn(String email, String pass) {
    final u = _users[email.trim().toLowerCase()];
    if (u == null || u.password != pass) return 'Wrong email or password';
    user = u;
    notifyListeners();
    return null;
  }

  void logOut() {
    _timer?.cancel();
    current = null;
    playing = false;
    user = null;
    notifyListeners();
  }

  void deleteAccount() {
    _users.remove(user?.email);
    logOut();
  }

  void setName(String n) {
    user?.name = n.trim();
    notifyListeners();
  }

  // Settings
  void setTheme(ThemeMode m) {
    themeMode = m;
    notifyListeners();
  }

  void setFilter(Lang? l) {
    filter = l;
    notifyListeners();
  }

  void toggleFav(Song s) {
    favorites.contains(s) ? favorites.remove(s) : favorites.add(s);
    notifyListeners();
  }

  // Player (simulated, see notes below the code)
  void play(Song s) {
    current = s;
    position = 0;
    playing = true;
    _startTimer();
    notifyListeners();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (current == null) return;
      if (position >= current!.seconds - 1) {
        next();
      } else {
        position++;
        notifyListeners();
      }
    });
  }

  void toggle() {
    if (current == null) return;
    playing = !playing;
    playing ? _startTimer() : _timer?.cancel();
    notifyListeners();
  }

  void next() {
    final l = visible;
    if (l.isEmpty) return;
    final i = current == null ? -1 : l.indexOf(current!);
    play(l[(i + 1) % l.length]);
  }

  void prev() {
    final l = visible;
    if (l.isEmpty || current == null) return;
    if (position > 3) {
      position = 0;
      notifyListeners();
      return;
    }
    final i = l.indexOf(current!);
    play(l[(i - 1 + l.length) % l.length]);
  }

  void seek(int s) {
    position = s;
    notifyListeners();
  }
}

final app = AppState();

// ───────────── ROOT ─────────────
class SelamApp extends StatelessWidget {
  const SelamApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) => MaterialApp(
        title: 'Selam Worship',
        debugShowCheckedModeBanner: false,
        themeMode: app.themeMode,
        theme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFFD4A017),
            brightness: Brightness.light),
        darkTheme: ThemeData(
            useMaterial3: true,
            colorSchemeSeed: const Color(0xFFD4A017),
            brightness: Brightness.dark),
        home: app.user == null ? const AuthScreen() : const HomeShell(),
      ),
    );
  }
}

// ───────────── AUTH ─────────────
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  bool isLogin = true, hide = true;
  String? error;

  void submit() {
    if (!_form.currentState!.validate()) return;
    final err = isLogin
        ? app.logIn(_email.text, _pass.text)
        : app.signUp(_name.text, _email.text, _pass.text);
    if (err != null) setState(() => error = err);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _form,
                child: Column(children: [
                  Icon(Icons.church, size: 64, color: cs.primary),
                  const SizedBox(height: 8),
                  Text('Selam Worship',
                      style: Theme.of(context)
                          .textTheme
                          .headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  Text('አማርኛ & English worship music',
                      style: TextStyle(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 32),
                  if (!isLogin) ...[
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(
                          labelText: 'Full name',
                          prefixIcon: Icon(Icons.person),
                          border: OutlineInputBorder()),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Enter your name' : null,
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.email),
                        border: OutlineInputBorder()),
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Enter a valid email'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass,
                    obscureText: hide,
                    decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(hide ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => hide = !hide),
                        )),
                    validator: (v) => (v == null || v.length < 6)
                        ? 'At least 6 characters'
                        : null,
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(error!, style: TextStyle(color: cs.error)),
                    ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                        onPressed: submit,
                        child: Text(isLogin ? 'Log in' : 'Create account')),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      isLogin = !isLogin;
                      error = null;
                    }),
                    child: Text(isLogin
                        ? "Don't have an account? Sign up"
                        : 'Already have an account? Log in'),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────── HOME SHELL ─────────────
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;
  final pages = const [HomePage(), SearchPage(), LibraryPage(), SettingsPage()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: pages[index]),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        const MiniPlayer(),
        NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => setState(() => index = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
            NavigationDestination(icon: Icon(Icons.favorite), label: 'Library'),
            NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          ],
        ),
      ]),
    );
  }
}

// ───────────── PAGES ─────────────
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final list = app.visible;
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text('Welcome, ${app.user!.name.split(' ').first} 🙏',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            ChoiceChip(
                label: const Text('All'),
                selected: app.filter == null,
                onSelected: (_) => app.setFilter(null)),
            ChoiceChip(
                label: const Text('አማርኛ'),
                selected: app.filter == Lang.amharic,
                onSelected: (_) => app.setFilter(Lang.amharic)),
            ChoiceChip(
                label: const Text('English'),
                selected: app.filter == Lang.english,
                onSelected: (_) => app.setFilter(Lang.english)),
          ]),
          const SizedBox(height: 8),
          for (final s in list) SongTile(s),
        ]);
      },
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final r = app.visible
            .where((s) =>
                s.title.toLowerCase().contains(q.toLowerCase()) ||
                s.artist.toLowerCase().contains(q.toLowerCase()))
            .toList();
        return ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: const InputDecoration(
                hintText: 'Search songs or artists / ዘፈን ፈልግ',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          if (r.isEmpty)
            const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No songs found'))),
          for (final s in r) SongTile(s),
        ]);
      },
    );
  }
}

class LibraryPage extends StatelessWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final favs = app.favorites.toList();
        return ListView(padding: const EdgeInsets.all(16), children: [
          Text('Your Library',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          if (favs.isEmpty)
            const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Tap ♡ on a song to save it here'))),
          for (final s in favs) SongTile(s),
        ]);
      },
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  void editName(BuildContext context) {
    final c = TextEditingController(text: app.user!.name);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Edit name'),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                if (c.text.trim().isNotEmpty) app.setName(c.text);
                Navigator.pop(context);
              },
              child: const Text('Save')),
        ],
      ),
    );
  }

  void confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () {
                Navigator.pop(context);
                app.deleteAccount();
              },
              child: const Text('Delete')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) => ListView(children: [
        const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Settings',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
        ListTile(
          leading: const CircleAvatar(child: Icon(Icons.person)),
          title: Text(app.user!.name),
          subtitle: Text(app.user!.email),
          trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => editName(context)),
        ),
        const Divider(),
        SwitchListTile(
          secondary: const Icon(Icons.dark_mode),
          title: const Text('Dark mode'),
          value: app.themeMode == ThemeMode.dark,
          onChanged: (v) => app.setTheme(v ? ThemeMode.dark : ThemeMode.light),
        ),
        ListTile(
          leading: const Icon(Icons.language),
          title: const Text('Music language'),
          trailing: DropdownButton<Lang?>(
            value: app.filter,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: null, child: Text('Both')),
              DropdownMenuItem(value: Lang.amharic, child: Text('አማርኛ')),
              DropdownMenuItem(value: Lang.english, child: Text('English')),
            ],
            onChanged: app.setFilter,
          ),
        ),
        const Divider(),
        const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('About'),
            subtitle: Text('Selam Worship v1.0.0')),
        ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out'),
            onTap: app.logOut),
        ListTile(
          leading: Icon(Icons.delete_forever,
              color: Theme.of(context).colorScheme.error),
          title: Text('Delete account',
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          onTap: () => confirmDelete(context),
        ),
      ]),
    );
  }
}

// ───────────── WIDGETS ─────────────
class SongTile extends StatelessWidget {
  final Song song;
  const SongTile(this.song, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = app.current == song;
    final fav = app.favorites.contains(song);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
            color: song.lang == Lang.amharic
                ? cs.primaryContainer
                : cs.tertiaryContainer,
            borderRadius: BorderRadius.circular(8)),
        child: Icon(active && app.playing ? Icons.graphic_eq : Icons.music_note),
      ),
      title: Text(song.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: active ? cs.primary : null,
              fontWeight: active ? FontWeight.bold : null)),
      subtitle: Text(
          '${song.artist} • ${song.lang == Lang.amharic ? 'አማርኛ' : 'English'}'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(fmt(song.seconds)),
        IconButton(
          icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
              color: fav ? Colors.redAccent : null),
          onPressed: () => app.toggleFav(song),
        ),
      ]),
      onTap: () => app.play(song),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final s = app.current;
        if (s == null) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return GestureDetector(
          onTap: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const PlayerScreen(), fullscreenDialog: true)),
          child: Container(
            color: cs.surfaceContainerHighest,
            child: Column(children: [
              LinearProgressIndicator(value: app.position / s.seconds, minHeight: 2),
              ListTile(
                dense: true,
                leading: const Icon(Icons.music_note),
                title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(s.artist),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                      icon: Icon(app.playing ? Icons.pause : Icons.play_arrow),
                      onPressed: app.toggle),
                  IconButton(icon: const Icon(Icons.skip_next), onPressed: app.next),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (_, __) {
        final s = app.current;
        if (s == null) return const Scaffold();
        final cs = Theme.of(context).colorScheme;
        final fav = app.favorites.contains(s);
        return Scaffold(
          appBar: AppBar(
              leading: IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onPressed: () => Navigator.pop(context)),
              title: const Text('Now Playing')),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(children: [
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: Container(
                      decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          borderRadius: BorderRadius.circular(24)),
                      child: Icon(Icons.church, size: 96, color: cs.primary),
                    ),
                  ),
                ),
              ),
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.title,
                        style: Theme.of(context).textTheme.titleLarge,
                        maxLines: 2),
                    Text(s.artist, style: TextStyle(color: cs.onSurfaceVariant)),
                  ]),
                ),
                IconButton(
                  icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                      color: fav ? Colors.redAccent : null),
                  onPressed: () => app.toggleFav(s),
                ),
              ]),
              Slider(
                value: app.position.toDouble().clamp(0, s.seconds.toDouble()),
                max: s.seconds.toDouble(),
                onChanged: (v) => app.seek(v.toInt()),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(fmt(app.position)),
                Text(fmt(s.seconds)),
              ]),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                    iconSize: 40,
                    icon: const Icon(Icons.skip_previous),
                    onPressed: app.prev),
                const SizedBox(width: 16),
                IconButton.filled(
                    iconSize: 48,
                    icon: Icon(app.playing ? Icons.pause : Icons.play_arrow),
                    onPressed: app.toggle),
                const SizedBox(width: 16),
                IconButton(
                    iconSize: 40,
                    icon: const Icon(Icons.skip_next),
                    onPressed: app.next),
              ]),
              const SizedBox(height: 24),
            ]),
          ),
        );
      },
    );
  }
}
