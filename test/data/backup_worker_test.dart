/// The nightly backup's own logic: when it is due, where it writes, and what
/// it records.
///
/// What is NOT tested here, and cannot be from a Dart test, is whether Android
/// actually runs the periodic task. That is the whole reason the recorded
/// last-success time exists, and it is section 9 of HARDWARE_TEST.md.
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/backup_service.dart';
import 'package:restaurant_pos/data/backup_worker.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/settings_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/core/domain.dart';

class Fixture {
  Fixture(this.dir, this.db, this.deviceId, this.ownerId, this.itemId);

  final Directory dir;
  final PosDatabase db;
  final String deviceId;
  final String ownerId;
  final String itemId;

  File get file => File(p.join(dir.path, kDatabaseFileName));
  SettingsRepository get settings => SettingsRepository(db);
  Directory get into => Directory(p.join(dir.path, 'out'));
}

Future<Fixture> openFixture() async {
  final dir = Directory.systemTemp.createTempSync('pos-worker-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final db =
      PosDatabase(NativeDatabase(File(p.join(dir.path, kDatabaseFileName))));
  addTearDown(db.close);

  final setup = SetupRepository(db);
  final r = await setup.completeSetup(const SetupDetails(
    outletName: 'Annapurna Mess',
    address: 'Main Road',
    phone: '9000000000',
    fssaiNo: '12345678901234',
    taxMode: TaxMode.regular5,
    gstin: '37ABCDE1234F1Z5',
    ownerName: 'Ravi',
    ownerPin: '1357',
    devicePrefix: 'A',
  ));

  final menu = MenuRepository(db, deviceId: r.deviceId);
  final cat = await menu.createCategory(nameEn: 'Biryani', byUserId: r.ownerId);
  final item = await menu.createItem(
    categoryId: cat,
    nameEn: 'Chicken Dum Biryani',
    price: Paise.fromRupees(240),
    taxClass: TaxClass.gst5,
    byUserId: r.ownerId,
  );

  return Fixture(dir, db, r.deviceId, r.ownerId, item);
}

Future<void> sell(Fixture f) async {
  final computed = computeBill(
    cart: [
      CartLine(
        itemId: f.itemId,
        nameSnapshot: 'Chicken Dum Biryani',
        unitPrice: Paise.fromRupees(240),
        qty: 1,
        taxClass: TaxClass.gst5,
      ),
    ],
    config: const TaxConfig(mode: TaxMode.regular5, pricesIncludeTax: false),
    orderType: OrderType.dine,
  );
  await BillRepository(f.db).commitSale(
    computed: computed,
    payments: [PaymentIntent(PaymentMode.cash, computed.total)],
    deviceId: f.deviceId,
    userId: f.ownerId,
  );
}

void main() {
  // path_provider talks to the platform, which a Dart test has none of. The
  // default backup folder is part of what is being tested, so the channel is
  // answered with a temp directory rather than the tests avoiding that path.
  late Directory platformDir;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    platformDir = Directory.systemTemp.createTempSync('pos-platform-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => platformDir.path,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (platformDir.existsSync()) platformDir.deleteSync(recursive: true);
  });

  group('when the next run is due', () {
    test('later the same day', () {
      final delay = delayUntilNextRun(DateTime(2026, 11, 4, 1, 0));
      expect(delay, const Duration(hours: 3, minutes: 30));
    });

    test('tomorrow, once the hour has passed', () {
      final delay = delayUntilNextRun(DateTime(2026, 11, 4, 23, 30));
      expect(delay, const Duration(hours: 5));
    });

    test('at exactly the target time it waits a whole day', () {
      // A zero delay makes Android run the task at once and then again at the
      // scheduled time, which reads as the job firing twice.
      final delay = delayUntilNextRun(DateTime(2026, 11, 4, 4, 30));
      expect(delay, const Duration(days: 1));
    });

    test('is never zero or negative, at any minute of the day', () {
      for (var minute = 0; minute < 24 * 60; minute++) {
        final at = DateTime(2026, 11, 4).add(Duration(minutes: minute));
        final delay = delayUntilNextRun(at);
        expect(delay, greaterThan(Duration.zero), reason: '$at');
        expect(delay, lessThanOrEqualTo(const Duration(days: 1)), reason: '$at');
      }
    });

    test('across the end of a month', () {
      final delay = delayUntilNextRun(DateTime(2026, 11, 30, 23, 0));
      expect(delay, const Duration(hours: 5, minutes: 30));
    });
  });

  group('whether to warn about the backup', () {
    test('a backup from this morning is fine', () {
      expect(backupNeedsAttention(const Duration(hours: 6)), isFalse);
    });

    test('nothing recorded at all is a warning, not a blank', () {
      // An app that has been billing for a month with no backup must say so.
      expect(backupNeedsAttention(null), isTrue);
    });

    test('older than the stale window is a warning', () {
      expect(
        backupNeedsAttention(kBackupStaleAfter + const Duration(minutes: 1)),
        isTrue,
      );
    });

    test('exactly at the window is not yet a warning', () {
      expect(backupNeedsAttention(kBackupStaleAfter), isFalse);
    });

    test('one missed night does not warn', () {
      // A phone switched off overnight misses a run. Warning every time trains
      // the owner to ignore the warning, which is worse than not showing one.
      expect(backupNeedsAttention(const Duration(hours: 30)), isFalse);
    });
  });

  group('running a backup', () {
    test('records the time, the file name, and no error', () async {
      final f = await openFixture();
      await sell(f);

      final attempt =
          await runBackupNow(f.db, databaseFile: f.file, into: f.into);
      expect(attempt.succeeded, isTrue);

      expect(
        await f.settings.readTime(SettingKeys.backupLastSuccessAt),
        isNotNull,
      );
      expect(
        await f.settings.read(SettingKeys.backupLastFile),
        startsWith('pos-backup-'),
      );
      expect(await f.settings.read(SettingKeys.backupLastError), isNull);
      expect(
        await f.settings.readTime(SettingKeys.backupLastAttemptAt),
        isNotNull,
      );
    });

    test('records a failure instead of losing it', () async {
      // A nightly job has nobody to throw to. An unrecorded failure is a
      // silent one, and silence is indistinguishable from success.
      final f = await openFixture();
      await sell(f);
      final blocked = File(p.join(f.dir.path, 'not-a-folder'))
        ..writeAsStringSync('x');

      final attempt = await runBackupNow(
        f.db,
        databaseFile: f.file,
        into: Directory(blocked.path),
      );

      expect(attempt.succeeded, isFalse);
      expect(await f.settings.read(SettingKeys.backupLastError), isNotNull);
      expect(
        await f.settings.readTime(SettingKeys.backupLastAttemptAt),
        isNotNull,
        reason: 'tried and failed must be distinguishable from never tried',
      );
      expect(
        await f.settings.readTime(SettingKeys.backupLastSuccessAt),
        isNull,
      );
    });

    test('a later success clears the recorded failure', () async {
      final f = await openFixture();
      await sell(f);
      final blocked = File(p.join(f.dir.path, 'not-a-folder'))
        ..writeAsStringSync('x');

      await runBackupNow(f.db,
          databaseFile: f.file, into: Directory(blocked.path));
      expect(await f.settings.read(SettingKeys.backupLastError), isNotNull);

      await runBackupNow(f.db, databaseFile: f.file, into: f.into);
      expect(
        await f.settings.read(SettingKeys.backupLastError),
        isNull,
        reason: 'a stale error on the screen is its own kind of wrong',
      );
    });

    test('the recorded success time matches a readable backup', () async {
      // The two halves have to agree: a recorded time with no file behind it
      // would be the worst possible outcome, since it reads as safe.
      final f = await openFixture();
      await sell(f);

      await runBackupNow(f.db, databaseFile: f.file, into: f.into);

      final name = await f.settings.read(SettingKeys.backupLastFile);
      final file = File(p.join(f.into.path, name!));
      expect(file.existsSync(), isTrue);

      final check = BackupService(f.db, databaseFile: f.file).inspect(file);
      expect(check, isA<RestoreUsable>());
      expect((check as RestoreUsable).bills, 1);
    });
  });

  group('backing up at startup when the last one is old', () {
    test('runs when nothing has ever been backed up', () async {
      final f = await openFixture();
      await sell(f);
      await f.settings.write(SettingKeys.backupDir, f.into.path);

      final attempt = await backupIfStale(f.db, databaseFile: f.file);
      expect(attempt, isNotNull);
      expect(attempt!.succeeded, isTrue);
    });

    test('does nothing when a recent backup exists', () async {
      final f = await openFixture();
      await sell(f);
      await f.settings
          .writeTime(SettingKeys.backupLastSuccessAt, DateTime(2026, 11, 4, 4));

      final attempt = await backupIfStale(
        f.db,
        databaseFile: f.file,
        now: () => DateTime(2026, 11, 4, 20),
      );
      expect(attempt, isNull);
    });

    test('runs when the last one is older than the stale window', () async {
      final f = await openFixture();
      await sell(f);
      await f.settings.write(SettingKeys.backupDir, f.into.path);
      await f.settings
          .writeTime(SettingKeys.backupLastSuccessAt, DateTime(2026, 11, 1, 4));

      final attempt = await backupIfStale(
        f.db,
        databaseFile: f.file,
        now: () => DateTime(2026, 11, 4, 20),
      );
      expect(attempt, isNotNull);
      expect(attempt!.succeeded, isTrue);
    });

    test('respects the owner switching nightly backup off', () async {
      final f = await openFixture();
      await sell(f);
      await f.settings.writeFlag(SettingKeys.backupNightlyEnabled, false);

      expect(await backupIfStale(f.db, databaseFile: f.file), isNull);
    });

    test('on by default, because the setting starts absent', () async {
      final f = await openFixture();
      expect(
        await f.settings
            .readFlag(SettingKeys.backupNightlyEnabled, orElse: true),
        isTrue,
      );
    });
  });

  group('where backups go', () {
    test('a chosen folder is used', () async {
      final f = await openFixture();
      final chosen = Directory(p.join(f.dir.path, 'chosen'))..createSync();
      await f.settings.write(SettingKeys.backupDir, chosen.path);

      expect((await BackupLocations.current(f.settings)).path, chosen.path);
      expect(await BackupLocations.isUsingDefault(f.settings), isFalse);
    });

    test('a chosen folder deleted by a file manager is recreated', () async {
      // The owner asked for backups to go there. A folder someone tidied away
      // should not quietly move tonight's backup somewhere else.
      final f = await openFixture();
      final chosen = Directory(p.join(f.dir.path, 'chosen'))..createSync();
      await f.settings.write(SettingKeys.backupDir, chosen.path);
      chosen.deleteSync();

      expect((await BackupLocations.current(f.settings)).path, chosen.path);
      expect(chosen.existsSync(), isTrue);
      expect(await BackupLocations.isUsingDefault(f.settings), isFalse);
    });

    test('a chosen folder that cannot be created falls back to the default',
        () async {
      // What an SD card taken out looks like. Backing up somewhere beats a
      // nightly failure nobody reads.
      final f = await openFixture();
      final blocker = File(p.join(f.dir.path, 'blocker'))
        ..writeAsStringSync('x');
      await f.settings
          .write(SettingKeys.backupDir, p.join(blocker.path, 'backups'));

      expect(await BackupLocations.isUsingDefault(f.settings), isTrue);
      expect(
        (await BackupLocations.current(f.settings)).path,
        (await BackupLocations.defaultDirectory()).path,
      );
    });

    test('an empty stored path counts as not chosen', () async {
      final f = await openFixture();
      await f.settings.write(SettingKeys.backupDir, '');
      expect(await BackupLocations.isUsingDefault(f.settings), isTrue);
    });

    test('the default is a backups folder the app owns', () async {
      final dir = await BackupLocations.defaultDirectory();
      expect(p.basename(dir.path), 'backups');
    });

    test('a nightly run with no folder chosen writes to the default',
        () async {
      final f = await openFixture();
      await sell(f);

      final attempt = await runBackupNow(f.db, databaseFile: f.file);

      expect(attempt.succeeded, isTrue);
      expect(
        attempt.directory.path,
        (await BackupLocations.defaultDirectory()).path,
      );
    });
  });

  group('the settings store itself', () {
    test('a value survives a round trip', () async {
      final f = await openFixture();
      await f.settings.write('k', 'v');
      expect(await f.settings.read('k'), 'v');
    });

    test('writing twice updates rather than failing on the key', () async {
      final f = await openFixture();
      await f.settings.write('k', 'one');
      await f.settings.write('k', 'two');
      expect(await f.settings.read('k'), 'two');
    });

    test('a time comes back as the same instant', () async {
      final f = await openFixture();
      final at = DateTime(2026, 11, 4, 4, 30, 15);
      await f.settings.writeTime('t', at);
      expect(await f.settings.readTime('t'), at);
    });

    test('a corrupt time reads as absent rather than throwing', () async {
      // A settings row must never be able to stop the restaurant billing.
      final f = await openFixture();
      await f.settings.write('t', 'not a date');
      expect(await f.settings.readTime('t'), isNull);
    });

    test('a corrupt flag falls back to the default', () async {
      final f = await openFixture();
      await f.settings.write('flag', 'yes please');
      expect(await f.settings.readFlag('flag', orElse: true), isTrue);
      expect(await f.settings.readFlag('flag', orElse: false), isFalse);
    });

    test('readAll fetches several at once', () async {
      final f = await openFixture();
      await f.settings.write('a', '1');
      await f.settings.write('b', '2');
      expect(await f.settings.readAll(['a', 'b', 'missing']), {'a': '1', 'b': '2'});
    });

    test('readAll of nothing asks nothing', () async {
      final f = await openFixture();
      expect(await f.settings.readAll(const []), isEmpty);
    });

    test('watchAll sees a write made while it is being watched', () async {
      // The backup screen is open while the nightly job writes its result.
      final f = await openFixture();
      final seen = f.settings.watchAll(['x']);

      await f.settings.write('x', 'first');
      await expectLater(
        seen,
        emitsThrough(containsPair('x', 'first')),
      );
    });

    test('remove really removes', () async {
      final f = await openFixture();
      await f.settings.write('k', 'v');
      await f.settings.remove('k');
      expect(await f.settings.read('k'), isNull);
    });
  });
}
