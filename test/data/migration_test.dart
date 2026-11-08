/// Migrations.
///
/// The v1 to v2 step recreates the `bill` table to widen a unique constraint,
/// and recreating a table is the migration most likely to lose data. There is
/// already a database on a device with real bills in it, so this checks the
/// rows survive rather than assuming they do.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/db.dart';

/// Builds a v1 database by hand: the old schema, with the old constraint.
///
/// Hand-written rather than generated, because the point is to reproduce
/// exactly what is on a device that installed the earlier build.
Future<PosDatabase> openV1() async {
  final executor = NativeDatabase.memory();
  final db = PosDatabase(executor);

  // Let drift create the current schema, then put the OLD constraint back by
  // recreating `bill` the way v1 had it.
  await db.customStatement('SELECT 1');

  await db.customStatement('DROP TABLE bill');
  await db.customStatement('''
    CREATE TABLE bill (
      id TEXT NOT NULL,
      device_id TEXT NOT NULL REFERENCES device (id),
      device_seq INTEGER NOT NULL,
      invoice_no TEXT NOT NULL,
      fy TEXT NOT NULL,
      business_date TEXT NOT NULL,
      doc_type TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      status TEXT NOT NULL,
      order_type TEXT NOT NULL,
      subtotal INTEGER NOT NULL,
      discount INTEGER NOT NULL,
      taxable INTEGER NOT NULL,
      cgst INTEGER NOT NULL,
      sgst INTEGER NOT NULL,
      round_off INTEGER NOT NULL,
      total INTEGER NOT NULL,
      cancel_reason TEXT NULL,
      cancelled_by TEXT NULL REFERENCES user (id),
      ref_bill_id TEXT NULL,
      created_by TEXT NOT NULL REFERENCES user (id),
      composition_turnover INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (id),
      UNIQUE (device_id, device_seq),
      UNIQUE (fy, invoice_no)
    )
  ''');
  await db.customStatement('PRAGMA user_version = 1');

  return db;
}

/// Builds a v2 database: the current schema minus the v3 snapshot columns.
Future<PosDatabase> openV2() async {
  final db = PosDatabase(NativeDatabase.memory());
  await db.customStatement('SELECT 1');

  for (final column in const [
    'outlet_name',
    'outlet_address',
    'outlet_phone',
    'outlet_fssai_no',
    'outlet_gstin',
    'outlet_sac_code',
  ]) {
    await db.customStatement('ALTER TABLE bill DROP COLUMN $column');
  }
  await db.customStatement('PRAGMA user_version = 2');
  return db;
}

void main() {
  group('the v1 to v2 migration', () {
    test('a v1 database really does reject the new year', () async {
      // Establishes that the bug being fixed was real, so the migration is
      // not solving an imagined problem.
      final db = await openV1();
      addTearDown(db.close);
      await _seed(db);

      await _insertBill(db, fy: 2026, seq: 1, no: 'A/2627/000001');
      await expectLater(
        _insertBill(db, fy: 2027, seq: 1, no: 'A/2728/000001'),
        throwsA(anything),
        reason: 'this is the failure the migration exists to remove',
      );
    });

    test('keeps every bill, with its number and amounts', () async {
      final db = await openV1();
      addTearDown(db.close);
      await _seed(db);

      await _insertBill(db, fy: 2026, seq: 1, no: 'A/2627/000001');
      await _insertBill(db, fy: 2026, seq: 2, no: 'A/2627/000002');
      await _insertBill(
        db,
        fy: 2026,
        seq: 3,
        no: 'A/2627/000003',
        cancelled: true,
      );

      await _migrate(db);

      final bills = await (db.select(db.bills)
            ..orderBy([(b) => OrderingTerm.asc(b.deviceSeq)]))
          .get();

      expect(bills, hasLength(3));
      expect(
        bills.map((b) => b.invoiceNo),
        ['A/2627/000001', 'A/2627/000002', 'A/2627/000003'],
      );
      expect(bills.every((b) => b.total.value == 25200), isTrue);
      expect(bills.last.status, BillStatus.cancelled);
      expect(bills.last.cancelReason, 'Wrong item entered');
    });

    test('and afterwards the new financial year is accepted', () async {
      final db = await openV1();
      addTearDown(db.close);
      await _seed(db);

      await _insertBill(db, fy: 2026, seq: 1, no: 'A/2627/000001');
      await _migrate(db);

      // The thing v1 refused.
      await _insertBill(db, fy: 2027, seq: 1, no: 'A/2728/000001');

      expect(await db.select(db.bills).get(), hasLength(2));
    });

    test('a duplicate within one year is still refused afterwards',
        () async {
      final db = await openV1();
      addTearDown(db.close);
      await _seed(db);

      await _insertBill(db, fy: 2026, seq: 1, no: 'A/2627/000001');
      await _migrate(db);

      await expectLater(
        _insertBill(db, fy: 2026, seq: 1, no: 'A/2627/000009'),
        throwsA(anything),
        reason: 'widening the key must not weaken it within a year',
      );
    });

    test('the lines and payments of a migrated bill still resolve',
        () async {
      final db = await openV1();
      addTearDown(db.close);
      await _seed(db);
      await _insertBill(db, fy: 2026, seq: 1, no: 'A/2627/000001');

      await db.into(db.billLines).insert(BillLinesCompanion.insert(
            id: 'line-1',
            billId: 'bill-2026-1',
            itemId: 'item-x',
            nameSnapshot: 'Chicken Dum Biryani',
            qty: 1,
            unitPrice: const Paise(24000),
            taxRate: 500,
            lineDiscount: Paise.zero,
            lineTotal: const Paise(25200),
            taxable: const Paise(24000),
            cgst: const Paise(600),
            sgst: const Paise(600),
          ));

      await _migrate(db);

      final lines = await db.select(db.billLines).get();
      expect(lines, hasLength(1));
      expect(lines.single.billId, 'bill-2026-1');

      // The foreign key must still point at a bill that exists.
      final bill = await (db.select(db.bills)
            ..where((b) => b.id.equals(lines.single.billId)))
          .getSingleOrNull();
      expect(bill, isNotNull,
          reason: 'recreating a table must not orphan its children');
    });
  });

  group('the v2 to v3 migration', () {
    test('adds the header columns and keeps every bill', () async {
      final db = await openV2();
      addTearDown(db.close);
      await _seed(db);
      await _insertBill(db, fy: 2026, seq: 1, no: 'A/2627/000001');
      await _insertBill(db, fy: 2026, seq: 2, no: 'A/2627/000002');

      await _migrateFrom(db, 2);

      final bills = await (db.select(db.bills)
            ..orderBy([(b) => OrderingTerm.asc(b.deviceSeq)]))
          .get();
      expect(bills, hasLength(2));
      expect(bills.map((b) => b.invoiceNo),
          ['A/2627/000001', 'A/2627/000002']);
      expect(bills.every((b) => b.total.value == 25200), isTrue);
    });

    test('bills from before it have no snapshot, rather than a wrong one',
        () async {
      // Backfilling would stamp today's outlet details onto bills issued
      // under different ones, which is the bug the snapshot exists to fix.
      final db = await openV2();
      addTearDown(db.close);
      await _seed(db);
      await _insertBill(db, fy: 2026, seq: 1, no: 'A/2627/000001');

      await _migrateFrom(db, 2);

      final bill = await db.select(db.bills).getSingle();
      expect(bill.outletName, isNull);
      expect(bill.outletFssaiNo, isNull);
      expect(bill.outletGstin, isNull);
    });

    test('a bill written after it carries the header', () async {
      final db = await openV2();
      addTearDown(db.close);
      await _seed(db);
      await _migrateFrom(db, 2);

      await _insertBill(db, fy: 2026, seq: 1, no: 'A/2627/000001');
      // _insertBill does not set them, so this only proves the columns
      // accept values; commitSale filling them is covered in
      // test/printing/reprint_header_test.dart.
      await (db.update(db.bills)..where((b) => b.deviceSeq.equals(1)))
          .write(const BillsCompanion(
        outletName: Value('Annapurna Mess'),
        outletFssaiNo: Value('12345678901234'),
      ));

      final bill = await db.select(db.bills).getSingle();
      expect(bill.outletName, 'Annapurna Mess');
      expect(bill.outletFssaiNo, '12345678901234');
    });
  });

  group('schema version', () {
    test('a fresh database is at the current version', () async {
      final db = PosDatabase.memory();
      addTearDown(db.close);
      final row = await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), kSchemaVersion);
      expect(kSchemaVersion, 3);
    });

    test('every version from 1 to the current one has a step', () async {
      // If schemaVersion is raised without a migration, onUpgrade throws.
      for (var from = 1; from < kSchemaVersion; from++) {
        final db = await openV1();
        addTearDown(db.close);
        await _seed(db);
        await expectLater(_migrate(db), completes, reason: 'v$from');
      }
    });
  });
}

/// Runs the real onUpgrade path from v1.
Future<void> _migrate(PosDatabase db) => _migrateFrom(db, 1);

/// Runs the real onUpgrade path from [from] to the current version.
Future<void> _migrateFrom(PosDatabase db, int from) async {
  final migrator = db.createMigrator();
  await db.migration.onUpgrade(migrator, from, kSchemaVersion);
  await db.customStatement('PRAGMA user_version = $kSchemaVersion');
}

Future<void> _seed(PosDatabase db) async {
  await db.into(db.outlets).insert(OutletsCompanion.insert(
        id: 'outlet-1',
        name: 'Annapurna Mess',
        address: 'Main Road',
        phone: '9000000000',
        fssaiNo: '12345678901234',
        taxMode: TaxMode.regular5,
      ));
  await db.into(db.devices).insert(DevicesCompanion.insert(
        id: 'device-1',
        outletId: 'outlet-1',
        seriesPrefix: 'A',
        seqFy: const FinancialYear(2026),
      ));
  await db.into(db.users).insert(UsersCompanion.insert(
        id: 'user-owner',
        name: 'Ravi',
        role: UserRole.owner,
        pinHash: 'test',
      ));
}

Future<void> _insertBill(
  PosDatabase db, {
  required int fy,
  required int seq,
  required String no,
  bool cancelled = false,
}) =>
    db.into(db.bills).insert(BillsCompanion.insert(
          id: 'bill-$fy-$seq',
          deviceId: 'device-1',
          deviceSeq: seq,
          invoiceNo: no,
          fy: FinancialYear(fy),
          businessDate: BusinessDate(fy, 6, 1),
          docType: DocType.invoice,
          createdAt: DateTime(fy, 6, 1, 13),
          status: cancelled ? BillStatus.cancelled : BillStatus.paid,
          orderType: OrderType.dine,
          subtotal: const Paise(24000),
          discount: Paise.zero,
          taxable: const Paise(24000),
          cgst: const Paise(600),
          sgst: const Paise(600),
          roundOff: Paise.zero,
          total: const Paise(25200),
          createdBy: 'user-owner',
          cancelReason:
              cancelled ? const Value('Wrong item entered') : const Value.absent(),
        ));
