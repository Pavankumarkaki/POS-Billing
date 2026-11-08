/// Backup and restore of the whole database.
///
/// Three things in here are not obvious, and each is the result of getting it
/// wrong first:
///
///   1. **The copy is made with `VACUUM INTO`, never with a file copy.** The
///      database runs in WAL mode, so recent writes live in `pos.sqlite-wal`
///      and not in `pos.sqlite`. Copying just the one file yields a backup
///      missing the last however-many bills, and it looks fine: it opens, it
///      has tables, it is simply out of date. `VACUUM INTO` asks SQLite for a
///      consistent snapshot of the whole database, WAL included, while the app
///      keeps billing.
///
///   2. **A backup is verified before it counts as one.** The file is reopened,
///      `PRAGMA integrity_check` is run, and the bills in it are counted and
///      compared with the source. An unverified backup is a file you hope
///      works, and the one time it matters is the one time you cannot check.
///
///   3. **A restore is staged, not applied.** Replacing `pos.sqlite` under a
///      live connection is how you corrupt a database. Instead the chosen file
///      is copied to `pos.sqlite.restore` and [adoptStagedRestore] swaps it in
///      at the next app start, before anything opens the database. The
///      database being replaced is moved aside, never deleted.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'db.dart';

/// How many dated backups to keep in the destination folder.
///
/// Each is a full copy of the database, and a restaurant's year of billing is
/// a few megabytes, so this is cheap. Older files are removed to stop the
/// folder growing without end; the bills themselves are never touched, which
/// is what the brief's rule about never deleting a bill is about.
const int kBackupsToKeep = 14;

/// A backup older than this is stale enough to warn about.
///
/// Two days rather than one: a phone switched off overnight will miss a run,
/// and warning the owner every time they open the app after a quiet Monday
/// trains them to ignore the warning.
const Duration kBackupStaleAfter = Duration(days: 2);

/// The staged file [adoptStagedRestore] looks for.
const String kStagedRestoreName = '$kDatabaseFileName.restore';

/// What a backup attempt did.
sealed class BackupResult {
  const BackupResult();
}

class BackupDone extends BackupResult {
  const BackupDone({
    required this.file,
    required this.bytes,
    required this.bills,
    required this.at,
  });

  final File file;
  final int bytes;

  /// Bills in the backup, counted from the backup itself. The figure the owner
  /// can compare against what the reports screen says.
  final int bills;

  final DateTime at;
}

class BackupFailed extends BackupResult {
  const BackupFailed(this.message);

  /// Plain language, shown to the owner as it is. No stack traces: the people
  /// using this run a restaurant.
  final String message;
}

/// Whether a file is usable as a restore source.
sealed class RestoreCheck {
  const RestoreCheck();
}

class RestoreUsable extends RestoreCheck {
  const RestoreUsable({
    required this.file,
    required this.bills,
    required this.schemaVersion,
    required this.newestBillAt,
  });

  final File file;
  final int bills;

  /// The schema the backup was written by. Lower than the running app's is
  /// fine: the migrations run when it is opened. Higher is refused.
  final int schemaVersion;

  /// When the last bill in the backup was created, so the owner can see how
  /// much a restore would cost them before they agree to it.
  final DateTime? newestBillAt;
}

class RestoreRefused extends RestoreCheck {
  const RestoreRefused(this.reason);
  final String reason;
}

class BackupService {
  BackupService(
    this._db, {
    required this.databaseFile,
    this.now = DateTime.now,
  });

  final PosDatabase _db;

  /// The live database file. Used only by the restore path, which stages its
  /// replacement beside it.
  final File databaseFile;

  /// The clock, so a test can pin the stamp in a backup's file name.
  final DateTime Function() now;

  Directory get _databaseDir => databaseFile.parent;

  /// Writes a verified backup into [into] and returns what happened.
  ///
  /// Never throws. The nightly job has nowhere to report an exception to, and
  /// a failure has to be recorded rather than lost, so every failure comes
  /// back as a [BackupFailed] with something the owner can act on.
  Future<BackupResult> backupTo(Directory into) async {
    final at = now();
    File? staging;
    try {
      if (!into.existsSync()) {
        into.createSync(recursive: true);
      }

      final name = 'pos-backup-${_stamp(at)}.sqlite';
      final target = File(p.join(into.path, name));

      // VACUUM INTO refuses to overwrite, so a second run in the same minute
      // would fail on the name alone. Write to a temporary name and move it
      // into place, which also means a half-written file is never left under
      // a name that looks like a good backup.
      staging = File(p.join(into.path, '.$name.part'));
      if (staging.existsSync()) staging.deleteSync();

      await _db.customStatement('VACUUM INTO ?', [staging.path]);

      final check = _inspect(staging);
      if (check is RestoreRefused) {
        return BackupFailed('The backup was written but failed its check: '
            '${check.reason}');
      }
      final good = check as RestoreUsable;

      final sourceBills = await _countBills();
      if (good.bills != sourceBills) {
        return BackupFailed(
          'The backup holds ${good.bills} bills but the database has '
          '$sourceBills. Not keeping it.',
        );
      }

      if (target.existsSync()) target.deleteSync();
      staging.renameSync(target.path);
      staging = null;

      _prune(into);

      return BackupDone(
        file: target,
        bytes: target.lengthSync(),
        bills: good.bills,
        at: at,
      );
    } on FileSystemException catch (e) {
      return BackupFailed(_explainFileError(e, into));
    } on SqliteException catch (e) {
      return BackupFailed('SQLite could not write the backup: ${e.message}');
    } on Object catch (e) {
      return BackupFailed('The backup did not finish: $e');
    } finally {
      // A failed attempt must not leave a part file behind to be mistaken for
      // a backup, or to accumulate one per night.
      try {
        if (staging != null && staging.existsSync()) staging.deleteSync();
      } on Object {
        // Nothing useful to do, and the attempt has already been reported.
      }
    }
  }

  /// Proves a folder can actually be written to, by writing to it.
  ///
  /// Android's scoped storage will hand the app a path it cannot write, and
  /// `Directory.existsSync()` says nothing about permission. Saving a
  /// destination that silently fails every night is worse than refusing it
  /// now, so the destination is probed before it is stored.
  Future<String?> probeWritable(Directory dir) async {
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final probe = File(p.join(dir.path, '.pos-write-test'));
      probe.writeAsStringSync('ok');
      final read = probe.readAsStringSync();
      probe.deleteSync();
      if (read != 'ok') return 'That folder did not keep what was written.';
      return null;
    } on FileSystemException catch (e) {
      return _explainFileError(e, dir);
    } on Object catch (e) {
      return 'That folder cannot be used: $e';
    }
  }

  /// The dated backups in [dir], newest first.
  List<File> existingBackups(Directory dir) {
    if (!dir.existsSync()) return const [];
    final files = <File>[];
    for (final e in dir.listSync()) {
      if (e is File && _isBackupName(p.basename(e.path))) files.add(e);
    }
    // By name, which sorts chronologically because the stamp is ISO-ordered.
    files.sort((a, b) => p.basename(b.path).compareTo(p.basename(a.path)));
    return files;
  }

  /// Whether [file] could be restored, and what it holds.
  RestoreCheck inspect(File file) => _inspect(file);

  /// Copies [file] in beside the live database for the next start to adopt.
  ///
  /// Returns null on success, or a reason. Nothing is replaced here: see
  /// [adoptStagedRestore].
  Future<String?> stageRestore(File file) async {
    final check = _inspect(file);
    if (check is RestoreRefused) return check.reason;

    try {
      final staged = File(p.join(_databaseDir.path, kStagedRestoreName));
      _clearSidecars(staged);
      if (staged.existsSync()) staged.deleteSync();
      file.copySync(staged.path);

      // Check the copy, not the original. A truncated copy that is adopted at
      // the next start would take the live database with it.
      final copied = _inspect(staged);
      if (copied is RestoreRefused) {
        staged.deleteSync();
        return 'The copy of that backup did not come out right: '
            '${copied.reason}';
      }
      return null;
    } on FileSystemException catch (e) {
      return _explainFileError(e, _databaseDir);
    } on Object catch (e) {
      return 'That backup could not be prepared: $e';
    }
  }

  /// Whether a restore is waiting to be applied at the next start.
  bool hasStagedRestore() =>
      File(p.join(_databaseDir.path, kStagedRestoreName)).existsSync();

  /// Throws away a staged restore that has not been applied yet.
  void cancelStagedRestore() {
    final staged = File(p.join(_databaseDir.path, kStagedRestoreName));
    if (staged.existsSync()) staged.deleteSync();
  }

  Future<int> _countBills() async {
    final row = await _db
        .customSelect('SELECT COUNT(*) AS n FROM bill')
        .getSingle();
    return row.read<int>('n');
  }

  void _prune(Directory dir) {
    final files = existingBackups(dir);
    for (final old in files.skip(kBackupsToKeep)) {
      try {
        old.deleteSync();
      } on Object {
        // A backup that will not delete is not a reason to fail the backup
        // that just succeeded.
      }
    }
  }

  static bool _isBackupName(String name) =>
      name.startsWith('pos-backup-') && name.endsWith('.sqlite');

  static String _stamp(DateTime at) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)}'
        '-${two(at.hour)}${two(at.minute)}';
  }

  static String _explainFileError(FileSystemException e, Directory dir) {
    final code = e.osError?.errorCode;
    // EACCES and EPERM. Android hands out paths under /storage that look
    // ordinary and cannot be written without All files access, so this is the
    // error the owner is most likely to hit, and the one a raw message
    // explains worst.
    if (code == 13 || code == 1) {
      return 'Android will not let this app write to ${dir.path}. '
          'Either grant all-files access, or pick a different folder.';
    }
    if (code == 28) return 'There is no space left for a backup.';
    if (code == 2) return 'That folder no longer exists: ${dir.path}';
    return e.osError?.message ?? e.message;
  }
}

/// Reads a database file and decides whether it could be restored.
///
/// Opened read-only and never migrated, because deciding whether to restore a
/// file must not change it.
RestoreCheck _inspect(File file) {
  if (!file.existsSync()) {
    return const RestoreRefused('That file is not there any more.');
  }
  if (file.lengthSync() == 0) {
    return const RestoreRefused('That file is empty.');
  }

  Database? db;
  try {
    db = sqlite3.open(file.path, mode: OpenMode.readOnly);

    final integrity = db.select('PRAGMA integrity_check');
    final verdict = integrity.isEmpty
        ? 'no result'
        : '${integrity.first.values.first}';
    if (verdict != 'ok') {
      return RestoreRefused('That file is damaged: $verdict');
    }

    final tables = db
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((r) => r['name'] as String)
        .toSet();
    // A valid SQLite file from some other app is not a backup of this one.
    for (final needed in const ['bill', 'bill_line', 'payment', 'outlet']) {
      if (!tables.contains(needed)) {
        return const RestoreRefused(
          'That is a database, but not one from this app.',
        );
      }
    }

    final version =
        db.select('PRAGMA user_version').first.values.first as int;
    if (version > kSchemaVersion) {
      return RestoreRefused(
        'That backup was made by a newer version of the app '
        '(data version $version, this app reads $kSchemaVersion). '
        'Update the app before restoring it.',
      );
    }

    final bills = db.select('SELECT COUNT(*) AS n FROM bill').first['n'] as int;

    DateTime? newest;
    final latest = db.select('SELECT MAX(created_at) AS t FROM bill');
    final raw = latest.isEmpty ? null : latest.first['t'];
    if (raw is int) {
      // Drift stores DateTime columns as unix seconds.
      newest = DateTime.fromMillisecondsSinceEpoch(raw * 1000);
    }

    return RestoreUsable(
      file: file,
      bills: bills,
      schemaVersion: version,
      newestBillAt: newest,
    );
  } on SqliteException catch (e) {
    return RestoreRefused('That file is not a database this app can read: '
        '${e.message}');
  } on Object catch (e) {
    return RestoreRefused('That file could not be read: $e');
  } finally {
    db?.close();
  }
}

/// Removes the `-wal` and `-shm` that sit beside [file].
///
/// Opening a database read-only still creates them, so simply inspecting a
/// staged restore leaves a pair behind.
void _clearSidecars(File file) {
  for (final suffix in const ['-wal', '-shm']) {
    final f = File('${file.path}$suffix');
    try {
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // Nothing worth failing a restore over.
    }
  }
}

/// Applies a staged restore, if there is one. Call before opening the database.
///
/// The database being replaced is renamed aside rather than deleted, so a
/// restore from the wrong backup is itself recoverable. Returns what happened,
/// for the log and for the screen that reports it.
StagedRestoreOutcome adoptStagedRestore(Directory databaseDir) {
  final staged = File(p.join(databaseDir.path, kStagedRestoreName));
  if (!staged.existsSync()) return const StagedRestoreOutcome.none();

  // Checked again here, not trusted from when it was staged. Between staging
  // and this call the app has been closed and reopened, and the file has been
  // sitting on a phone's flash storage.
  final check = _inspect(staged);
  if (check is RestoreRefused) {
    // Moved out of the way rather than deleted, so it cannot be retried in a
    // loop at every start, and can still be looked at.
    try {
      staged.renameSync('${staged.path}.rejected');
      _clearSidecars(staged);
    } on Object {
      // If it will not even rename, leave it; the message is what matters.
    }
    return StagedRestoreOutcome.failed(
      'The backup waiting to be restored could not be used: ${check.reason}',
    );
  }

  final live = File(p.join(databaseDir.path, kDatabaseFileName));
  try {
    if (live.existsSync()) {
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .split('.')
          .first;
      final aside = p.join(databaseDir.path, 'pos.replaced-$stamp.sqlite');
      live.renameSync(aside);

      // The write-ahead log moves WITH the database it belongs to, and is not
      // deleted. Two reasons, and the first one cost a restore on a test
      // device before it was caught:
      //
      //   1. Most of the recent bills live in the WAL, not in the main file.
      //      Deleting it left the kept-aside copy holding 6 bills out of 10,
      //      which makes "the database being replaced is kept, so a mistake
      //      can be undone" a false promise. SQLite finds a WAL by its
      //      database's file name, so renaming it alongside keeps the copy
      //      whole and openable.
      //   2. It still has to stop being beside the restored file. A stale WAL
      //      left there is how a restored database opens and then shows the
      //      old data straight back.
      for (final suffix in const ['-wal', '-shm']) {
        final f = File(p.join(databaseDir.path, '$kDatabaseFileName$suffix'));
        if (f.existsSync()) f.renameSync('$aside$suffix');
      }
    }

    staged.renameSync(live.path);

    // Inspecting the staged file opened it, which leaves a -wal and -shm
    // beside it. Harmless now, but a stale pair sitting next to the NEXT
    // staged restore would belong to a different database, and SQLite would
    // read the two together.
    _clearSidecars(staged);

    return StagedRestoreOutcome.done((check as RestoreUsable).bills);
  } on Object catch (e) {
    return StagedRestoreOutcome.failed('The restore could not be completed: $e');
  }
}

class StagedRestoreOutcome {
  const StagedRestoreOutcome.none()
      : applied = false,
        bills = 0,
        error = null;
  const StagedRestoreOutcome.done(this.bills)
      : applied = true,
        error = null;
  const StagedRestoreOutcome.failed(this.error)
      : applied = false,
        bills = 0;

  final bool applied;
  final int bills;
  final String? error;

  bool get isNothing => !applied && error == null;
}
