/// The brief's hardest rule: the bill, its lines, its payments, the audit
/// entry, the outbox entry and the sequence increment commit in ONE
/// transaction. A failure at any point must leave no partial bill and no
/// skipped invoice number.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/tables.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late BillRepository repo;

  setUp(() async {
    f = await Fixture.create();
    repo = BillRepository(f.db);
  });

  tearDown(() => f.close());

  Future<SavedBill> sell({
    List<CartLine>? lines,
    OrderType orderType = OrderType.dine,
    String userId = kOwnerId,
    DateTime? at,
    SaleFailureHook? failAt,
    List<PaymentIntent>? payments,
  }) async {
    final computed = await f.compute(lines: lines, orderType: orderType);
    return repo.commitSale(
      computed: computed,
      payments: payments ??
          [PaymentIntent(PaymentMode.cash, computed.total)],
      deviceId: kDeviceId,
      userId: userId,
      at: at ?? DateTime(2026, 6, 1, 13, 30),
      failAt: failAt,
    );
  }

  group('a successful sale writes all six things once', () {
    test('everything lands', () async {
      final saved = await sell();

      expect(await f.billCount(), 1);
      expect(await f.lineCount(), 1);
      expect(await f.paymentCount(), 1);
      expect(await f.auditCount(), 1);
      expect(await f.outboxCount(), 1);
      expect(await f.nextSeq(), 2, reason: 'the sequence advanced by one');

      expect(saved.invoiceNo.formatted, 'A/2627/000001');
      expect(saved.deviceSeq, 1);
      expect(saved.businessDate.iso, '2026-06-01');
    });

    test('the stored bill matches what was computed', () async {
      final saved = await sell();
      final row = await f.db.select(f.db.bills).getSingle();

      expect(row.id, saved.id);
      expect(row.invoiceNo, 'A/2627/000001');
      expect(row.deviceSeq, 1);
      expect(row.fy.code, '2627');
      expect(row.status, BillStatus.paid);
      expect(row.docType, DocType.invoice);
      expect(row.orderType, OrderType.dine);
      expect(row.createdBy, kOwnerId);

      expect(row.subtotal.value, 24000);
      expect(row.taxable.value, 24000);
      expect(row.cgst.value, 600);
      expect(row.sgst.value, 600);
      expect(row.total.value, 25200);
      expect(row.roundOff.value, 0);
    });

    test('the sequence advances one per sale', () async {
      final a = await sell();
      final b = await sell();
      final c = await sell();

      expect(a.invoiceNo.formatted, 'A/2627/000001');
      expect(b.invoiceNo.formatted, 'A/2627/000002');
      expect(c.invoiceNo.formatted, 'A/2627/000003');
      expect(await f.nextSeq(), 4);
    });

    test('invoice numbers are unique across many sales', () async {
      final numbers = <String>{};
      for (var i = 0; i < 50; i++) {
        numbers.add((await sell()).invoiceNo.formatted);
      }
      expect(numbers, hasLength(50));
      expect(await f.nextSeq(), 51);
    });

    test('a split payment writes one row per tender', () async {
      final computed = await f.compute();
      // 252.00 total, split across cash and UPI.
      await repo.commitSale(
        computed: computed,
        payments: [
          PaymentIntent(PaymentMode.cash, Paise.fromRupees(200)),
          PaymentIntent(PaymentMode.upi, Paise.fromRupees(52)),
        ],
        deviceId: kDeviceId,
        userId: kOwnerId,
        at: DateTime(2026, 6, 1, 13, 30),
      );

      final pays = await f.db.select(f.db.payments).get();
      expect(pays, hasLength(2));
      expect(
        pays.fold(Paise.zero, (Paise s, p) => s + p.amount).value,
        25200,
      );
      expect(pays.map((p) => p.mode).toSet(),
          {PaymentMode.cash, PaymentMode.upi});
    });

    test('the lines carry their own tax split', () async {
      await sell(lines: f.cart(withColdDrink: true, withWater: true));
      final lines = await f.db.select(f.db.billLines).get();
      expect(lines, hasLength(3));

      final biryani = lines.firstWhere((l) => l.itemId == kItemBiryani);
      expect(biryani.taxRate, 500);
      expect(biryani.cgst.value, 600);

      final drink = lines.firstWhere((l) => l.itemId == kItemColdDrink);
      expect(drink.taxRate, 1800, reason: 'the item rate wins');
      expect(drink.cgst.value, 900);

      final water = lines.firstWhere((l) => l.itemId == kItemWater);
      expect(water.taxRate, 0);
      expect(water.cgst.value, 0);
    });
  });

  group('rollback: a failure at any of the six writes leaves nothing', () {
    for (final stage in SaleStage.values) {
      test('failing at $stage leaves no trace and no skipped number',
          () async {
        expect(
          () => sell(
            failAt: (s) {
              if (s == stage) throw StateError('injected failure at $s');
            },
          ),
          throwsA(isA<StateError>()),
        );
        // Let the failed future settle before asserting.
        await Future<void>.delayed(Duration.zero);

        expect(await f.billCount(), 0, reason: 'no partial bill');
        expect(await f.lineCount(), 0, reason: 'no orphan lines');
        expect(await f.paymentCount(), 0, reason: 'no orphan payments');
        expect(await f.auditCount(), 0, reason: 'no audit entry');
        expect(await f.outboxCount(), 0, reason: 'no outbox entry');
        expect(
          await f.nextSeq(),
          1,
          reason: 'the sequence increment rolled back, so no number is skipped',
        );
      });
    }

    test('the next sale after a failure takes the number that was rolled back',
        () async {
      // Fail once, late in the transaction.
      await expectLater(
        sell(
          failAt: (s) {
            if (s == SaleStage.afterOutboxInsert) {
              throw StateError('injected');
            }
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(await f.nextSeq(), 1);

      // Then succeed. It must get 000001, not 000002.
      final saved = await sell();
      expect(saved.invoiceNo.formatted, 'A/2627/000001');
      expect(await f.billCount(), 1);
    });

    test('a failure between two good sales does not disturb the series',
        () async {
      final first = await sell();

      await expectLater(
        sell(
          failAt: (s) {
            if (s == SaleStage.afterBillInsert) throw StateError('injected');
          },
        ),
        throwsA(isA<StateError>()),
      );

      final third = await sell();

      expect(first.invoiceNo.formatted, 'A/2627/000001');
      expect(third.invoiceNo.formatted, 'A/2627/000002',
          reason: 'the failed sale consumed no number');
      expect(await f.billCount(), 2);
    });
  });

  group('the FSSAI gate blocks billing', () {
    test('an empty FSSAI number stops the sale', () async {
      final bad = await Fixture.create(fssai: '00000000000000');
      // Overwrite with something invalid: a short number.
      await bad.db.customStatement(
        "UPDATE outlet SET fssai_no = '123' WHERE id = '$kOutletId'",
      );
      final r = BillRepository(bad.db);
      final computed = await bad.compute();

      await expectLater(
        r.commitSale(
          computed: computed,
          payments: [PaymentIntent(PaymentMode.cash, computed.total)],
          deviceId: kDeviceId,
          userId: kOwnerId,
        ),
        throwsA(isA<SaleError>().having(
          (e) => e.message,
          'message',
          contains('FSSAI'),
        )),
      );
      expect(await bad.billCount(), 0);
      expect(await bad.nextSeq(), 1, reason: 'no number consumed');
      await bad.close();
    });

    test('a 14-digit number is accepted', () async {
      expect(isValidFssai('12345678901234'), isTrue);
    });

    test('anything else is not', () async {
      for (final bad in [
        '',
        '1234567890123',
        '123456789012345',
        'abcdefghijklmn',
        '1234567890123a',
      ]) {
        expect(isValidFssai(bad), isFalse, reason: '"$bad"');
      }
    });
  });

  group('payments must reconcile with the total', () {
    test('underpaying is refused', () async {
      final computed = await f.compute();
      await expectLater(
        repo.commitSale(
          computed: computed,
          payments: [PaymentIntent(PaymentMode.cash, Paise.fromRupees(100))],
          deviceId: kDeviceId,
          userId: kOwnerId,
        ),
        throwsA(isA<SaleError>()),
      );
      expect(await f.billCount(), 0);
      expect(await f.nextSeq(), 1);
    });

    test('overpaying is refused: change is not a payment', () async {
      final computed = await f.compute();
      await expectLater(
        repo.commitSale(
          computed: computed,
          payments: [PaymentIntent(PaymentMode.cash, Paise.fromRupees(1000))],
          deviceId: kDeviceId,
          userId: kOwnerId,
        ),
        throwsA(isA<SaleError>()),
      );
      expect(await f.billCount(), 0);
    });

    test('no payment at all is refused', () async {
      final computed = await f.compute();
      await expectLater(
        repo.commitSale(
          computed: computed,
          payments: const [],
          deviceId: kDeviceId,
          userId: kOwnerId,
        ),
        throwsA(isA<SaleError>()),
      );
    });

    test('a split that adds up exactly is accepted', () async {
      final computed = await f.compute();
      final half = Paise(computed.total.value ~/ 2);
      await repo.commitSale(
        computed: computed,
        payments: [
          PaymentIntent(PaymentMode.cash, half),
          PaymentIntent(PaymentMode.card, computed.total - half),
        ],
        deviceId: kDeviceId,
        userId: kOwnerId,
      );
      expect(await f.billCount(), 1);
    });
  });

  group('the business date comes from the cutoff, not the clock', () {
    test('a 1 AM bill counts toward the previous night', () async {
      final saved = await sell(at: DateTime(2026, 6, 2, 1, 15));
      expect(saved.businessDate.iso, '2026-06-01');

      final row = await f.db.select(f.db.bills).getSingle();
      expect(row.businessDate.iso, '2026-06-01');
      expect(row.createdAt, DateTime(2026, 6, 2, 1, 15),
          reason: 'the real time is kept as well');
    });

    test('a 5 AM bill counts toward the new day', () async {
      final saved = await sell(at: DateTime(2026, 6, 2, 5, 0));
      expect(saved.businessDate.iso, '2026-06-02');
    });

    test('the outlet cutoff is honoured, not the default', () async {
      final late = await Fixture.create(cutoffMinutes: 360); // 06:00
      final r = BillRepository(late.db);
      final computed = await late.compute();
      final saved = await r.commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: kDeviceId,
        userId: kOwnerId,
        at: DateTime(2026, 6, 2, 5, 0),
      );
      expect(saved.businessDate.iso, '2026-06-01',
          reason: '5 AM is before a 06:00 cutoff');
      await late.close();
    });
  });

  group('the financial year rolls over on the business date', () {
    test('a 1 AM bill on 1 April stays in the old year', () async {
      final f2 = await Fixture.create(nextSeq: 500, fyStart: 2026);
      final r = BillRepository(f2.db);
      final computed = await f2.compute();
      final saved = await r.commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: kDeviceId,
        userId: kOwnerId,
        at: DateTime(2027, 4, 1, 1, 30),
      );
      expect(saved.businessDate.iso, '2027-03-31');
      expect(saved.invoiceNo.formatted, 'A/2627/000500');
      expect((await f2.seqFy()).code, '2627');
      await f2.close();
    });

    test('a 5 AM bill on 1 April restarts the series at 1', () async {
      final f2 = await Fixture.create(nextSeq: 500, fyStart: 2026);
      final r = BillRepository(f2.db);
      final computed = await f2.compute();
      final saved = await r.commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: kDeviceId,
        userId: kOwnerId,
        at: DateTime(2027, 4, 1, 5, 0),
      );
      expect(saved.businessDate.iso, '2027-04-01');
      expect(saved.invoiceNo.formatted, 'A/2728/000001');
      expect((await f2.seqFy()).code, '2728');
      expect(await f2.nextSeq(), 2);
      await f2.close();
    });

    test('bills either side of the rollover keep distinct numbers', () async {
      final f2 = await Fixture.create(nextSeq: 998, fyStart: 2026);
      final r = BillRepository(f2.db);

      Future<String> at(DateTime when) async {
        final c = await f2.compute();
        final s = await r.commitSale(
          computed: c,
          payments: [PaymentIntent(PaymentMode.cash, c.total)],
          deviceId: kDeviceId,
          userId: kOwnerId,
          at: when,
        );
        return s.invoiceNo.formatted;
      }

      final numbers = [
        await at(DateTime(2027, 3, 31, 22, 0)),
        await at(DateTime(2027, 4, 1, 1, 0)),
        await at(DateTime(2027, 4, 1, 10, 0)),
        await at(DateTime(2027, 4, 2, 10, 0)),
      ];

      expect(numbers, [
        'A/2627/000998',
        'A/2627/000999',
        'A/2728/000001',
        'A/2728/000002',
      ]);
      expect(numbers.toSet(), hasLength(4));
      await f2.close();
    });
  });

  group('the audit entry', () {
    test('records the create with an after state and no before', () async {
      final saved = await sell();
      final entry = await f.db.select(f.db.auditLog).getSingle();

      expect(entry.action, AuditAction.billCreated);
      expect(entry.entity, AuditEntity.bill);
      expect(entry.entityId, saved.id);
      expect(entry.userId, kOwnerId);
      expect(entry.deviceId, kDeviceId);
      expect(entry.before, isNull, reason: 'a create has no prior state');
      expect(entry.after, isNotNull);

      final after = jsonDecode(entry.after!) as Map<String, Object?>;
      expect(after['invoice_no'], 'A/2627/000001');
      expect(after['total'], 25200);
      expect(after['status'], 'paid');
      expect((after['lines'] as List<Object?>), hasLength(1));
      expect((after['payments'] as List<Object?>), hasLength(1));
    });

    test('the snapshot in the log is complete enough to reconstruct the bill',
        () async {
      await sell(lines: f.cart(biryaniQty: 2, withColdDrink: true));
      final entry = await f.db.select(f.db.auditLog).getSingle();
      final after = jsonDecode(entry.after!) as Map<String, Object?>;
      final lines = (after['lines']! as List<Object?>)
          .cast<Map<String, Object?>>();

      expect(lines, hasLength(2));
      expect(lines[0]['name'], 'Chicken Dum Biryani');
      expect(lines[0]['qty'], 2);
      expect(lines[0]['unit_price'], 24000);
      expect(lines[0]['tax_rate_bp'], 500);
      expect(lines[1]['tax_rate_bp'], 1800);
    });
  });

  group('the outbox is filled even though nothing reads it', () {
    test('one entry per sale, unsent', () async {
      await sell();
      final row = await f.db.select(f.db.outbox).getSingle();

      expect(row.entity, AuditEntity.bill);
      expect(row.sentAt, isNull, reason: 'nothing sends it in Phase 1');
      expect(row.opId, isNotEmpty);

      final payload = jsonDecode(row.payload) as Map<String, Object?>;
      expect(payload['op'], 'bill_created');
      expect((payload['bill']! as Map<String, Object?>)['invoice_no'],
          'A/2627/000001');
    });

    test('op ids are unique, so a server could deduplicate', () async {
      for (var i = 0; i < 5; i++) {
        await sell();
      }
      final rows = await f.db.select(f.db.outbox).get();
      expect(rows.map((r) => r.opId).toSet(), hasLength(5));
    });

    test('ids are UUIDv7, so they sort in creation order', () async {
      final ids = <String>[];
      for (var i = 0; i < 5; i++) {
        ids.add((await sell()).id);
      }
      final sorted = [...ids]..sort();
      expect(sorted, ids, reason: 'UUIDv7 is time-ordered');
    });
  });

  group('permissions', () {
    test('staff may ring up a bill', () async {
      final saved = await sell(userId: kStaffId);
      expect(saved.invoiceNo.formatted, 'A/2627/000001');
    });

    test('an unknown user cannot', () async {
      await expectLater(
        sell(userId: 'nobody'),
        throwsA(isA<SaleError>()),
      );
      expect(await f.nextSeq(), 1);
    });

    test('a deactivated user cannot', () async {
      await (f.db.update(f.db.users)..where((u) => u.id.equals(kStaffId)))
          .write(const UsersCompanion(isActive: Value(false)));

      await expectLater(
        sell(userId: kStaffId),
        throwsA(isA<SaleError>()),
      );
      expect(await f.billCount(), 0);
      expect(await f.nextSeq(), 1);
    });
  });

  group('aggregator orders', () {
    test('print no tax but still take a number', () async {
      final saved = await sell(orderType: OrderType.aggregator);
      final row = await f.db.select(f.db.bills).getSingle();

      expect(row.docType, DocType.billOfSupply);
      expect(row.orderType, OrderType.aggregator);
      expect(row.cgst.value, 0);
      expect(row.sgst.value, 0);
      expect(row.total.value, 24000);
      expect(saved.invoiceNo.formatted, 'A/2627/000001',
          reason: 'the series has no gaps');
    });

    test('they sit in the same series as dine-in bills', () async {
      final a = await sell();
      final b = await sell(orderType: OrderType.aggregator);
      final c = await sell();

      expect(a.invoiceNo.formatted, 'A/2627/000001');
      expect(b.invoiceNo.formatted, 'A/2627/000002');
      expect(c.invoiceNo.formatted, 'A/2627/000003');
    });
  });

  group('composition mode', () {
    test('stores the turnover figure without charging it', () async {
      final comp = await Fixture.create(taxMode: TaxMode.composition);
      final r = BillRepository(comp.db);
      final computed = await comp.compute();
      await r.commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: kDeviceId,
        userId: kOwnerId,
      );

      final row = await comp.db.select(comp.db.bills).getSingle();
      expect(row.docType, DocType.billOfSupply);
      expect(row.cgst.value, 0);
      expect(row.total.value, 24000, reason: 'the customer pays menu price');
      expect(row.compositionTurnover.value, 1200, reason: '5% of 240');
      await comp.close();
    });
  });
}
