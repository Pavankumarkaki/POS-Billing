/// The object graph, wired with Riverpod.
///
/// Flutter note for a Go developer: this file is what you would write by hand
/// in a Go `main()` — construct the database, hand it to the repositories, hand
/// those to whatever needs them. Riverpod adds two things: each provider builds
/// its value lazily and once, and a test can override any provider with a fake
/// without touching the code that depends on it.
///
/// Deliberately written by hand rather than generated. The brief's reader is
/// new to Flutter, and one less code generator is one less thing to debug when
/// a build goes wrong.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'core/domain.dart';
import 'data/auth_repository.dart';
import 'data/backup_service.dart';
import 'data/backup_worker.dart';
import 'data/bill_repository.dart';
import 'data/db.dart';
import 'data/export_service.dart';
import 'data/menu_repository.dart';
import 'data/outlet_repository.dart';
import 'data/settings_repository.dart';
import 'data/setup_repository.dart';
import 'printing/bluetooth_printer.dart';
import 'printing/fake_printer.dart';
import 'printing/lan_printer.dart';
import 'printing/print_service.dart';
import 'printing/printer.dart';

/// The database. One per app run.
///
/// Overridden in tests with `PosDatabase.memory()`, which is why nothing below
/// constructs a database itself.
final databaseProvider = Provider<PosDatabase>((ref) {
  final db = PosDatabase.open();
  ref.onDispose(db.close);
  return db;
});

/// Setup can run before there is a device or an outlet, so it depends on
/// nothing but the database.
final setupRepositoryProvider = Provider<SetupRepository>(
  (ref) => SetupRepository(ref.watch(databaseProvider)),
);

/// Whether first-run setup has been completed. The app routes on this.
final isConfiguredProvider = FutureProvider<bool>(
  (ref) => ref.watch(setupRepositoryProvider).isConfigured(),
);

/// This device's row. Null before setup.
final deviceProvider = FutureProvider<DeviceRow?>(
  (ref) => ref.watch(databaseProvider).select(
        ref.watch(databaseProvider).devices,
      ).getSingleOrNull(),
);

/// Emits whenever the outlet row changes. Not read for its value.
///
/// Exists so [outletProvider] can stay a FutureProvider while still being
/// live. See the note there for why it cannot simply be a stream itself.
final _outletChanges = StreamProvider<void>(
  (ref) => ref.watch(databaseProvider).select(
        ref.watch(databaseProvider).outlets,
      ).watchSingleOrNull(),
);

/// The outlet. Null before setup.
///
/// A FutureProvider that re-runs when the outlet row changes, rather than a
/// StreamProvider. Both halves of that are deliberate:
///
///   * **It has to re-run.** Settings can now change the tax mode, the FSSAI
///     number and the GSTIN, and the screens that read them are not the screen
///     that writes them. A plain cached future left the billing screen
///     computing bills on the old tax mode until the app was restarted, which
///     is the same bug that once hid a saved bill from the Bills tab.
///   * **It cannot be a StreamProvider.** Several callers do
///     `await ref.watch(outletProvider.future)`, and a StreamProvider's
///     `.future` only completes once something is subscribed to the stream.
///     Read from a one-shot callback, as the export does through
///     `todayProvider`, it never completes and the caller hangs for ever.
///     Making this a stream deadlocked the whole export path, deterministically
///     and silently.
final outletProvider = FutureProvider<OutletRow?>((ref) async {
  // Watched for the dependency, not the value: an emission re-runs this.
  ref.watch(_outletChanges);
  return ref.watch(databaseProvider).select(
        ref.watch(databaseProvider).outlets,
      ).getSingleOrNull();
});

/// Auth needs the device id, for the audit log.
///
/// Returns null before setup, because there is no device to attribute a
/// sign-in to and nobody to sign in as.
final authRepositoryProvider = FutureProvider<AuthRepository?>((ref) async {
  final device = await ref.watch(deviceProvider.future);
  if (device == null) return null;
  return AuthRepository(ref.watch(databaseProvider), deviceId: device.id);
});

final billRepositoryProvider = Provider<BillRepository>(
  (ref) => BillRepository(ref.watch(databaseProvider)),
);

/// The menu. Needs the device id for the audit log, so it waits for setup.
final menuRepositoryProvider = FutureProvider<MenuRepository?>((ref) async {
  final device = await ref.watch(deviceProvider.future);
  if (device == null) return null;
  return MenuRepository(ref.watch(databaseProvider), deviceId: device.id);
});

/// The category tree for the admin screen, disabled entries included so they
/// can be brought back.
///
/// A stream, so an edit made anywhere shows everywhere without a writer
/// having to remember to invalidate it.
final categoryTreeProvider =
    StreamProvider<List<CategoryTree>>((ref) async* {
  final menu = await ref.watch(menuRepositoryProvider.future);
  if (menu == null) {
    yield const [];
    return;
  }
  yield* menu.watchCategoryTree(includeInactive: true);
});

/// Items in one category, disabled ones included.
final categoryItemsProvider =
    StreamProvider.family<List<ItemRow>, String>((ref, categoryId) async* {
  final menu = await ref.watch(menuRepositoryProvider.future);
  if (menu == null) {
    yield const [];
    return;
  }
  yield* menu.watchItemsIn(categoryId, includeInactive: true);
});

/// Where the fake printer writes its receipts.
///
/// Overridden in tests with a temp directory. In the app it is the documents
/// directory, so the owner can find the files through a file manager.
final receiptDirectoryProvider = Provider<Directory>((ref) {
  throw UnimplementedError('receiptDirectoryProvider must be overridden');
});

/// The printer settings stored on the device row.
final printerConfigProvider = FutureProvider<PrinterConfig>((ref) async {
  final device = await ref.watch(deviceProvider.future);
  if (device == null) return const PrinterConfig();
  try {
    return PrinterConfig.fromJson(
      jsonDecode(device.printerCfg) as Map<String, Object?>,
    );
  } on Object {
    // A corrupt setting must not stop the restaurant billing.
    return const PrinterConfig();
  }
});

/// The printer in use, chosen by the stored configuration.
///
/// Everything above depends on the [Printer] interface, so swapping between
/// Bluetooth, LAN and the fake printer changes nothing else.
final printerProvider = Provider<Printer>((ref) {
  final config = ref.watch(printerConfigProvider).value;
  return switch (config?.kind ?? PrinterKind.fake) {
    PrinterKind.bluetooth => BluetoothPrinter(),
    PrinterKind.lan => LanPrinter(),
    PrinterKind.fake =>
      FakePrinter(directory: ref.watch(receiptDirectoryProvider)),
  };
});

/// Printers already paired with this phone. Bluetooth only.
final pairedPrintersProvider =
    FutureProvider<List<PairedPrinter>>((ref) => BluetoothPrinter.pairedPrinters());

/// Printing. One instance, so its queue really does serialise every job.
final printServiceProvider = Provider<PrintService>(
  (ref) => PrintService(
    ref.watch(databaseProvider),
    printer: ref.watch(printerProvider),
  ),
);

/// Everyone who may be offered on the login screen.
final activeUsersProvider = FutureProvider<List<UserRow>>((ref) async {
  final auth = await ref.watch(authRepositoryProvider.future);
  if (auth == null) return const [];
  return auth.activeUsers();
});

/// Who is signed in, or null.
///
/// Memory only, on purpose: closing the app signs you out. A till left on a
/// counter should not stay signed in as the owner.
final sessionProvider = NotifierProvider<SessionNotifier, Session?>(
  SessionNotifier.new,
);

class SessionNotifier extends Notifier<Session?> {
  @override
  Session? build() => null;

  void signIn(Session session) => state = session;

  void signOut() => state = null;
}

/// Whether the signed-in user may do something.
///
/// Returns false when nobody is signed in, so a screen that forgets to check
/// for a session fails closed rather than open.
bool can(Ref ref, Permission permission) {
  final session = ref.watch(sessionProvider);
  if (session == null) return false;
  return session.can(permission);
}

// ---------------------------------------------------------------------------
// Backup, restore and export.
// ---------------------------------------------------------------------------

/// The `setting` table, read and written by name.
final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

/// The live database file, which the restore path needs in order to stage its
/// replacement beside it.
///
/// Overridden in tests with a temp file, the same way [receiptDirectoryProvider]
/// is: a widget test has no application documents directory.
final databaseFileProvider = FutureProvider<File>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  return File(p.join(dir.path, kDatabaseFileName));
});

final backupServiceProvider = FutureProvider<BackupService>((ref) async {
  final file = await ref.watch(databaseFileProvider.future);
  return BackupService(ref.watch(databaseProvider), databaseFile: file);
});

final exportServiceProvider = Provider<ExportService>(
  (ref) => ExportService(ref.watch(databaseProvider)),
);

/// Where backups are being written.
final backupDirectoryProvider = FutureProvider<Directory>(
  (ref) => BackupLocations.current(ref.watch(settingsRepositoryProvider)),
);

/// What the backup screen shows, and the one thing the brief insists on: when
/// the last backup actually succeeded, rather than whether one is scheduled.
class BackupStatus {
  const BackupStatus({
    required this.lastSuccessAt,
    required this.lastFile,
    required this.lastError,
    required this.lastAttemptAt,
    required this.nightlyEnabled,
    required this.restoreNotice,
    required this.directory,
    required this.usingDefaultDirectory,
    required this.now,
  });

  final DateTime? lastSuccessAt;
  final String? lastFile;

  /// Why the last attempt failed. Null when the last attempt succeeded.
  final String? lastError;

  final DateTime? lastAttemptAt;
  final bool nightlyEnabled;

  /// What a staged restore did at the last app start, if anything.
  final String? restoreNotice;

  final Directory directory;
  final bool usingDefaultDirectory;
  final DateTime now;

  Duration? get age =>
      lastSuccessAt == null ? null : now.difference(lastSuccessAt!);

  /// Never having backed up counts as needing attention, not as a blank.
  bool get needsAttention => backupNeedsAttention(age);

  bool get everSucceeded => lastSuccessAt != null;
}

/// A stream, so a backup finishing anywhere, including in the background
/// isolate, updates the screen without it having to poll or be reopened.
final backupStatusProvider = StreamProvider<BackupStatus>((ref) async* {
  final settings = ref.watch(settingsRepositoryProvider);
  const keys = [
    SettingKeys.backupLastSuccessAt,
    SettingKeys.backupLastFile,
    SettingKeys.backupLastError,
    SettingKeys.backupLastAttemptAt,
    SettingKeys.backupNightlyEnabled,
    SettingKeys.backupDir,
    SettingKeys.restoreNotice,
  ];

  await for (final values in settings.watchAll(keys)) {
    final chosen = values[SettingKeys.backupDir];
    yield BackupStatus(
      lastSuccessAt:
          DateTime.tryParse(values[SettingKeys.backupLastSuccessAt] ?? '')
              ?.toLocal(),
      lastFile: values[SettingKeys.backupLastFile],
      lastError: values[SettingKeys.backupLastError],
      lastAttemptAt:
          DateTime.tryParse(values[SettingKeys.backupLastAttemptAt] ?? '')
              ?.toLocal(),
      nightlyEnabled:
          values[SettingKeys.backupNightlyEnabled] != 'false',
      restoreNotice: values[SettingKeys.restoreNotice],
      directory: await BackupLocations.current(settings),
      usingDefaultDirectory:
          chosen == null || chosen.isEmpty || !Directory(chosen).existsSync(),
      now: DateTime.now(),
    );
  }
});


// ---------------------------------------------------------------------------
// Outlet details, editable after setup.
// ---------------------------------------------------------------------------

final outletRepositoryProvider = Provider<OutletRepository>(
  (ref) => OutletRepository(ref.watch(databaseProvider)),
);

/// What the Bill details card shows. Null before setup.
final billDetailsProvider = StreamProvider<BillDetails?>(
  (ref) => ref.watch(outletRepositoryProvider).watch(),
);
