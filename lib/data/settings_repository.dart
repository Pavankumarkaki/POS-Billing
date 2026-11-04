/// The `setting` table, read and written by name.
///
/// A plain key/value table, which is the right shape for the handful of values
/// that belong to the installation rather than to the outlet or the device:
/// where backups go, when the last one succeeded, what went wrong if it did
/// not. Putting these on the `device` row would mean a migration every time
/// one is added.
///
/// Everything is stored as text and parsed on the way out, so a corrupt or
/// hand-edited value degrades to the default instead of throwing. A settings
/// row must never be able to stop the restaurant billing.
library;

import 'db.dart';

/// Every key this app stores. Constants rather than bare strings, so a typo in
/// a writer and a reader cannot silently disagree.
abstract final class SettingKeys {
  /// Absolute path of the folder backups are written to.
  static const backupDir = 'backup.dir';

  /// When the last backup was verified good, as an ISO-8601 UTC timestamp.
  static const backupLastSuccessAt = 'backup.last_success_at';

  /// The file name of that backup, so the UI can name what it would restore.
  static const backupLastFile = 'backup.last_file';

  /// Why the last attempt failed, or absent if the last attempt succeeded.
  static const backupLastError = 'backup.last_error';

  /// When that failure happened.
  static const backupLastAttemptAt = 'backup.last_attempt_at';

  /// Whether the nightly job is wanted. Absent counts as on.
  static const backupNightlyEnabled = 'backup.nightly_enabled';

  /// What a staged restore did at the last app start, successful or not.
  ///
  /// Deliberately not [backupLastError]: a restore that worked is not a
  /// backup failure, and showing it as one would be its own small lie.
  /// Cleared once the owner has seen it.
  static const restoreNotice = 'restore.notice';
}

class SettingsRepository {
  SettingsRepository(this._db);

  final PosDatabase _db;

  Future<String?> read(String key) async {
    final row = await (_db.select(_db.settings)..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  /// A timestamp, or null if absent or unparseable.
  ///
  /// Stored in UTC and returned in local time, because every other time in
  /// this app is local and a backup time that silently reads five and a half
  /// hours early would look like a failure.
  Future<DateTime?> readTime(String key) async {
    final raw = await read(key);
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toLocal();
  }

  Future<bool> readFlag(String key, {required bool orElse}) async {
    final raw = await read(key);
    return switch (raw) {
      'true' => true,
      'false' => false,
      _ => orElse,
    };
  }

  Future<void> write(String key, String value) =>
      _db.into(_db.settings).insertOnConflictUpdate(SettingsCompanion.insert(
            key: key,
            value: value,
            updatedAt: DateTime.now(),
          ));

  Future<void> writeTime(String key, DateTime at) =>
      write(key, at.toUtc().toIso8601String());

  Future<void> writeFlag(String key, bool value) =>
      write(key, value ? 'true' : 'false');

  Future<void> remove(String key) =>
      (_db.delete(_db.settings)..where((s) => s.key.equals(key))).go();

  /// Reads several keys in one query, for a screen that wants the lot.
  Future<Map<String, String>> readAll(Iterable<String> keys) async {
    final wanted = keys.toList();
    if (wanted.isEmpty) return const {};
    final rows =
        await (_db.select(_db.settings)..where((s) => s.key.isIn(wanted))).get();
    return {for (final r in rows) r.key: r.value};
  }

  /// A stream, so the backup screen updates when the nightly job writes its
  /// result while the screen is open.
  Stream<Map<String, String>> watchAll(Iterable<String> keys) {
    final wanted = keys.toList();
    if (wanted.isEmpty) return Stream.value(const {});
    return (_db.select(_db.settings)..where((s) => s.key.isIn(wanted)))
        .watch()
        .map((rows) => {for (final r in rows) r.key: r.value});
  }
}
