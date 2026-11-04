/// The nightly backup: where it writes, how it is scheduled, and what runs.
///
/// Read this before changing anything here, because two of the constraints are
/// not negotiable and both are easy to design around by accident.
///
/// **WorkManager is not a clock.** Android promises that a periodic task
/// eventually runs, not that it runs at the hour you asked for. Doze, battery
/// saver, a phone switched off overnight and the manufacturer's own task
/// killer all delay it, and some vendor builds never run it at all. So the app
/// must never present "the nightly backup is on" as "a backup happened". The
/// brief says the same thing in different words: show the last successful
/// backup time and warn when it is old. That is why [runBackupNow] records its
/// result in the `setting` table, and why [backupIfStale] exists as a second
/// path that does not depend on WorkManager firing at all.
///
/// **The destination has to be writable from a background isolate.** Android's
/// scoped storage will happily hand the app a path under `/storage/emulated/0`
/// that it cannot write without all-files access. The default destination is
/// therefore the app's own external files directory, which needs no permission
/// and works from the background, and anything the owner picks instead is
/// probed by writing to it before it is saved. See
/// [BackupLocations.defaultDirectory].
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:workmanager/workmanager.dart';

import 'backup_service.dart';
import 'db.dart';
import 'settings_repository.dart';

/// The WorkManager task. One name, so re-registering replaces rather than
/// stacks up a second nightly job every time the app starts.
const String kNightlyBackupTask = 'nightly-backup';
const String kNightlyBackupUniqueName = 'pos-nightly-backup';

/// Local hour the nightly run aims for.
///
/// 4:30 AM, just after the 4 AM business-day cutoff, so a run captures a whole
/// trading day rather than splitting one. Android will drift this by hours;
/// see the note at the top of this file.
const int kNightlyBackupHour = 4;
const int kNightlyBackupMinute = 30;

/// Where backups go.
class BackupLocations {
  /// The folder used when the owner has not chosen one.
  ///
  /// The app's own external files directory, `Android/data/<the package
  /// name>/files/backups`. Three reasons it is the default rather than a
  /// folder in Documents:
  ///
  ///   * it needs no runtime permission, on any Android version;
  ///   * it is writable from the background isolate, which a tree URI from the
  ///     system file picker is not without platform code;
  ///   * a file manager and a USB cable can both reach it, so the files can be
  ///     copied off the phone.
  ///
  /// The cost, which the backup screen states plainly rather than hiding:
  /// Android deletes this folder when the app is uninstalled. A backup that
  /// only ever lives here does not survive losing the phone, so the screen
  /// also tells the owner to copy a file off the device now and then.
  static Future<Directory> defaultDirectory() async {
    // Android only. Null on a phone with no external storage mounted, which
    // is why there is a fallback rather than a bang.
    final external =
        Platform.isAndroid ? await getExternalStorageDirectory() : null;
    final base = external ?? await getApplicationDocumentsDirectory();
    return Directory(p.join(base.path, 'backups'));
  }

  /// The folder in use: whatever the owner chose, or the default.
  ///
  /// A chosen folder that is missing is recreated rather than abandoned: the
  /// owner asked for backups to go there, and a folder deleted by a file
  /// manager should not quietly move them somewhere else. Only when it cannot
  /// be created, which is what an SD card taken out looks like, does this fall
  /// back to the default so that the night's backup still happens somewhere.
  static Future<Directory> current(SettingsRepository settings) async {
    final chosen = await settings.read(SettingKeys.backupDir);
    if (chosen != null && chosen.isNotEmpty) {
      final dir = Directory(chosen);
      if (_usable(dir)) return dir;
    }
    return defaultDirectory();
  }

  /// Whether the folder in use is the owner's choice or the fallback.
  static Future<bool> isUsingDefault(SettingsRepository settings) async {
    final chosen = await settings.read(SettingKeys.backupDir);
    if (chosen == null || chosen.isEmpty) return true;
    return !_usable(Directory(chosen));
  }

  static bool _usable(Directory dir) {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir.existsSync();
    } on FileSystemException {
      return false;
    }
  }
}

/// What a backup attempt did, for the caller and for the screen.
class BackupAttempt {
  const BackupAttempt({required this.result, required this.directory});

  final BackupResult result;
  final Directory directory;

  bool get succeeded => result is BackupDone;
}

/// Runs a backup and records the outcome, success or failure.
///
/// The recording is the point. A nightly job has nobody to report to, so an
/// unrecorded failure is a silent one, and the whole reason the brief asks for
/// a last-success time is that silence cannot be distinguished from success.
Future<BackupAttempt> runBackupNow(
  PosDatabase db, {
  required File databaseFile,
  Directory? into,
}) async {
  final settings = SettingsRepository(db);
  final dir = into ?? await BackupLocations.current(settings);

  final service = BackupService(db, databaseFile: databaseFile);
  final result = await service.backupTo(dir);

  // Every attempt stamps its time, so "tried at 4:30 and failed" is
  // distinguishable from "never tried".
  await settings.writeTime(SettingKeys.backupLastAttemptAt, DateTime.now());

  switch (result) {
    case BackupDone(:final file, :final at):
      await settings.writeTime(SettingKeys.backupLastSuccessAt, at);
      await settings.write(SettingKeys.backupLastFile, p.basename(file.path));
      await settings.remove(SettingKeys.backupLastError);
    case BackupFailed(:final message):
      await settings.write(SettingKeys.backupLastError, message);
  }

  return BackupAttempt(result: result, directory: dir);
}

/// Backs up if the last good one is older than [kBackupStaleAfter].
///
/// Called when the app starts. This is the path that does not rely on Android
/// running a periodic task, and on the phones this app is going to live on it
/// is likely to be the path that actually does the work. Returns null when no
/// backup was due.
Future<BackupAttempt?> backupIfStale(
  PosDatabase db, {
  required File databaseFile,
  DateTime Function() now = DateTime.now,
}) async {
  final settings = SettingsRepository(db);
  if (!await settings.readFlag(SettingKeys.backupNightlyEnabled,
      orElse: true)) {
    return null;
  }

  final last = await settings.readTime(SettingKeys.backupLastSuccessAt);
  if (last != null && now().difference(last) < kBackupStaleAfter) return null;

  return runBackupNow(db, databaseFile: databaseFile);
}

/// How long ago the last good backup was, or null if there has never been one.
Future<Duration?> backupAge(
  SettingsRepository settings, {
  DateTime Function() now = DateTime.now,
}) async {
  final last = await settings.readTime(SettingKeys.backupLastSuccessAt);
  if (last == null) return null;
  return now().difference(last);
}

/// Whether the owner should be warned about the backup.
///
/// Never having backed up is a warning too, not a blank. An app that has been
/// billing for a month with no backup should say so.
bool backupNeedsAttention(Duration? age) =>
    age == null || age > kBackupStaleAfter;

/// The entry point Android calls in a background isolate.
///
/// `vm:entry-point` keeps the tree shaker from removing it in a release build,
/// where nothing in Dart appears to call it. Without the pragma the nightly
/// backup works in debug and silently never runs in the release APK.
@pragma('vm:entry-point')
void backupCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task != kNightlyBackupTask) {
      // Not ours. Returning true stops Android retrying it forever.
      return true;
    }

    PosDatabase? db;
    try {
      // A separate isolate, so none of the app's providers exist here. The
      // database is opened fresh and closed again, and WAL mode means this
      // does not block the till if the restaurant happens to be open.
      db = PosDatabase.open();
      final dir = await getApplicationDocumentsDirectory();
      await runBackupNow(
        db,
        databaseFile: File(p.join(dir.path, kDatabaseFileName)),
      );
      // True even when the backup failed. The failure is already recorded in
      // the database, where the backup screen will show it, and asking Android
      // to retry a backup that failed because a folder is unwritable would
      // only drain the battery until the owner fixes the folder.
      return true;
    } on Object {
      // The isolate must not crash out: a thrown error here is reported by
      // Android as a failed task and nothing else, so it would be invisible.
      return true;
    } finally {
      await db?.close();
    }
  });
}

/// Registers the nightly job, replacing any already registered.
Future<void> scheduleNightlyBackup({DateTime Function() now = DateTime.now}) =>
    Workmanager().registerPeriodicTask(
      kNightlyBackupUniqueName,
      kNightlyBackupTask,
      frequency: const Duration(days: 1),
      initialDelay: delayUntilNextRun(now()),
      // `update` rather than `keep`: with `keep`, changing the frequency in a
      // later version of the app would leave the old one running forever.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      constraints: Constraints(
        networkType: NetworkType.notRequired,
        requiresBatteryNotLow: true,
        requiresStorageNotLow: true,
      ),
    );

Future<void> cancelNightlyBackup() =>
    Workmanager().cancelByUniqueName(kNightlyBackupUniqueName);

/// How long until the next [kNightlyBackupHour]:[kNightlyBackupMinute] local.
///
/// Always in the future: at exactly 4:30 AM the answer is tomorrow, not zero,
/// because a zero delay makes Android run the task immediately and then again
/// at the same time, which looks like the job firing twice.
Duration delayUntilNextRun(DateTime from) {
  var target = DateTime(
    from.year,
    from.month,
    from.day,
    kNightlyBackupHour,
    kNightlyBackupMinute,
  );
  if (!target.isAfter(from)) {
    target = target.add(const Duration(days: 1));
  }
  return target.difference(from);
}
