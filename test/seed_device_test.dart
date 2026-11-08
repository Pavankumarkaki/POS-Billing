/// Not a test: a way to build a seeded database file for the emulator.
///
/// Skipped in a normal run; see dart_test.yaml. Run it with:
///
///     flutter test test/seed_device_test.dart --run-skipped
///
/// Then push build/seed.sqlite to the device as pos.sqlite.restore and restart
/// the app, which makes the restore path do the installing. Driving first-run
/// setup through adb taps is slow and error-prone, and this uses the app's own
/// repositories, so the result is a database the app really would have
/// written rather than one assembled by hand.
@Tags(['seed'])
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';

void main() {
  test('writes build/seed.sqlite', () async {
    final file = File('build/seed.sqlite');
    if (file.existsSync()) file.deleteSync();
    for (final s in const ['-wal', '-shm']) {
      final f = File('${file.path}$s');
      if (f.existsSync()) f.deleteSync();
    }

    final db = PosDatabase(NativeDatabase(file));
    final setup = SetupRepository(db);
    final r = await setup.completeSetup(
      const SetupDetails(
        outletName: 'Annapurna Mess',
        address: 'Main Road, Guntur',
        phone: '9000000000',
        fssaiNo: '12345678901234',
        taxMode: TaxMode.regular5,
        gstin: '37ABCDE1234F1Z5',
        ownerName: 'Ravi',
        ownerPin: '1357',
        devicePrefix: 'A',
      ),
      at: DateTime(2026, 4, 1, 10),
    );

    final menu = MenuRepository(db, deviceId: r.deviceId);
    final cat = await menu.createCategory(nameEn: 'Biryani', byUserId: r.ownerId);
    await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: r.ownerId,
    );

    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    await db.close();

    expect(file.existsSync(), isTrue);
    // ignore: avoid_print
    print('seed written: ${file.absolute.path} (${file.lengthSync()} bytes)');
  });
}
