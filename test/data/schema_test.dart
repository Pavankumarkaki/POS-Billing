/// The schema itself: that a fresh database comes up complete, that the
/// constraints the brief relies on are real, and that the tax-mode wire
/// values match what the brief specifies.
///
/// Note on migrations: Phase 1 ships schema v1, so there is no upgrade step to
/// exercise yet. What is tested here is that a fresh create is correct and
/// that `kSchemaVersion` and the migration strategy agree. The step-by-step
/// migration test arrives with v2, and `onUpgrade` throws by default rather
/// than silently doing nothing if a version is added without one.
library;

// drift exports isNull/isNotNull as SQL expression helpers, which collide
// with flutter_test's matchers of the same name.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/converters.dart';
import 'package:restaurant_pos/data/db.dart';

import 'fixture.dart';

void main() {
  group('a fresh database', () {
    late PosDatabase db;

    setUp(() => db = PosDatabase.memory());
    tearDown(() => db.close());

    test('creates every table the brief names', () async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
          .get();
      final names = rows.map((r) => r.read<String>('name')).toSet();

      for (final expected in [
        'outlet',
        'tax_profile_history',
        'device',
        'user',
        'category',
        'item',
        'bill',
        'bill_line',
        'payment',
        'audit_log',
        'outbox',
      ]) {
        expect(names, contains(expected));
      }
    });

    test('reports the schema version it was built at', () async {
      expect(db.schemaVersion, kSchemaVersion);
      final row = await db.customSelect('PRAGMA user_version').getSingle();
      expect(row.read<int>('user_version'), kSchemaVersion);
    });

    test('foreign keys are enforced, not just declared', () async {
      final row = await db.customSelect('PRAGMA foreign_keys').getSingle();
      expect(row.read<int>('foreign_keys'), 1);
    });

    test('a bill line cannot point at a bill that does not exist', () async {
      await expectLater(
        db.into(db.billLines).insert(BillLinesCompanion.insert(
              id: 'line-1',
              billId: 'no-such-bill',
              itemId: 'x',
              nameSnapshot: 'x',
              qty: 1,
              unitPrice: const Paise(100),
              taxRate: 500,
              lineDiscount: Paise.zero,
              lineTotal: const Paise(105),
              taxable: const Paise(100),
              cgst: const Paise(3),
              sgst: const Paise(2),
            )),
        throwsA(anything),
      );
    });

    test('the indexes the reports rely on exist', () async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
          .get();
      final names = rows.map((r) => r.read<String>('name')).toSet();

      for (final expected in [
        'idx_bill_business_date',
        'idx_bill_device_fy',
        'idx_bill_invoice_no',
        'idx_bill_line_bill',
        'idx_payment_bill',
        'idx_item_category',
        'idx_audit_entity',
        'idx_outbox_unsent',
      ]) {
        expect(names, contains(expected));
      }
    });
  });

  group('money is stored as integer paise, never a float', () {
    test('every money column is declared INTEGER', () async {
      final db = PosDatabase.memory();
      addTearDown(db.close);

      const moneyColumns = {
        'bill': [
          'subtotal',
          'discount',
          'taxable',
          'cgst',
          'sgst',
          'round_off',
          'total',
          'composition_turnover',
        ],
        'bill_line': [
          'unit_price',
          'line_discount',
          'line_total',
          'taxable',
          'cgst',
          'sgst',
        ],
        'payment': ['amount'],
        'item': ['price_paise'],
      };

      for (final entry in moneyColumns.entries) {
        final info =
            await db.customSelect('PRAGMA table_info(${entry.key})').get();
        final types = {
          for (final r in info)
            r.read<String>('name'): r.read<String>('type').toUpperCase(),
        };
        for (final col in entry.value) {
          expect(types[col], 'INTEGER',
              reason: '${entry.key}.$col must be INTEGER paise');
        }
      }
    });

    test('a money value round trips exactly', () async {
      final f = await Fixture.create();
      addTearDown(f.close);

      // An amount that a double would mangle.
      await (f.db.update(f.db.items)..where((i) => i.id.equals(kItemBiryani)))
          .write(ItemsCompanion(
        pricePaise: const Value(Paise(24049)),
        updatedAt: Value(DateTime(2026, 6, 1)),
      ));

      final item = await (f.db.select(f.db.items)
            ..where((i) => i.id.equals(kItemBiryani)))
          .getSingle();
      expect(item.pricePaise.value, 24049);
      expect(item.pricePaise.plain, '240.49');
    });
  });

  group('enums are stored as the brief spells them', () {
    test('tax modes', () async {
      for (final mode in TaxMode.values) {
        final f = await Fixture.create(taxMode: mode);
        final row = await f.db
            .customSelect('SELECT tax_mode FROM outlet')
            .getSingle();
        expect(row.read<String>('tax_mode'), mode.wireName);
        await f.close();
      }

      expect(TaxMode.regular5.wireName, 'regular_5');
      expect(TaxMode.regular18.wireName, 'regular_18');
      expect(TaxMode.unregistered.wireName, 'unregistered');
      expect(TaxMode.composition.wireName, 'composition');
    });

    test('tax classes', () async {
      final f = await Fixture.create();
      addTearDown(f.close);
      final rows = await f.db
          .customSelect('SELECT tax_class FROM item ORDER BY tax_class')
          .get();
      final values = rows.map((r) => r.read<String>('tax_class')).toSet();
      expect(values, {'gst5', 'gst18', 'non_gst'});
    });

    test('doc types and order types', () {
      expect(DocType.billOfSupply.wireName, 'bill_of_supply');
      expect(DocType.creditNote.wireName, 'credit_note');
      expect(OrderType.aggregator.wireName, 'aggregator');
    });

    test('every wire value round trips through its converter', () {
      for (final m in TaxMode.values) {
        expect(TaxModeWire.parse(m.wireName), m);
      }
      for (final c in TaxClass.values) {
        expect(TaxClassWire.parse(c.wireName), c);
      }
      for (final d in DocType.values) {
        expect(DocTypeWire.parse(d.wireName), d);
      }
      for (final o in OrderType.values) {
        expect(OrderTypeWire.parse(o.wireName), o);
      }
    });
  });

  group('business dates and financial years store readably', () {
    test('a business date is ISO text that sorts correctly', () async {
      final f = await Fixture.create();
      addTearDown(f.close);

      final info = await f.db.customSelect('PRAGMA table_info(bill)').get();
      final type = info
          .firstWhere((r) => r.read<String>('name') == 'business_date')
          .read<String>('type')
          .toUpperCase();
      expect(type, 'TEXT');
    });

    test('a financial year round trips through its converter', () {
      const conv = FinancialYearConverter();
      for (final y in [2000, 2026, 2099]) {
        final fy = FinancialYear(y);
        expect(conv.fromSql(conv.toSql(fy)), fy);
      }
    });

    test('a business date round trips through its converter', () {
      const conv = BusinessDateConverter();
      final d = const BusinessDate(2026, 3, 2);
      expect(conv.toSql(d), '2026-03-02');
      expect(conv.fromSql('2026-03-02'), d);
    });

    test('a corrupt stored date is rejected, not silently accepted', () {
      const conv = BusinessDateConverter();
      expect(() => conv.fromSql('not-a-date'),
          throwsA(isA<UnknownWireValue>()));
      expect(() => conv.fromSql('2026-02-31'),
          throwsA(isA<UnknownWireValue>()));
    });
  });

  group('the unique constraints that protect the numbering', () {
    test('two bills cannot share a device sequence', () async {
      final f = await Fixture.create();
      addTearDown(f.close);

      Future<void> insert(int seq, String id, String no) =>
          f.db.into(f.db.bills).insert(BillsCompanion.insert(
                id: id,
                deviceId: kDeviceId,
                deviceSeq: seq,
                invoiceNo: no,
                fy: const FinancialYear(2026),
                businessDate: const BusinessDate(2026, 6, 1),
                docType: DocType.invoice,
                createdAt: DateTime(2026, 6, 1, 13),
                status: BillStatus.paid,
                orderType: OrderType.dine,
                subtotal: const Paise(24000),
                discount: Paise.zero,
                taxable: const Paise(24000),
                cgst: const Paise(600),
                sgst: const Paise(600),
                roundOff: Paise.zero,
                total: const Paise(25200),
                createdBy: kOwnerId,
              ));

      await insert(1, 'bill-1', 'A/2627/000001');
      await expectLater(
        insert(1, 'bill-2', 'A/2627/000002'),
        throwsA(anything),
        // Same (device_id, device_seq).
      );
    });

    test('two bills in a year cannot share an invoice number', () async {
      final f = await Fixture.create();
      addTearDown(f.close);

      Future<void> insert(int seq, String id, String no) =>
          f.db.into(f.db.bills).insert(BillsCompanion.insert(
                id: id,
                deviceId: kDeviceId,
                deviceSeq: seq,
                invoiceNo: no,
                fy: const FinancialYear(2026),
                businessDate: const BusinessDate(2026, 6, 1),
                docType: DocType.invoice,
                createdAt: DateTime(2026, 6, 1, 13),
                status: BillStatus.paid,
                orderType: OrderType.dine,
                subtotal: const Paise(24000),
                discount: Paise.zero,
                taxable: const Paise(24000),
                cgst: const Paise(600),
                sgst: const Paise(600),
                roundOff: Paise.zero,
                total: const Paise(25200),
                createdBy: kOwnerId,
              ));

      await insert(1, 'bill-1', 'A/2627/000001');
      await expectLater(
        insert(2, 'bill-2', 'A/2627/000001'),
        throwsA(anything),
      );
    });

    test('an invoice number column cannot hold more than 16 characters',
        () async {
      final f = await Fixture.create();
      addTearDown(f.close);

      await expectLater(
        f.db.into(f.db.bills).insert(BillsCompanion.insert(
              id: 'bill-long',
              deviceId: kDeviceId,
              deviceSeq: 1,
              invoiceNo: 'A/2627/0000001234567890',
              fy: const FinancialYear(2026),
              businessDate: const BusinessDate(2026, 6, 1),
              docType: DocType.invoice,
              createdAt: DateTime(2026, 6, 1, 13),
              status: BillStatus.paid,
              orderType: OrderType.dine,
              subtotal: const Paise(24000),
              discount: Paise.zero,
              taxable: const Paise(24000),
              cgst: const Paise(600),
              sgst: const Paise(600),
              roundOff: Paise.zero,
              total: const Paise(25200),
              createdBy: kOwnerId,
            )),
        throwsA(anything),
      );
    });
  });

  group('the outbox is ready for a later sync phase', () {
    test('op_id is the primary key, so a resend cannot duplicate', () async {
      final db = PosDatabase.memory();
      addTearDown(db.close);

      await db.into(db.outbox).insert(OutboxCompanion.insert(
            opId: 'op-1',
            entity: AuditEntity.bill,
            payload: '{}',
            createdAt: DateTime(2026, 6, 1),
          ));
      await expectLater(
        db.into(db.outbox).insert(OutboxCompanion.insert(
              opId: 'op-1',
              entity: AuditEntity.bill,
              payload: '{}',
              createdAt: DateTime(2026, 6, 1),
            )),
        throwsA(anything),
      );
    });

    test('sent_at starts null', () async {
      final db = PosDatabase.memory();
      addTearDown(db.close);

      await db.into(db.outbox).insert(OutboxCompanion.insert(
            opId: 'op-1',
            entity: AuditEntity.bill,
            payload: '{}',
            createdAt: DateTime(2026, 6, 1),
          ));
      final row = await db.select(db.outbox).getSingle();
      expect(row.sentAt, isNull);
    });
  });

  group('credit notes stay in the schema, unused', () {
    test('doc_type accepts credit_note and ref_bill_id exists', () async {
      final info = await PosDatabase.memory().customSelect(
        'PRAGMA table_info(bill)',
      ).get();
      final names = info.map((r) => r.read<String>('name')).toSet();
      expect(names, contains('ref_bill_id'));
      expect(names, contains('doc_type'));
      expect(DocType.values, contains(DocType.creditNote));
    });
  });

  group('the invoice numbering constraint spans the financial year', () {
    test('the same device_seq is allowed in a different year', () async {
      final f = await Fixture.create();
      addTearDown(f.close);

      Future<void> insert(FinancialYear fy, String id, String no) =>
          f.db.into(f.db.bills).insert(BillsCompanion.insert(
                id: id,
                deviceId: kDeviceId,
                deviceSeq: 1,
                invoiceNo: no,
                fy: fy,
                businessDate: BusinessDate(fy.startYear, 6, 1),
                docType: DocType.invoice,
                createdAt: DateTime(fy.startYear, 6, 1, 13),
                status: BillStatus.paid,
                orderType: OrderType.dine,
                subtotal: const Paise(24000),
                discount: Paise.zero,
                taxable: const Paise(24000),
                cgst: const Paise(600),
                sgst: const Paise(600),
                roundOff: Paise.zero,
                total: const Paise(25200),
                createdBy: kOwnerId,
              ));

      await insert(const FinancialYear(2026), 'bill-a', 'A/2627/000001');

      // The sequence restarts each April, so seq 1 recurs. Under the brief's
      // literal UNIQUE(device_id, device_seq) this threw, and the app would
      // have refused its first bill of the new year on 1 April.
      await insert(const FinancialYear(2027), 'bill-b', 'A/2728/000001');

      expect(await f.db.select(f.db.bills).get(), hasLength(2));
    });

    test('a genuine duplicate within one year is still refused', () async {
      final f = await Fixture.create();
      addTearDown(f.close);

      Future<void> insert(String id, String no) =>
          f.db.into(f.db.bills).insert(BillsCompanion.insert(
                id: id,
                deviceId: kDeviceId,
                deviceSeq: 1,
                invoiceNo: no,
                fy: const FinancialYear(2026),
                businessDate: const BusinessDate(2026, 6, 1),
                docType: DocType.invoice,
                createdAt: DateTime(2026, 6, 1, 13),
                status: BillStatus.paid,
                orderType: OrderType.dine,
                subtotal: const Paise(24000),
                discount: Paise.zero,
                taxable: const Paise(24000),
                cgst: const Paise(600),
                sgst: const Paise(600),
                roundOff: Paise.zero,
                total: const Paise(25200),
                createdBy: kOwnerId,
              ));

      await insert('bill-a', 'A/2627/000001');
      await expectLater(
        insert('bill-b', 'A/2627/000002'),
        throwsA(anything),
        reason: 'same device, same year, same sequence',
      );
    });
  });
}
