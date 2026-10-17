
import 'package:flutter/material.dart';

void main() {
  runApp(const EnuApp());
}

class EnuApp extends StatelessWidget {
  const EnuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Enu',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF100D1C),
        useMaterial3: true,
      ),
      home: const EnuHome(),
    );
  }
}

class EnuHome extends StatelessWidget {
  const EnuHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Enu',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Praise in every moment',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your Christian music, wherever you go.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 28),
            const Text(
              'Your music',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 14),
            Card(
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFF7C4DFF),
                  child: Icon(Icons.music_note),
                ),
                title: const Text('Your songs'),
                subtitle: const Text(
                  'Your music library will appear here.',
                ),
                trailing: const Icon(Icons.chevron_right),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.download),
                ),
                title: const Text('Offline music'),
                subtitle: const Text(
                  'Listen to downloaded songs without internet.',
                ),
              ),
            ),
            const Spacer(),
            const Center(
              child: Text(
                'Made for worship 💜',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
