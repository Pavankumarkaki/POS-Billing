/// Entry point.
///
/// Flutter note: ProviderScope is Riverpod's container. Everything in
/// providers.dart is built lazily beneath it, and a test can replace any of
/// them by passing `overrides`.
///
/// Two things here are load-bearing:
///
///   1. **A staged restore is applied before anything opens the database.**
///      The first provider to touch `databaseProvider` opens the file, and
///      from then on it cannot be swapped safely. So [adoptStagedRestore] runs
///      before the container is built, not after.
///
///   2. **The container is built here and handed to the app**, rather than
///      letting `ProviderScope` make its own. The startup backup needs the
///      same database the app uses; a second container would open a second
///      connection to the same file, which is how two writers end up racing.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import 'app.dart';
import 'data/backup_service.dart';
import 'data/backup_worker.dart';
import 'data/db.dart';
import 'data/settings_repository.dart';
import 'providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final docs = await getApplicationDocumentsDirectory();

  // Before the database is opened by anything at all. See the note above.
  final restore = adoptStagedRestore(docs);

  // The fake printer writes receipts here. Inside the app's documents
  // directory so they are easy to find and go away with the app.
  final receipts = Directory('${docs.path}/receipts');

  final container = ProviderContainer(
    overrides: [
      receiptDirectoryProvider.overrideWithValue(receipts),
    ],
  );

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const PosApp(),
    ),
  );

  // After runApp, so none of it delays the till. Billing has to work whatever
  // else is broken.
  await _startBackgroundWork(container, docs, restore);
}

/// Records what the restore did, registers the nightly job, and catches up if
/// the last backup is old.
///
/// Every step is guarded on its own, because a phone whose manufacturer has
/// gutted WorkManager must still open the till.
Future<void> _startBackgroundWork(
  ProviderContainer container,
  Directory docs,
  StagedRestoreOutcome restore,
) async {
  try {
    final db = container.read(databaseProvider);
    final settings = SettingsRepository(db);

    if (!restore.isNothing) {
      // Written where the backup screen will show it. A restore that quietly
      // did not happen is the worst outcome of this whole feature, so it
      // leaves a trace either way.
      await settings.write(
        SettingKeys.restoreNotice,
        restore.applied
            ? 'A backup of ${restore.bills} bills was restored when the app '
                'last started.'
            : restore.error!,
      );
    }

    try {
      if (await settings.readFlag(SettingKeys.backupNightlyEnabled,
          orElse: true)) {
        await Workmanager().initialize(backupCallbackDispatcher);
        await scheduleNightlyBackup();
      }
    } on Object {
      // Nothing to do and nowhere useful to say it. The owner sees the real
      // consequence on the backup screen: the last-success time stops moving.
      // The catch-up below does not depend on any of this having worked.
    }

    await backupIfStale(
      db,
      databaseFile: File('${docs.path}/$kDatabaseFileName'),
    );
  } on Object {
    // Billing must not depend on any of the above.
  }
}
