/// Reports: the three rules that decide whether every figure is right.
///
///   cancelled bills never reach a sales total
///   everything groups by business_date, not by the clock
///   aggregator GST is not the restaurant's to pay
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/core/turnover.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/reports_query.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late BillRepository repo;
  late ReportsQuery reports;

  setUp(() async {
    f = await Fixture.create();
    repo = BillRepository(f.db);
    reports = ReportsQuery(f.db);
  });

  tearDown(() => f.close());

  Future<SavedBill> sell({
    DateTime? at,
    OrderType orderType = OrderType.dine,
    PaymentMode mode = PaymentMode.cash,
    int biryaniQty = 1,
    bool withColdDrink = false,
  }) async {
    final computed = await f.compute(
      lines: f.cart(biryaniQty: biryaniQty, withColdDrink: withColdDrink),
      orderType: orderType,
    );
    return repo.commitSale(
      computed: computed,
      payments: [PaymentIntent(mode, computed.total)],
      deviceId: kDeviceId,
      userId: kOwnerId,
      at: at ?? DateTime(2026, 6, 1, 13, 30),
    );
  }

  final day = const BusinessDate(2026, 6, 1);

  group('cancelled bills never reach a sales total', () {
    test('they are excluded and counted separately', () async {
      final a = await sell();
      await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final r = await reports.forRange(day, day);
      expect(r.billCount, 1);
      expect(r.total.value, 25200);
      expect(r.cancelledCount, 1);
      expect(r.cancelledTotal.value, 25200);
    });

    test('a day of only cancellations reports zero sales', () async {
      final a = await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Test bill',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final r = await reports.forRange(day, day);
      expect(r.total.value, 0);
      expect(r.billCount, 0);
      expect(r.cancelledCount, 1);
    });

    test('their tax is excluded too', () async {
      final a = await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final r = await reports.forRange(day, day);
      expect(r.cgst.value, 0);
      expect(r.sgst.value, 0);
      expect(r.taxable.value, 0);
    });

    test('their items are excluded from the item breakdown', () async {
      final a = await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final r = await reports.forRange(day, day);
      expect(r.byItem, isEmpty);
    });

    test('their payments are excluded from the mode breakdown', () async {
      final a = await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final r = await reports.forRange(day, day);
      expect(r.byMode, isEmpty);
    });

    test('and they do not count toward turnover', () async {
      final a = await sell();
      await sell();
      await repo.cancelBill(
        billId: a.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      expect(
        (await reports.turnoverForYear(const FinancialYear(2026))).value,
        25200,
      );
    });
  });

  group('grouping by the business day, not the clock', () {
    test('a 1 AM bill counts toward the night before', () async {
      await sell(at: DateTime(2026, 6, 2, 1, 15));

      final first = await reports.forRange(day, day);
      final second = await reports.forRange(
        const BusinessDate(2026, 6, 2),
        const BusinessDate(2026, 6, 2),
      );

      expect(first.billCount, 1);
      expect(second.billCount, 0);
    });

    test('a trading night straddling midnight is one day', () async {
      await sell(at: DateTime(2026, 6, 1, 20, 0));
      await sell(at: DateTime(2026, 6, 1, 23, 55));
      await sell(at: DateTime(2026, 6, 2, 0, 20));
      await sell(at: DateTime(2026, 6, 2, 3, 40));

      final r = await reports.forRange(day, day);
      expect(r.billCount, 4);
      expect(r.byDay, hasLength(1));
      expect(r.byDay.single.bills, 4);
    });

    test('a 5 AM bill starts the new day', () async {
      await sell(at: DateTime(2026, 6, 2, 5, 0));
      expect((await reports.forRange(day, day)).billCount, 0);
      expect(
        (await reports.forRange(
          const BusinessDate(2026, 6, 2),
          const BusinessDate(2026, 6, 2),
        ))
            .billCount,
        1,
      );
    });
  });

  group('the day series', () {
    test('includes quiet days, so a bad week is not flattered', () async {
      await sell(at: DateTime(2026, 6, 1, 13, 0));
      await sell(at: DateTime(2026, 6, 3, 13, 0));

      final r = await reports.forRange(
        const BusinessDate(2026, 6, 1),
        const BusinessDate(2026, 6, 3),
      );

      expect(r.byDay, hasLength(3));
      expect(r.byDay[1].total.value, 0, reason: '2 June had no sales');
      expect(r.byDay[1].bills, 0);
    });

    test('runs in date order', () async {
      await sell(at: DateTime(2026, 6, 3, 13, 0));
      await sell(at: DateTime(2026, 6, 1, 13, 0));

      final r = await reports.forRange(
        const BusinessDate(2026, 6, 1),
        const BusinessDate(2026, 6, 3),
      );
      expect(
        r.byDay.map((p) => p.day.iso),
        ['2026-06-01', '2026-06-02', '2026-06-03'],
      );
    });

    test('a week adds up to the total', () async {
      for (var d = 1; d <= 7; d++) {
        await sell(at: DateTime(2026, 6, d, 13, 0));
      }
      final r = await reports.forRange(
        const BusinessDate(2026, 6, 1),
        const BusinessDate(2026, 6, 7),
      );
      expect(r.billCount, 7);
      expect(
        r.byDay.fold(Paise.zero, (Paise s, p) => s + p.total).value,
        r.total.value,
      );
    });
  });

  group('payment modes', () {
    test('split by mode, biggest first', () async {
      await sell(mode: PaymentMode.cash);
      await sell(mode: PaymentMode.cash);
      await sell(mode: PaymentMode.upi);

      final r = await reports.forRange(day, day);
      expect(r.byMode.first.mode, PaymentMode.cash);
      expect(r.byMode.first.total.value, 25200 * 2);
      expect(r.byMode.first.count, 2);
      expect(r.byMode.last.mode, PaymentMode.upi);
    });

    test('a split bill contributes to both modes', () async {
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

      final r = await reports.forRange(day, day);
      expect(r.byMode, hasLength(2));
      expect(
        r.byMode.fold(Paise.zero, (Paise s, m) => s + m.total).value,
        r.total.value,
        reason: 'the modes must add up to the sales total',
      );
    });
  });

  group('items', () {
    test('best sellers first, by quantity', () async {
      await sell(biryaniQty: 2, withColdDrink: true);
      await sell(biryaniQty: 3);

      final r = await reports.forRange(day, day);
      expect(r.byItem.first.name, 'Chicken Dum Biryani');
      expect(r.byItem.first.qty, 5);
      expect(r.byItem.last.name, 'Bottled soft drink');
      expect(r.byItem.last.qty, 1);
    });

    test('grouped by the name it was sold under, not the current one',
        () async {
      await sell(biryaniQty: 2);

      // Rename the item afterwards.
      await f.db.customStatement(
        "UPDATE item SET name_en = 'Renamed Later' "
        "WHERE id = '$kItemBiryani'",
      );

      final r = await reports.forRange(day, day);
      expect(
        r.byItem.first.name,
        'Chicken Dum Biryani',
        reason: 'a rename must not relabel history',
      );
    });
  });

  group('the tax summary the CA needs', () {
    test('one row per rate, from the stored splits', () async {
      await sell(withColdDrink: true);

      final r = await reports.forRange(day, day);
      expect(r.byRate.map((x) => x.rateBp), [500, 1800]);

      final five = r.byRate.first;
      expect(five.taxable.value, 24000);
      expect(five.cgst.value, 600);
      expect(five.sgst.value, 600);

      final eighteen = r.byRate.last;
      expect(eighteen.taxable.value, 10000);
      expect(eighteen.cgst.value, 900);
    });

    test('the rate rows add up to the bill totals', () async {
      await sell(withColdDrink: true);
      await sell(biryaniQty: 2);

      final r = await reports.forRange(day, day);
      expect(
        r.byRate.fold(Paise.zero, (Paise s, x) => s + x.cgst).value,
        r.cgst.value,
      );
      expect(
        r.byRate.fold(Paise.zero, (Paise s, x) => s + x.taxable).value,
        r.taxable.value,
      );
    });

    test('document counts are reported', () async {
      await sell();
      await sell(orderType: OrderType.aggregator);

      final r = await reports.forRange(day, day);
      expect(r.docCounts[DocType.invoice], 1);
      expect(r.docCounts[DocType.billOfSupply], 1);
    });
  });

  group('aggregator orders', () {
    test('count toward turnover but not toward GST payable', () async {
      await sell();
      await sell(orderType: OrderType.aggregator);

      final r = await reports.forRange(day, day);

      // The dine-in bill is 240 + 12 tax; the aggregator one is 240 flat.
      expect(r.aggregatorTotal.value, 24000);
      expect(r.total.value, 25200 + 24000);
      expect(
        r.aggregatorTax.value,
        0,
        reason: 'aggregator bills carry no tax in the first place',
      );
      expect(
        r.gstPayable.value,
        1200,
        reason: 'only the dine-in tax is the restaurant to pay',
      );
    });

    test('a day of only aggregator orders owes no GST', () async {
      await sell(orderType: OrderType.aggregator);
      await sell(orderType: OrderType.aggregator);

      final r = await reports.forRange(day, day);
      expect(r.gstPayable.value, 0);
      expect(r.total.value, 48000, reason: 'turnover still counts');
    });
  });

  group('composition turnover', () {
    test('is reported but never charged', () async {
      final comp = await Fixture.create(taxMode: TaxMode.composition);
      final r = BillRepository(comp.db);
      final computed = await comp.compute();
      await r.commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: kDeviceId,
        userId: kOwnerId,
        at: DateTime(2026, 6, 1, 13, 30),
      );

      final report = await ReportsQuery(comp.db).forRange(day, day);
      expect(report.compositionTurnover.value, 1200, reason: '5% of 240');
      expect(report.total.value, 24000, reason: 'the customer paid 240');
      expect(report.cgst.value, 0);
      await comp.close();
    });
  });

  group('an empty period', () {
    test('reports zeroes rather than failing', () async {
      final r = await reports.forRange(day, day);
      expect(r.total.value, 0);
      expect(r.billCount, 0);
      expect(r.averageBill.value, 0);
      expect(r.byItem, isEmpty);
      expect(r.byMode, isEmpty);
      expect(r.byRate, isEmpty);
      expect(r.byDay, hasLength(1));
    });
  });

  group('the average bill', () {
    test('is the total over the count', () async {
      await sell();
      await sell(biryaniQty: 3);

      final r = await reports.forRange(day, day);
      expect(r.averageBill.value, (25200 + 75600) ~/ 2);
    });
  });

  group('turnover warnings', () {
    final fy = const FinancialYear(2026);

    test('nothing to say well below the limit', () {
      expect(
        turnoverWarning(
          mode: TaxMode.unregistered,
          turnoverThisYear: Paise.fromRupees(500000),
          fy: fy,
        ),
        isNull,
      );
    });

    test('warns at 80% of the registration limit', () {
      final w = turnoverWarning(
        mode: TaxMode.unregistered,
        turnoverThisYear: Paise.fromRupees(1600000),
        fy: fy,
      );
      expect(w, isNotNull);
      expect(w!.level, TurnoverLevel.approaching);
      expect(w.headline, contains('registration limit'));
      expect(w.detail, contains('CA'));
      expect(w.remaining.value, Paise.fromRupees(400000).value);
    });

    test('and says so once past it', () {
      final w = turnoverWarning(
        mode: TaxMode.unregistered,
        turnoverThisYear: Paise.fromRupees(2100000),
        fy: fy,
      );
      expect(w!.level, TurnoverLevel.exceeded);
      expect(w.headline, contains('Past'));
      expect(w.remaining.value, 0);
      expect(w.fraction, 1.0);
    });

    test('composition warns at 80% of 1.5 crore', () {
      final w = turnoverWarning(
        mode: TaxMode.composition,
        turnoverThisYear: Paise.fromRupees(12000000),
        fy: fy,
      );
      expect(w, isNotNull);
      expect(w!.level, TurnoverLevel.approaching);
      expect(w.headline, contains('composition limit'));
    });

    test('just under 80% says nothing', () {
      expect(
        turnoverWarning(
          mode: TaxMode.composition,
          turnoverThisYear: Paise.fromRupees(11999999),
          fy: fy,
        ),
        isNull,
      );
    });

    test('a registered outlet has no limit to warn about', () {
      for (final mode in [TaxMode.regular5, TaxMode.regular18]) {
        expect(
          turnoverWarning(
            mode: mode,
            turnoverThisYear: Paise.fromRupees(90000000),
            fy: fy,
          ),
          isNull,
          reason: '$mode is already registered',
        );
      }
    });

    test('the thresholds are the ones the brief names', () {
      expect(kRegistrationThreshold.rupeesWhole, '₹20,00,000');
      expect(kCompositionThreshold.rupeesWhole, '₹1,50,00,000');
    });

    test('the fraction is usable for a progress bar', () {
      final w = turnoverWarning(
        mode: TaxMode.unregistered,
        turnoverThisYear: Paise.fromRupees(1800000),
        fy: fy,
      );
      expect(w!.fraction, closeTo(0.9, 0.001));
    });
  });

  group('turnover for the financial year', () {
    test('sums paid bills in that year only', () async {
      await sell(at: DateTime(2026, 6, 1, 13, 0));
      await sell(at: DateTime(2027, 5, 1, 13, 0)); // next financial year

      expect(
        (await reports.turnoverForYear(const FinancialYear(2026))).value,
        25200,
      );
      expect(
        (await reports.turnoverForYear(const FinancialYear(2027))).value,
        25200,
      );
    });
  });
}
