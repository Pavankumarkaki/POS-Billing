import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:flutter_test/flutter_test.dart';

/// A cart line, kept short so the cases below read as arithmetic.
CartLine line({
  String id = 'i1',
  String name = 'Chicken Dum Biryani',
  int priceRupees = 240,
  int qty = 1,
  TaxClass taxClass = TaxClass.gst5,
  int discountRupees = 0,
}) =>
    CartLine(
      itemId: id,
      nameSnapshot: name,
      unitPrice: Paise.fromRupees(priceRupees),
      qty: qty,
      taxClass: taxClass,
      lineDiscount: Paise.fromRupees(discountRupees),
    );

TaxConfig cfg(TaxMode mode, {bool inclusive = false}) =>
    TaxConfig(mode: mode, pricesIncludeTax: inclusive);

ComputedBill bill(
  List<CartLine> cart, {
  TaxMode mode = TaxMode.regular5,
  bool inclusive = false,
  OrderType orderType = OrderType.dine,
  int billDiscountRupees = 0,
}) =>
    computeBill(
      cart: cart,
      config: cfg(mode, inclusive: inclusive),
      orderType: orderType,
      billDiscount: Paise.fromRupees(billDiscountRupees),
    );

/// The invariants that must hold on every bill in every mode. Asserted after
/// each case below, so a change to the engine cannot quietly break one.
void expectConsistent(ComputedBill b) {
  expect(
    b.lines.fold(Paise.zero, (Paise s, l) => s + l.taxable).value,
    b.taxable.value,
    reason: 'taxable must be the sum of its lines',
  );
  expect(
    b.lines.fold(Paise.zero, (Paise s, l) => s + l.cgst).value,
    b.cgst.value,
    reason: 'CGST must be the sum of its lines',
  );
  expect(b.cgst.value, b.sgst.value,
      reason: 'CGST and SGST are always equal halves');
  expect(
    (b.taxable + b.cgst + b.sgst + b.roundOff).value,
    b.total.value,
    reason: 'taxable + tax + round off must be the total',
  );
  expect(b.total.value % 100, 0, reason: 'the total is always whole rupees');
  expect(b.roundOff.abs.value, lessThanOrEqualTo(50),
      reason: 'round off never exceeds half a rupee');
  for (final l in b.lines) {
    expect((l.taxable + l.cgst + l.sgst).value, l.lineTotal.value,
        reason: 'a line total is its taxable value plus its tax');
  }
  // Every rate block reconciles with the lines that fed it.
  for (final blk in b.rateBlocks) {
    final group = b.lines.where((l) => l.taxRateBp == blk.rateBp);
    expect(group.fold(Paise.zero, (Paise s, l) => s + l.taxable).value,
        blk.taxable.value);
    expect(group.fold(Paise.zero, (Paise s, l) => s + l.cgst).value,
        blk.cgst.value);
  }
}

void main() {
  group('unregistered: a plain bill, no tax at all', () {
    test('one line', () {
      final b = bill([line(priceRupees: 240)], mode: TaxMode.unregistered);
      expect(b.taxable.value, 24000);
      expect(b.cgst.value, 0);
      expect(b.sgst.value, 0);
      expect(b.total.value, 24000);
      expect(b.showsTax, isFalse);
      expect(b.docType, DocType.billOfSupply);
      expect(b.rateBlocks, isEmpty);
      expect(b.compositionTurnover.value, 0);
      expectConsistent(b);
    });

    test('a gst18 item is still untaxed, because the outlet is not registered',
        () {
      final b = bill(
        [line(priceRupees: 100, taxClass: TaxClass.gst18)],
        mode: TaxMode.unregistered,
      );
      expect(b.cgst.value, 0);
      expect(b.lines.single.taxRateBp, 0,
          reason: 'the snapshotted rate is the rate actually applied');
      expect(b.total.value, 10000);
      expectConsistent(b);
    });
  });

  group('regular_5: 2.5% CGST + 2.5% SGST', () {
    test('a round price', () {
      final b = bill([line(priceRupees: 240)]);
      expect(b.taxable.value, 24000);
      expect(b.cgst.value, 600); // 2.5% of 240 is 6.00
      expect(b.sgst.value, 600);
      // 240 + 6 + 6 = 252, already whole
      expect(b.roundOff.value, 0);
      expect(b.total.value, 25200);
      expect(b.docType, DocType.invoice);
      expect(b.showsTax, isTrue);
      expect(b.sacCode, '9963');
      expectConsistent(b);
    });

    test('a price that needs a round off', () {
      // 70 taxable, 2.5% is 1.75 -> 1.75 each side, so 73.50 exact.
      final b = bill([line(priceRupees: 70)]);
      expect(b.taxable.value, 7000);
      expect(b.cgst.value, 175);
      expect(b.sgst.value, 175);
      expect((b.taxable + b.cgst + b.sgst).value, 7350);
      expect(b.total.value, 7400, reason: '73.50 rounds up to 74');
      expect(b.roundOff.value, 50);
      expectConsistent(b);
    });

    test('a price that rounds down', () {
      // 1 x 101 -> 101 + 2.525 + 2.525. Each half rounds to 253 paise.
      final b = bill([line(priceRupees: 101)]);
      expect(b.cgst.value, 253);
      expect((b.taxable + b.cgst + b.sgst).value, 10606);
      expect(b.total.value, 10600, reason: '106.06 rounds down to 106');
      expect(b.roundOff.value, -6);
      expectConsistent(b);
    });

    test('quantity multiplies before tax', () {
      final b = bill([line(priceRupees: 240, qty: 3)]);
      expect(b.subtotal.value, 72000);
      expect(b.taxable.value, 72000);
      expect(b.cgst.value, 1800);
      expect(b.total.value, 75600);
      expectConsistent(b);
    });

    test('a non_gst line sits on the bill untaxed', () {
      final b = bill([
        line(id: 'a', priceRupees: 240),
        line(id: 'b', name: 'Mineral water', priceRupees: 20,
            taxClass: TaxClass.nonGst),
      ]);
      expect(b.taxable.value, 26000);
      expect(b.cgst.value, 600, reason: 'only the biryani is taxed');
      expect(b.rateBlocks, hasLength(1));
      expect(b.rateBlocks.single.rateBp, 500);
      expect(b.rateBlocks.single.taxable.value, 24000);
      expectConsistent(b);
    });
  });

  group('regular_18: 9% CGST + 9% SGST', () {
    test('a round price', () {
      final b = bill(
        [line(priceRupees: 100, taxClass: TaxClass.gst18)],
        mode: TaxMode.regular18,
      );
      expect(b.taxable.value, 10000);
      expect(b.cgst.value, 900);
      expect(b.sgst.value, 900);
      expect(b.total.value, 11800);
      expect(b.roundOff.value, 0);
      expectConsistent(b);
    });

    test('an awkward price', () {
      // 95 taxable, 9% is 8.55 each side -> 112.10
      final b = bill(
        [line(priceRupees: 95, taxClass: TaxClass.gst18)],
        mode: TaxMode.regular18,
      );
      expect(b.cgst.value, 855);
      expect((b.taxable + b.cgst + b.sgst).value, 11210);
      expect(b.total.value, 11200);
      expect(b.roundOff.value, -10);
      expectConsistent(b);
    });
  });

  group('the item rate wins over the outlet mode (answer to Q3)', () {
    test('a gst18 item on a regular_5 outlet is taxed at 18%', () {
      final b = bill(
        [line(priceRupees: 100, taxClass: TaxClass.gst18)],
        mode: TaxMode.regular5,
      );
      expect(b.lines.single.taxRateBp, 1800);
      expect(b.cgst.value, 900, reason: '9%, not 2.5%');
      expectConsistent(b);
    });

    test('a mixed-rate bill prints one block per rate, ascending', () {
      final b = bill([
        line(id: 'a', name: 'Chicken Dum Biryani', priceRupees: 240),
        line(id: 'b', name: 'Bottled soft drink', priceRupees: 100,
            taxClass: TaxClass.gst18),
        line(id: 'c', name: 'Mineral water', priceRupees: 20,
            taxClass: TaxClass.nonGst),
      ]);

      expect(b.rateBlocks, hasLength(2));
      expect(b.rateBlocks[0].rateBp, 500);
      expect(b.rateBlocks[1].rateBp, 1800);

      expect(b.rateBlocks[0].taxable.value, 24000);
      expect(b.rateBlocks[0].cgst.value, 600);
      expect(b.rateBlocks[1].taxable.value, 10000);
      expect(b.rateBlocks[1].cgst.value, 900);

      expect(b.taxable.value, 36000, reason: '240 + 100 + 20');
      expect(b.cgst.value, 1500, reason: '600 + 900');
      expect(b.total.value, 39000);
      expectConsistent(b);
    });

    test('rate block labels read the way a receipt needs them', () {
      final b = bill([
        line(id: 'a', priceRupees: 240),
        line(id: 'b', priceRupees: 100, taxClass: TaxClass.gst18),
      ]);
      expect(b.rateBlocks[0].halfRateLabel, '2.5');
      expect(b.rateBlocks[0].fullRateLabel, '5');
      expect(b.rateBlocks[1].halfRateLabel, '9');
      expect(b.rateBlocks[1].fullRateLabel, '18');
    });

    test('outlet mode still sets what a new item defaults to', () {
      expect(TaxMode.regular5.defaultItemClass, TaxClass.gst5);
      expect(TaxMode.regular18.defaultItemClass, TaxClass.gst18);
    });
  });

  group('composition: a Bill of Supply, with turnover tracked separately', () {
    test('no tax is charged or shown', () {
      final b = bill([line(priceRupees: 240)], mode: TaxMode.composition);
      expect(b.cgst.value, 0);
      expect(b.sgst.value, 0);
      expect(b.showsTax, isFalse);
      expect(b.docType, DocType.billOfSupply);
      expect(b.rateBlocks, isEmpty);
      expect(b.total.value, 24000, reason: 'the customer pays the menu price');
      expectConsistent(b);
    });

    test('5% of turnover is computed for the owner, not for the customer', () {
      final b = bill([line(priceRupees: 240)], mode: TaxMode.composition);
      expect(b.compositionTurnover.value, 1200, reason: '5% of 240');
      expect(b.total.value, 24000,
          reason: 'the turnover figure must not reach the total');
    });

    test('the turnover figure is zero in every other mode', () {
      for (final mode in [
        TaxMode.unregistered,
        TaxMode.regular5,
        TaxMode.regular18,
      ]) {
        final b = bill([line(priceRupees: 240)], mode: mode);
        expect(b.compositionTurnover.value, 0, reason: '$mode');
      }
    });
  });

  group('discounts come off before tax', () {
    test('a line discount', () {
      // 240 less 40 is 200 taxable, 2.5% is 5.00 each side.
      final b = bill([line(priceRupees: 240, discountRupees: 40)]);
      expect(b.subtotal.value, 24000, reason: 'subtotal is before discount');
      expect(b.discount.value, 4000);
      expect(b.taxable.value, 20000);
      expect(b.cgst.value, 500);
      expect(b.total.value, 21000);
      expectConsistent(b);
    });

    test('a bill discount spreads across lines in proportion to value', () {
      // 240 and 120, so 2:1. A 30 discount splits 20 and 10.
      final b = bill(
        [
          line(id: 'a', priceRupees: 240),
          line(id: 'b', priceRupees: 120),
        ],
        billDiscountRupees: 30,
      );
      expect(b.discount.value, 3000);
      expect(b.lines[0].lineDiscount.value, 2000);
      expect(b.lines[1].lineDiscount.value, 1000);
      expect(b.taxable.value, 33000, reason: '360 less 30');
      expect(b.cgst.value, 825);
      expectConsistent(b);
    });

    test('a bill discount that cannot split evenly loses no paisa', () {
      final b = bill(
        [
          line(id: 'a', priceRupees: 100),
          line(id: 'b', priceRupees: 100),
          line(id: 'c', priceRupees: 100),
        ],
        billDiscountRupees: 10,
      );
      final shares =
          b.lines.fold(Paise.zero, (Paise s, l) => s + l.lineDiscount);
      expect(shares.value, 1000, reason: 'the shares must add to the discount');
      expect(b.taxable.value, 29000);
      expectConsistent(b);
    });

    test('line and bill discounts stack, line first', () {
      final b = bill(
        [
          line(id: 'a', priceRupees: 240, discountRupees: 40),
          line(id: 'b', priceRupees: 100),
        ],
        billDiscountRupees: 30,
      );
      // Lines are 200 and 100 after line discounts, so 2:1 on the 30.
      expect(b.lines[0].lineDiscount.value, 4000 + 2000);
      expect(b.lines[1].lineDiscount.value, 1000);
      expect(b.discount.value, 7000);
      expect(b.taxable.value, 27000, reason: '340 less 70');
      expectConsistent(b);
    });

    test('a discount covering the whole bill leaves nothing to tax', () {
      final b = bill([line(priceRupees: 240)], billDiscountRupees: 240);
      expect(b.taxable.value, 0);
      expect(b.cgst.value, 0);
      expect(b.total.value, 0);
      expectConsistent(b);
    });
  });

  group('tax-inclusive menu prices', () {
    test('the customer pays the menu price', () {
      final b = bill([line(priceRupees: 240)], inclusive: true);
      expect((b.taxable + b.cgst + b.sgst).value, 24000,
          reason: 'the quoted price is what is collected');
      expect(b.total.value, 24000);
      expect(b.roundOff.value, 0);
      expectConsistent(b);
    });

    test('tax is backed out, not added on', () {
      final b = bill([line(priceRupees: 240)], inclusive: true);
      // 240 inclusive of 5%: each half is 240 * 2.5 / 105 = 5.714 -> 5.71
      expect(b.cgst.value, 571);
      expect(b.sgst.value, 571);
      expect(b.taxable.value, 24000 - 1142);
      expectConsistent(b);
    });

    test('at 18% inclusive', () {
      final b = bill(
        [line(priceRupees: 118, taxClass: TaxClass.gst18)],
        mode: TaxMode.regular18,
        inclusive: true,
      );
      // 118 inclusive of 18%: each half is 118 * 9 / 118 = 9.00 exactly
      expect(b.cgst.value, 900);
      expect(b.taxable.value, 10000);
      expect(b.total.value, 11800);
      expect(b.roundOff.value, 0);
      expectConsistent(b);
    });

    test('inclusive and exclusive differ, and both reconcile', () {
      final inc = bill([line(priceRupees: 240)], inclusive: true);
      final exc = bill([line(priceRupees: 240)]);
      expect(inc.total.value, 24000);
      expect(exc.total.value, 25200);
      expect(inc.taxable.value, lessThan(exc.taxable.value));
      expectConsistent(inc);
      expectConsistent(exc);
    });

    test('a discount comes off the inclusive price first', () {
      final b = bill(
        [line(priceRupees: 240, discountRupees: 40)],
        inclusive: true,
      );
      expect((b.taxable + b.cgst + b.sgst).value, 20000);
      expect(b.total.value, 20000);
      expectConsistent(b);
    });

    test('inclusive mixed rates still reconcile per block', () {
      final b = bill(
        [
          line(id: 'a', priceRupees: 240),
          line(id: 'b', priceRupees: 118, taxClass: TaxClass.gst18),
        ],
        mode: TaxMode.regular5,
        inclusive: true,
      );
      expect(b.rateBlocks, hasLength(2));
      expect((b.taxable + b.cgst + b.sgst).value, 35800);
      expectConsistent(b);
    });
  });

  group('aggregator orders (answer to Q4)', () {
    test('no tax is charged, because the aggregator pays it', () {
      final b = bill(
        [line(priceRupees: 240)],
        mode: TaxMode.regular5,
        orderType: OrderType.aggregator,
      );
      expect(b.cgst.value, 0);
      expect(b.sgst.value, 0);
      expect(b.showsTax, isFalse);
      expect(b.docType, DocType.billOfSupply);
      expect(b.total.value, 24000);
      expectConsistent(b);
    });

    test('they are flagged so reports can keep their GST out of what is owed',
        () {
      final agg = bill([line()], orderType: OrderType.aggregator);
      final dine = bill([line()], orderType: OrderType.dine);
      expect(agg.gstPaidByAggregator, isTrue);
      expect(dine.gstPaidByAggregator, isFalse);
    });

    test('dine in and takeaway are taxed normally', () {
      for (final t in [OrderType.dine, OrderType.takeaway]) {
        final b = bill([line(priceRupees: 240)], orderType: t);
        expect(b.cgst.value, 600, reason: '$t');
        expect(b.docType, DocType.invoice);
      }
    });
  });

  group('the SAC code stays configurable', () {
    test('defaults to 9963', () {
      expect(bill([line()]).sacCode, '9963');
    });

    test('can be overridden without touching the engine', () {
      final b = computeBill(
        cart: [line()],
        config: const TaxConfig(
          mode: TaxMode.regular5,
          pricesIncludeTax: false,
          sacCode: '996331',
        ),
        orderType: OrderType.dine,
      );
      expect(b.sacCode, '996331');
    });
  });

  group('snapshots', () {
    test('the line carries the name and price it was sold at', () {
      final b = bill([line(name: 'Gongura Mutton', priceRupees: 320)]);
      final l = b.lines.single;
      expect(l.nameSnapshot, 'Gongura Mutton');
      expect(l.unitPrice.value, 32000);
      expect(l.taxRateBp, 500);
    });

    test('the Telugu name is snapshotted too', () {
      final b = computeBill(
        cart: [
          CartLine(
            itemId: 'i1',
            nameSnapshot: 'Chicken Dum Biryani',
            nameTeSnapshot: 'చికెన్ దమ్ బిర్యానీ',
            unitPrice: Paise.fromRupees(240),
            qty: 1,
            taxClass: TaxClass.gst5,
          ),
        ],
        config: cfg(TaxMode.regular5),
        orderType: OrderType.dine,
      );
      expect(b.lines.single.nameTeSnapshot, 'చికెన్ దమ్ బిర్యానీ');
    });
  });

  group('rejections', () {
    test('an empty cart is not a bill', () {
      expect(() => bill([]), throwsA(isA<BillingError>()));
    });

    test('a zero or negative quantity', () {
      expect(() => bill([line(qty: 0)]), throwsA(isA<BillingError>()));
      expect(() => bill([line(qty: -1)]), throwsA(isA<BillingError>()));
    });

    test('a negative discount', () {
      expect(
        () => bill([line(discountRupees: -10)]),
        throwsA(isA<BillingError>()),
      );
      expect(
        () => bill([line()], billDiscountRupees: -10),
        throwsA(isA<BillingError>()),
      );
    });

    test('a line discount bigger than the line', () {
      expect(
        () => bill([line(priceRupees: 100, discountRupees: 150)]),
        throwsA(isA<BillingError>()),
      );
    });

    test('a bill discount bigger than the bill', () {
      expect(
        () => bill([line(priceRupees: 100)], billDiscountRupees: 150),
        throwsA(isA<BillingError>()),
      );
    });
  });

  group('a realistic bill, every mode', () {
    final cart = [
      line(id: 'a', name: 'Chicken Dum Biryani', priceRupees: 240, qty: 2),
      line(id: 'b', name: 'Mutton Dum Biryani', priceRupees: 340),
      line(id: 'c', name: 'Buttermilk', priceRupees: 30, qty: 3),
      line(id: 'd', name: 'Filter Coffee', priceRupees: 30, qty: 2,
          discountRupees: 10),
    ];

    for (final mode in TaxMode.values) {
      for (final inclusive in [false, true]) {
        test('$mode, inclusive=$inclusive, holds every invariant', () {
          final b = bill(
            cart,
            mode: mode,
            inclusive: inclusive,
            billDiscountRupees: 25,
          );
          expectConsistent(b);
          expect(b.subtotal.value, 48000 + 34000 + 9000 + 6000);
          expect(b.discount.value, 1000 + 2500);
          expect(b.lines, hasLength(4));
        });
      }
    }

    test('regular_5 exclusive, the arithmetic in full', () {
      final b = bill(cart, mode: TaxMode.regular5, billDiscountRupees: 25);
      // Lines after their own discounts: 480, 340, 90, 50. Total 960.
      // A 25 bill discount over 960 by weight, so taxable is 935.
      expect(b.taxable.value, 93500);
      // 2.5% of 935 is 23.375, but it is taxed line by line and then summed.
      expect(b.cgst.value, b.sgst.value);
      expect(b.total.value % 100, 0);
      expectConsistent(b);
    });
  });
}
