import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The brief requires the billing, tax and numbering logic to be plain Dart
/// with no Flutter dependencies, so it stays easy to test. That is easy to
/// break by reflex: one `import 'package:flutter/material.dart'` for a `Color`
/// or a `debugPrint` and `lib/core` can no longer run outside a Flutter test
/// harness.
///
/// So the rule is checked rather than trusted.
void main() {
  group('lib/core stays free of Flutter and of the database', () {
    late final List<File> coreFiles;

    setUpAll(() {
      final dir = Directory('lib/core');
      expect(
        dir.existsSync(),
        isTrue,
        reason: 'run tests from the package root',
      );
      coreFiles = dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();
      expect(coreFiles, isNotEmpty);
    });

    test('no Flutter imports', () {
      final offenders = <String>[];
      for (final file in coreFiles) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (RegExp(r'''^\s*(import|export)\s+['"]package:flutter''')
              .hasMatch(line)) {
            offenders.add('${file.path}:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'lib/core must not depend on Flutter. Found:\n'
            '${offenders.join('\n')}',
      );
    });

    test('no database imports either', () {
      // Drift and sqlite3 belong in lib/data. Keeping them out of core is what
      // lets the tax engine be tested without opening a database.
      final offenders = <String>[];
      for (final file in coreFiles) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (RegExp(
            r'''^\s*(import|export)\s+['"]package:(drift|sqlite3)''',
          ).hasMatch(lines[i])) {
            offenders.add('${file.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
      expect(offenders, isEmpty,
          reason: 'lib/core must not reach for the database. Found:\n'
              '${offenders.join('\n')}');
    });

    test('no dart:io, dart:ui or clock of its own', () {
      // Core takes the time it should use as an argument. A function that reads
      // DateTime.now() itself cannot be tested on a cutoff boundary.
      final offenders = <String>[];
      for (final file in coreFiles) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (RegExp(r'''^\s*import\s+['"]dart:(io|ui)['"]''')
              .hasMatch(line)) {
            offenders.add('${file.path}:${i + 1}: ${line.trim()}');
          }
          if (line.contains('DateTime.now()')) {
            offenders.add(
              '${file.path}:${i + 1}: DateTime.now() — pass the time in instead',
            );
          }
        }
      }
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });
  });
}
