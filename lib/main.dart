// Placeholder entry point.
//
// Milestones 1 and 2 are the calculation engine and the database, neither of
// which has a screen. This exists so the project compiles and a debug APK can
// be built, which is what proves the toolchain and the sqlite3 3.x native
// assets work. The real app starts at milestone 3.
import 'package:flutter/material.dart';

void main() => runApp(const PosApp());

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Billing',
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'AnekTelugu',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0F4A33),
        ),
      ),
      home: const _Placeholder(),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F1),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Milestone 0',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: const Color(0xFF0F4A33),
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            const Text('Toolchain and database check'),
            const SizedBox(height: 24),
            // Proves the bundled Telugu font renders, which printer fonts
            // cannot do.
            const Text(
              'చికెన్ దమ్ బిర్యానీ',
              style: TextStyle(fontSize: 22),
            ),
          ],
        ),
      ),
    );
  }
}
