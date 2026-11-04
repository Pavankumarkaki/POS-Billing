/// Reading bills back: day grouping across the cutoff, filters, and cancelled
/// bills staying visible while being excluded from the total.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/bills_query.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late BillRepository repo;
  late BillsQuery query;

  setUp(() async {
    f = await Fixture.create();
    repo = BillRepository(f.db);
    query = BillsQuery(f.db);
  });

  tearDown(() => f.close());

  Future<SavedBill> sell({
    DateTime? at,
    List<PaymentIntent>? payments,
    int biryaniQty = 1,
    OrderType orderType = OrderType.dine,
  }) async {
    final computed = await f.compute(
      lines: f.cart(biryaniQty: biryaniQty),
      orderType: orderType,
    );
    return repo.commitSale(
      computed: computed,
      payments: payments ??
          [PaymentIntent(PaymentMode.cash, computed.total)],
      deviceId: kDeviceId,
      userId: kOwnerId,
      at: at ?? DateTime(2026, 6, 1, 13, 30),
    );
  }

  group('listing a day', () {
    test('an empty day lists nothing', () async {
      expect(await query.forDay(const BusinessDate(2026, 6, 1)), isEmpty);
    });

    test('newest first, because that is the bill being asked about', () async {
      final a = await sell();
      final b = await sell();
      final c = await sell();

      final list = await query.forDay(const BusinessDate(2026, 6, 1));
      expect(
        list.map((e) => e.bill.invoiceNo),
        [
          c.invoiceNo.formatted,
          b.invoiceNo.formatted,
          a.invoiceNo.formatted,
        ],
      );
    });

    test('carries the item count and payment modes', () async {
      await sell(
        biryaniQty: 3,
        payments: [
          PaymentIntent(PaymentMode.cash, Paise.fromRupees(500)),
          const PaymentIntent(PaymentMode.upi, Paise(75600 - 50000)),
        ],
      );

      final entry = (await query.forDay(const BusinessDate(2026, 6, 1))).single;
      expect(entry.itemCount, 3);
      expect(entry.paymentModes, [PaymentMode.cash, PaymentMode.upi]);
      expect(entry.summary, 'Dine in · Cash · UPI');
    });

    test('a split across two cash tenders reads once, not twice', () async {
      final computed = await f.compute();
      final half = Paise(computed.total.value ~/ 2);
      await repo.commitSale(
        computed: computed,
        payments: [
          PaymentIntent(PaymentMode.cash, half),
          PaymentIntent(PaymentMode.cash, computed.total - half),
        ],
        deviceId: kDeviceId,
        userId: kOwnerId,
        at: DateTime(2026, 6, 1, 13, 30),
      );

      final entry = (await query.forDay(const BusinessDate(2026, 6, 1))).single;
      expect(entry.summary, 'Dine in · Cash');
    });

    test('an online order says so', () async {
      await sell(orderType: OrderType.aggregator);
      final entry = (await query.forDay(const BusinessDate(2026, 6, 1))).single;
      expect(entry.summary, startsWith('Online'));
    });
  });

  group('the 04:00 cutoff decides which day a bill is on', () {
    test('a 1 AM bill lists under the previous night', () async {
      await sell(at: DateTime(2026, 6, 2, 1, 15));

      expect(await query.forDay(const BusinessDate(2026, 6, 2)), isEmpty);
      expect(
        await query.forDay(const BusinessDate(2026, 6, 1)),
        hasLength(1),
        reason: 'the list must agree with the reports',
      );
    });

    test('a 5 AM bill lists under the new day', () async {
      await sell(at: DateTime(2026, 6, 2, 5, 0));
      expect(await query.forDay(const BusinessDate(2026, 6, 2)), hasLength(1));
    });

    test('a night straddling midnight is one day in the list', () async {
      await sell(at: DateTime(2026, 6, 1, 21, 0));
      await sell(at: DateTime(2026, 6, 1, 23, 50));
      await sell(at: DateTime(2026, 6, 2, 0, 30));
      await sell(at: DateTime(2026, 6, 2, 2, 15));

      expect(
        await query.forDay(const BusinessDate(2026, 6, 1)),
        hasLength(4),
        reason: 'one trading night, one day in the list',
      );
    });
  });

  group('the day summary', () {
    test('counts paid bills and sums them', () async {
      await sell();
      await sell();

      final summary = await query.summaryFor(const BusinessDate(2026, 6, 1));
      expect(summary.paidCount, 2);
      expect(summary.cancelledCount, 0);
      expect(summary.total.value, 25200 * 2);
    });

    test('excludes cancelled bills from the total but counts them', () async {
      final a = await sell();
      await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final summary = await query.summaryFor(const BusinessDate(2026, 6, 1));
      expect(summary.paidCount, 1);
      expect(summary.cancelledCount, 1);
      expect(
        summary.total.value,
        25200,
        reason: 'the brief: cancelled bills are excluded from sales totals',
      );
    });

    test('a day of nothing but cancellations sums to zero', () async {
      final a = await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Test bill',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final summary = await query.summaryFor(const BusinessDate(2026, 6, 1));
      expect(summary.total.value, 0);
      expect(summary.cancelledCount, 1);
    });
  });

  group('filters', () {
    test('All shows everything, cancelled included', () async {
      final a = await sell();
      await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final all = await query.forDay(
        const BusinessDate(2026, 6, 1),
        filter: BillFilter.all,
      );
      expect(all, hasLength(2));
    });

    test('Cancelled shows only cancelled', () async {
      final a = await sell();
      await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final cancelled = await query.forDay(
        const BusinessDate(2026, 6, 1),
        filter: BillFilter.cancelled,
      );
      expect(cancelled, hasLength(1));
      expect(cancelled.single.bill.id, a.id);
    });

    test('a payment filter matches the mode', () async {
      final computed = await f.compute();
      await repo.commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.upi, computed.total)],
        deviceId: kDeviceId,
        userId: kOwnerId,
        at: DateTime(2026, 6, 1, 13, 30),
      );
      await sell(); // cash

      expect(
        await query.forDay(const BusinessDate(2026, 6, 1), filter: BillFilter.upi),
        hasLength(1),
      );
      expect(
        await query.forDay(const BusinessDate(2026, 6, 1), filter: BillFilter.cash),
        hasLength(1),
      );
      expect(
        await query.forDay(const BusinessDate(2026, 6, 1), filter: BillFilter.card),
        isEmpty,
      );
    });

    test('a split bill appears under both of its modes', () async {
      final computed = await f.compute();
      await repo.commitSale(
        computed: computed,
        payments: [
          PaymentIntent(PaymentMode.cash, Paise.fromRupees(200)),
          PaymentIntent(PaymentMode.card, computed.total - Paise.fromRupees(200)),
        ],
        deviceId: kDeviceId,
        userId: kOwnerId,
        at: DateTime(2026, 6, 1, 13, 30),
      );

      expect(
        await query.forDay(const BusinessDate(2026, 6, 1), filter: BillFilter.cash),
        hasLength(1),
      );
      expect(
        await query.forDay(const BusinessDate(2026, 6, 1), filter: BillFilter.card),
        hasLength(1),
      );
    });

    test('a cancelled cash bill is not in the Cash filter', () async {
      final a = await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Wrong payment mode',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      expect(
        await query.forDay(const BusinessDate(2026, 6, 1), filter: BillFilter.cash),
        isEmpty,
        reason: "looking for today's cash should not turn up a voided bill",
      );
    });
  });

  group('finding a bill by its number', () {
    test('matches what a customer would read out', () async {
      final saved = await sell();
      final found = await query.byInvoiceNo(saved.invoiceNo.formatted);
      expect(found, isNotNull);
      expect(found!.id, saved.id);
    });

    test('is forgiving about case and whitespace', () async {
      await sell();
      expect(await query.byInvoiceNo('  a/2627/000001  '), isNotNull);
    });

    test('returns nothing for an unknown number', () async {
      await sell();
      expect(await query.byInvoiceNo('A/2627/999999'), isNull);
    });
  });

  group('days with bills', () {
    test('lists distinct days, newest first', () async {
      await sell(at: DateTime(2026, 6, 1, 13, 0));
      await sell(at: DateTime(2026, 6, 1, 19, 0));
      await sell(at: DateTime(2026, 6, 3, 13, 0));

      final days = await query.daysWithBills();
      expect(days.map((d) => d.iso), ['2026-06-03', '2026-06-01']);
    });

    test('is empty before any bill', () async {
      expect(await query.daysWithBills(), isEmpty);
    });
  });

  group('a bill history', () {
    test('shows the create, the reprint and the cancellation in order',
        () async {
      final saved = await sell();
      await repo.recordReprint(
        billId: saved.id,
        userId: kOwnerId,
        deviceId: kDeviceId,
        at: DateTime(2026, 6, 1, 14, 0),
      );
      await repo.cancelBill(
        billId: saved.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
        at: DateTime(2026, 6, 1, 15, 0),
      );

      final history = await query.historyFor(saved.id);
      expect(
        history.map((h) => h.action),
        [
          AuditAction.billCreated,
          AuditAction.billReprinted,
          AuditAction.billCancelled,
        ],
        reason: 'the owner should be able to see it was recorded, not just '
            'trust that it was',
      );
    });

    test('does not mix in another bill history', () async {
      final a = await sell();
      final b = await sell();
      await repo.recordReprint(
        billId: b.id,
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      expect(await query.historyFor(a.id), hasLength(1));
      expect(await query.historyFor(b.id), hasLength(2));
    });
  });

  group('a range', () {
    test('covers the days asked for and no others', () async {
      await sell(at: DateTime(2026, 6, 1, 13, 0));
      await sell(at: DateTime(2026, 6, 2, 13, 0));
      await sell(at: DateTime(2026, 6, 5, 13, 0));

      final week = await query.forRange(
        const BusinessDate(2026, 6, 1),
        const BusinessDate(2026, 6, 3),
      );
      expect(week, hasLength(2));
    });

    test('is inclusive at both ends', () async {
      await sell(at: DateTime(2026, 6, 1, 13, 0));
      await sell(at: DateTime(2026, 6, 3, 13, 0));

      final range = await query.forRange(
        const BusinessDate(2026, 6, 1),
        const BusinessDate(2026, 6, 3),
      );
      expect(range, hasLength(2));
    });
  });
}
