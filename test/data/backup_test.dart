/// Backup and restore.
///
/// The restore path gets more attention than the backup path on purpose. A
/// backup that is never restored costs nothing when it is wrong; the one time
/// it is restored is the one time nobody can afford it to be wrong. So these
/// tests do real round trips against real files on disk: write bills, back up,
/// write more bills, restore, and check exactly which bills came back.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/backup_service.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:sqlite3/sqlite3.dart';

/// One open database on disk, with the ids needed to sell something.
class Fixture {
  Fixture(this.dir, this.db, this.deviceId, this.ownerId, this.itemId);

  final Directory dir;
  PosDatabase db;
  final String deviceId;
  final String ownerId;
  final String itemId;

  File get file => File(p.join(dir.path, kDatabaseFileName));

  BackupService service() => BackupService(db, databaseFile: file);
}

Future<Fixture> openFixture() async {
  final dir = Directory.systemTemp.createTempSync('pos-backup-');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  final db =
      PosDatabase(NativeDatabase(File(p.join(dir.path, kDatabaseFileName))));

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

  final f = Fixture(dir, db, r.deviceId, r.ownerId, item);
  // Closed by whichever database the test last opened, not by the one it
  // started with: a restore test replaces it halfway through.
  addTearDown(() => f.db.close());
  return f;
}

Future<SavedBill> sell(Fixture f, {int qty = 1}) async {
  final computed = computeBill(
    cart: [
      CartLine(
        itemId: f.itemId,
        nameSnapshot: 'Chicken Dum Biryani',
        unitPrice: Paise.fromRupees(240),
        qty: qty,
        taxClass: TaxClass.gst5,
      ),
    ],
    config: const TaxConfig(mode: TaxMode.regular5, pricesIncludeTax: false),
    orderType: OrderType.dine,
  );
  return BillRepository(f.db).commitSale(
    computed: computed,
    payments: [PaymentIntent(PaymentMode.cash, computed.total)],
    deviceId: f.deviceId,
    userId: f.ownerId,
  );
}

Future<List<String>> invoiceNumbers(PosDatabase db) async {
  final rows =
      await db.customSelect('SELECT invoice_no FROM bill ORDER BY device_seq').get();
  return rows.map((r) => r.read<String>('invoice_no')).toList();
}

void main() {
  group('making a backup', () {
    test('writes a file that holds the bills', () async {
      final f = await openFixture();
      await sell(f);
      await sell(f, qty: 2);

      final into = Directory(p.join(f.dir.path, 'out'));
      final result = await f.service().backupTo(into);

      expect(result, isA<BackupDone>());
      final done = result as BackupDone;
      expect(done.bills, 2);
      expect(done.bytes, greaterThan(0));
      expect(done.file.existsSync(), isTrue);
      expect(p.basename(done.file.path), startsWith('pos-backup-'));
      expect(p.basename(done.file.path), endsWith('.sqlite'));
    });

    test('includes writes still sitting in the write-ahead log', () async {
      // The bug this guards against: the database runs in WAL mode, so a
      // plain copy of pos.sqlite can be missing the most recent bills while
      // still opening cleanly. Such a backup looks perfectly good.
      final f = await openFixture();
      final journal = await f.db.customSelect('PRAGMA journal_mode').getSingle();
      expect(
        journal.data.values.first.toString().toLowerCase(),
        'wal',
        reason: 'if this is not WAL the test below proves nothing',
      );

      await sell(f);
      final last = await sell(f);

      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;

      final backup = sqlite3.open(done.file.path, mode: OpenMode.readOnly);
      addTearDown(backup.close);
      final numbers = backup
          .select('SELECT invoice_no FROM bill ORDER BY device_seq')
          .map((r) => r['invoice_no'] as String)
          .toList();

      expect(numbers, hasLength(2));
      expect(
        numbers,
        contains(last.invoiceNo.formatted),
        reason: 'the newest bill is the one a plain file copy would lose',
      );
    });

    test('creates the destination folder if it is not there', () async {
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'a', 'b', 'c'));
      expect(into.existsSync(), isFalse);

      expect(await f.service().backupTo(into), isA<BackupDone>());
      expect(into.existsSync(), isTrue);
    });

    test('two backups in the same minute do not collide', () async {
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final fixed = DateTime(2026, 11, 4, 2, 30);
      final service =
          BackupService(f.db, databaseFile: f.file, now: () => fixed);

      expect(await service.backupTo(into), isA<BackupDone>());
      expect(
        await service.backupTo(into),
        isA<BackupDone>(),
        reason: 'VACUUM INTO refuses an existing target, so the second run '
            'has to replace rather than fail',
      );
      expect(service.existingBackups(into), hasLength(1));
    });

    test('keeps the newest $kBackupsToKeep and removes the rest', () async {
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));

      for (var day = 1; day <= kBackupsToKeep + 6; day++) {
        final service = BackupService(
          f.db,
          databaseFile: f.file,
          now: () => DateTime(2026, 3, day, 2, 30),
        );
        expect(await service.backupTo(into), isA<BackupDone>());
      }

      final kept = f.service().existingBackups(into);
      expect(kept, hasLength(kBackupsToKeep));
      expect(
        p.basename(kept.first.path),
        'pos-backup-2026-03-20-0230.sqlite',
        reason: 'newest first',
      );
      expect(
        kept.map((e) => p.basename(e.path)),
        isNot(contains('pos-backup-2026-03-01-0230.sqlite')),
      );
    });

    test('a failure is reported, not thrown', () async {
      final f = await openFixture();
      await sell(f);
      // A file standing where the destination folder should be.
      final notADir = File(p.join(f.dir.path, 'in-the-way'))
        ..writeAsStringSync('x');

      final result = await f.service().backupTo(Directory(notADir.path));
      expect(result, isA<BackupFailed>());
      expect((result as BackupFailed).message, isNotEmpty);
    });
  });

  group('probing a destination', () {
    test('accepts a writable folder', () async {
      final f = await openFixture();
      expect(await f.service().probeWritable(f.dir), isNull);
    });

    test('leaves nothing behind', () async {
      final f = await openFixture();
      final dir = Directory(p.join(f.dir.path, 'probe'))..createSync();
      await f.service().probeWritable(dir);
      expect(dir.listSync(), isEmpty);
    });

    test('refuses a folder it cannot write to, in plain language', () async {
      final f = await openFixture();
      final dir = Directory(p.join(f.dir.path, 'ro'))..createSync();
      // 0o500: enter and list, but not create.
      final chmod = await Process.run('chmod', ['500', dir.path]);
      expect(chmod.exitCode, 0, reason: 'cannot set up the test otherwise');
      addTearDown(() => Process.runSync('chmod', ['700', dir.path]));

      final reason = await f.service().probeWritable(dir);
      expect(reason, isNotNull);
      expect(reason, contains('access'));
    }, skip: Platform.isWindows ? 'no POSIX modes' : false);
  });

  group('inspecting a candidate', () {
    test('a real backup is usable, and says what is in it', () async {
      final f = await openFixture();
      await sell(f);
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;

      final check = f.service().inspect(done.file);
      expect(check, isA<RestoreUsable>());
      final ok = check as RestoreUsable;
      expect(ok.bills, 2);
      expect(ok.schemaVersion, kSchemaVersion);
      expect(ok.newestBillAt, isNotNull);
    });

    test('a missing file', () async {
      final f = await openFixture();
      final check = f.service().inspect(File(p.join(f.dir.path, 'nope')));
      expect(check, isA<RestoreRefused>());
      expect((check as RestoreRefused).reason, contains('not there'));
    });

    test('an empty file', () async {
      final f = await openFixture();
      final empty = File(p.join(f.dir.path, 'empty.sqlite'))
        ..writeAsBytesSync(Uint8List(0));
      final check = f.service().inspect(empty);
      expect((check as RestoreRefused).reason, contains('empty'));
    });

    test('a file that is not a database at all', () async {
      final f = await openFixture();
      final junk = File(p.join(f.dir.path, 'photo.sqlite'))
        ..writeAsBytesSync(Uint8List.fromList(List.filled(4096, 7)));
      expect(f.service().inspect(junk), isA<RestoreRefused>());
    });

    test('a valid database from some other app', () async {
      final f = await openFixture();
      final other = File(p.join(f.dir.path, 'other.sqlite'));
      final db = sqlite3.open(other.path);
      db.execute('CREATE TABLE notes (body TEXT)');
      db.execute("INSERT INTO notes VALUES ('hello')");
      db.close();

      final check = f.service().inspect(other);
      expect(check, isA<RestoreRefused>());
      expect(
          (check as RestoreRefused).reason, contains('not one from this app'));
    });

    test('a backup from a newer version of the app is refused', () async {
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;

      final raised = sqlite3.open(done.file.path);
      raised.execute('PRAGMA user_version = ${kSchemaVersion + 5}');
      raised.close();

      final check = f.service().inspect(done.file);
      expect(check, isA<RestoreRefused>());
      final reason = (check as RestoreRefused).reason;
      expect(reason, contains('newer version'));
      expect(reason, contains('Update the app'));
    });

    test('a half-copied backup is refused', () async {
      // Truncation is what a real damaged backup looks like: the copy to the
      // SD card or the phone being unplugged partway through. Note that
      // scribbling over bytes in the middle of a small database does NOT
      // reliably fail integrity_check, because those pages are free space, so
      // this test truncates rather than pretending otherwise.
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;

      final bytes = done.file.readAsBytesSync();
      done.file.writeAsBytesSync(
        Uint8List.sublistView(bytes, 0, (bytes.length * 0.6).floor()),
      );

      final check = f.service().inspect(done.file);
      expect(check, isA<RestoreRefused>());
      expect((check as RestoreRefused).reason, isNotEmpty);
    });

    test('inspecting does not modify the file', () async {
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;

      final before = done.file.readAsBytesSync();
      f.service().inspect(done.file);
      expect(done.file.readAsBytesSync(), before);
    });
  });

  group('restoring, end to end', () {
    test('brings back exactly the bills the backup held', () async {
      final f = await openFixture();
      final first = await sell(f);
      final second = await sell(f);

      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;

      // Trading continues after the backup.
      final third = await sell(f);
      final fourth = await sell(f);
      expect(await invoiceNumbers(f.db), hasLength(4));

      expect(await f.service().stageRestore(done.file), isNull);

      // The app closes and reopens: this is where the swap happens.
      await f.db.close();
      final outcome = adoptStagedRestore(f.dir);
      expect(outcome.applied, isTrue);
      expect(outcome.bills, 2);

      f.db = PosDatabase(NativeDatabase(f.file));
      final after = await invoiceNumbers(f.db);

      expect(after, [first.invoiceNo.formatted, second.invoiceNo.formatted]);
      expect(after, isNot(contains(third.invoiceNo.formatted)));
      expect(after, isNot(contains(fourth.invoiceNo.formatted)));
    });

    test('the replaced database is kept aside, whole, not deleted', () async {
      // This test used to check only that ONE lost bill was in the kept copy,
      // and passed while the copy was missing most of them: the write-ahead
      // log was being deleted rather than moved with its database, so the
      // safety copy held 6 of 10 bills on a real device. Asserting the exact
      // count is what catches that, so the count is what is asserted.
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;

      // The bug only shows when the write-ahead log still holds data at the
      // moment of the swap, which is what a force-stop or a crash leaves
      // behind. Closing the database first checkpoints the log into the main
      // file and hides it completely, so this test must not close cleanly:
      // auto-checkpointing is turned off, the bills are taken, and the swap
      // happens with the connection still open, the way it does on a phone
      // whose app was killed.
      await f.db.customStatement('PRAGMA wal_autocheckpoint = 0');

      final after = <String>[];
      for (var i = 0; i < 9; i++) {
        after.add((await sell(f)).invoiceNo.formatted);
      }
      final before = await invoiceNumbers(f.db);
      expect(before, hasLength(10));

      final walBytes = File('${f.file.path}-wal').lengthSync();
      expect(
        walBytes,
        greaterThan(0),
        reason: 'without a non-empty write-ahead log this test proves nothing',
      );

      await f.service().stageRestore(done.file);
      adoptStagedRestore(f.dir);
      f.db = PosDatabase(NativeDatabase(f.file));

      final aside = f.dir
          .listSync()
          .whereType<File>()
          .where((e) =>
              p.basename(e.path).startsWith('pos.replaced-') &&
              e.path.endsWith('.sqlite'))
          .toList();
      expect(aside, hasLength(1), reason: 'a wrong restore must be recoverable');

      final old = sqlite3.open(aside.single.path, mode: OpenMode.readOnly);
      addTearDown(old.close);
      final numbers = old
          .select('SELECT invoice_no FROM bill ORDER BY device_seq')
          .map((r) => r['invoice_no'] as String)
          .toList();

      expect(
        numbers,
        before,
        reason: 'every bill, not just the ones that happened to be '
            'checkpointed out of the write-ahead log',
      );
      for (final n in after) {
        expect(numbers, contains(n));
      }
    });

    test('the kept-aside database can actually be opened and billed from',
        () async {
      // Undoing a wrong restore means opening that file as the database
      // again, so it has to be a working database and not just bytes.
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;
      await sell(f);
      await sell(f);

      await f.service().stageRestore(done.file);
      await f.db.close();
      adoptStagedRestore(f.dir);

      final aside = f.dir
          .listSync()
          .whereType<File>()
          .firstWhere((e) =>
              p.basename(e.path).startsWith('pos.replaced-') &&
              e.path.endsWith('.sqlite'));

      // Put it back, the way undoing a restore would.
      f.file.deleteSync();
      for (final suffix in const ['-wal', '-shm']) {
        final s = File('${f.file.path}$suffix');
        if (s.existsSync()) s.deleteSync();
      }
      aside.renameSync(f.file.path);
      for (final suffix in const ['-wal', '-shm']) {
        final s = File('${aside.path}$suffix');
        if (s.existsSync()) s.renameSync('${f.file.path}$suffix');
      }

      f.db = PosDatabase(NativeDatabase(f.file));
      expect(await invoiceNumbers(f.db), hasLength(3));

      // And it still bills, with the sequence carrying on.
      final next = await sell(f);
      expect(next.invoiceNo.formatted, 'A/2627/000004');
    });

    test('the old write-ahead log does not come back with it', () async {
      // Without this, the restored database opens and then shows the data the
      // restore was meant to replace.
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;
      await sell(f);

      expect(
        File('${f.file.path}-wal').existsSync(),
        isTrue,
        reason: 'the test needs a WAL file to exist to be worth running',
      );

      await f.service().stageRestore(done.file);
      await f.db.close();
      adoptStagedRestore(f.dir);

      expect(File('${f.file.path}-wal').existsSync(), isFalse);
      expect(File('${f.file.path}-shm').existsSync(), isFalse);
      f.db = PosDatabase(NativeDatabase(f.file));
    });

    test('a restored database still bills, with the sequence continuing',
        () async {
      // The point of a restore is to carry on trading, and the invoice
      // sequence has to pick up from the restored state rather than repeat a
      // number that is already on a printed bill.
      final f = await openFixture();
      await sell(f);
      final second = await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;
      await sell(f);

      await f.service().stageRestore(done.file);
      await f.db.close();
      adoptStagedRestore(f.dir);
      f.db = PosDatabase(NativeDatabase(f.file));

      final next = await sell(f);
      expect(next.invoiceNo.formatted, isNot(second.invoiceNo.formatted));
      expect(await invoiceNumbers(f.db), hasLength(3));
    });

    test('staging refuses a file that is not a usable backup', () async {
      final f = await openFixture();
      final junk = File(p.join(f.dir.path, 'junk.sqlite'))
        ..writeAsBytesSync(Uint8List.fromList(List.filled(2048, 3)));

      final reason = await f.service().stageRestore(junk);
      expect(reason, isNotNull);
      expect(f.service().hasStagedRestore(), isFalse);
    });

    test('nothing staged means nothing happens', () async {
      final f = await openFixture();
      final outcome = adoptStagedRestore(f.dir);
      expect(outcome.isNothing, isTrue);
      expect(outcome.applied, isFalse);
      expect(f.file.existsSync(), isTrue);
    });

    test(
        'a staged file damaged while waiting is refused, and the live '
        'database survives', () async {
      final f = await openFixture();
      final kept = await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;
      await f.service().stageRestore(done.file);

      // Something happens to the file between staging and the next start.
      final staged = File(p.join(f.dir.path, kStagedRestoreName));
      staged.writeAsBytesSync(Uint8List.fromList(List.filled(1024, 9)));

      await f.db.close();
      final outcome = adoptStagedRestore(f.dir);

      expect(outcome.applied, isFalse);
      expect(outcome.error, isNotNull);

      f.db = PosDatabase(NativeDatabase(f.file));
      expect(
        await invoiceNumbers(f.db),
        [kept.invoiceNo.formatted],
        reason: 'a bad restore must leave the live database alone',
      );
    });

    test('a refused staged file is not retried at every start', () async {
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;
      await f.service().stageRestore(done.file);
      File(p.join(f.dir.path, kStagedRestoreName))
          .writeAsBytesSync(Uint8List.fromList(List.filled(1024, 9)));

      await f.db.close();
      expect(adoptStagedRestore(f.dir).error, isNotNull);
      expect(
        adoptStagedRestore(f.dir).isNothing,
        isTrue,
        reason: 'a file that cannot be restored must be moved out of the way',
      );
      f.db = PosDatabase(NativeDatabase(f.file));
    });

    test('a staged restore can be cancelled before it is applied', () async {
      final f = await openFixture();
      final kept = await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;
      await sell(f);

      await f.service().stageRestore(done.file);
      expect(f.service().hasStagedRestore(), isTrue);
      f.service().cancelStagedRestore();
      expect(f.service().hasStagedRestore(), isFalse);

      await f.db.close();
      expect(adoptStagedRestore(f.dir).isNothing, isTrue);
      f.db = PosDatabase(NativeDatabase(f.file));
      expect(await invoiceNumbers(f.db), hasLength(2),
          reason: 'cancelling must leave both bills in place');
      expect(kept.invoiceNo.formatted, isNotEmpty);
    });

    test('a backup from an older schema is migrated when it is opened',
        () async {
      // Restoring last month's backup after an app update must not need the
      // owner to do anything about schema versions.
      final f = await openFixture();
      await sell(f);
      final into = Directory(p.join(f.dir.path, 'out'));
      final done = await f.service().backupTo(into) as BackupDone;

      // Make it look like a v1 backup, the version actually on the device.
      final aged = sqlite3.open(done.file.path);
      aged.execute('PRAGMA user_version = 1');
      aged.close();

      final check = f.service().inspect(done.file);
      expect(check, isA<RestoreUsable>(),
          reason: 'an older backup is restorable');
      expect((check as RestoreUsable).schemaVersion, 1);

      expect(await f.service().stageRestore(done.file), isNull);
      await f.db.close();
      expect(adoptStagedRestore(f.dir).applied, isTrue);

      // Opening it runs the migration.
      f.db = PosDatabase(NativeDatabase(f.file));
      final row = await f.db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), kSchemaVersion);
      expect(await invoiceNumbers(f.db), hasLength(1));
    });
  });
}
