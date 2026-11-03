/// The cart: quantities, discounts, and the snapshot that protects a quoted
/// price from a menu edit mid-order.
library;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/features/billing/cart.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late ProviderContainer container;
  late ItemRow biryani;
  late ItemRow drink;
  late ItemRow water;

  // Local functions, not getters: a getter declaration is not legal
  // inside a function body.
  CartNotifier cart() => container.read(cartProvider.notifier);
  CartState state() => container.read(cartProvider);

  setUp(() async {
    f = await Fixture.create();
    container = ProviderContainer();
    addTearDown(container.dispose);

    Future<ItemRow> load(String id) =>
        (f.db.select(f.db.items)..where((i) => i.id.equals(id))).getSingle();
    biryani = await load(kItemBiryani);
    drink = await load(kItemColdDrink);
    water = await load(kItemWater);
  });

  tearDown(() => f.close());

  group('adding', () {
    test('an empty cart has nothing', () {
      expect(state().isEmpty, isTrue);
      expect(state().itemCount, 0);
      expect(state().subtotal.value, 0);
    });

    test('adding puts one line on the bill', () {
      cart().add(biryani);
      expect(state().entries, hasLength(1));
      expect(state().entries.single.qty, 1);
      expect(state().itemCount, 1);
    });

    test('adding the same item again increments rather than adding a line',
        () {
      cart().add(biryani);
      cart().add(biryani);
      cart().add(biryani);
      expect(state().entries, hasLength(1),
          reason: '"1 Biryani / 1 Biryani" looks like a mistake to a customer');
      expect(state().entries.single.qty, 3);
      expect(state().itemCount, 3);
    });

    test('different items get their own lines, in the order added', () {
      cart().add(drink);
      cart().add(biryani);
      expect(state().entries.map((e) => e.itemId), [drink.id, biryani.id]);
    });

    test('the subtotal is price times quantity', () {
      cart().add(biryani);
      cart().add(biryani);
      cart().add(water);
      expect(state().subtotal.value, 24000 * 2 + 2000);
    });

    test('qtyOf reports what is on the bill, for the grid badge', () {
      cart().add(biryani);
      cart().add(biryani);
      expect(state().qtyOf(biryani.id), 2);
      expect(state().qtyOf(drink.id), 0);
    });
  });

  group('quantities', () {
    test('increment and decrement', () {
      cart().add(biryani);
      cart().increment(biryani.id);
      expect(state().entries.single.qty, 2);
      cart().decrement(biryani.id);
      expect(state().entries.single.qty, 1);
    });

    test('decrementing the last one removes the line', () {
      cart().add(biryani);
      cart().decrement(biryani.id);
      expect(state().isEmpty, isTrue,
          reason: 'a zero-quantity line would print as a blank row');
    });

    test('decrementing something not there does nothing', () {
      cart().add(biryani);
      cart().decrement(drink.id);
      expect(state().entries, hasLength(1));
    });

    test('setQty sets it directly', () {
      cart().add(biryani);
      cart().setQty(biryani.id, 12);
      expect(state().entries.single.qty, 12);
    });

    test('setQty to zero or less removes the line', () {
      cart().add(biryani);
      cart().setQty(biryani.id, 0);
      expect(state().isEmpty, isTrue);

      cart().add(biryani);
      cart().setQty(biryani.id, -3);
      expect(state().isEmpty, isTrue);
    });

    test('quantity is capped, so a stuck finger cannot bill 900 plates', () {
      cart().add(biryani);
      for (var i = 0; i < 1200; i++) {
        cart().increment(biryani.id);
      }
      expect(state().entries.single.qty, 999);

      cart().setQty(biryani.id, 100000);
      expect(state().entries.single.qty, 999);
    });
  });

  group('discounts', () {
    test('a line discount is kept', () {
      cart().add(biryani);
      cart().setLineDiscount(biryani.id, Paise.fromRupees(40));
      expect(state().entries.single.lineDiscount.value, 4000);
    });

    test('a line discount cannot exceed the line', () {
      cart().add(biryani);
      cart().setLineDiscount(biryani.id, Paise.fromRupees(999));
      expect(
        state().entries.single.lineDiscount.value,
        24000,
        reason: 'a bigger discount would make the bill negative',
      );
    });

    test('a negative line discount is treated as none', () {
      cart().add(biryani);
      cart().setLineDiscount(biryani.id, const Paise(-500));
      expect(state().entries.single.lineDiscount.value, 0);
    });

    test('a bill discount is kept', () {
      cart().add(biryani);
      cart().setBillDiscount(Paise.fromRupees(30));
      expect(state().billDiscount.value, 3000);
    });

    test('a bill discount cannot exceed what is left after line discounts',
        () {
      cart().add(biryani);
      cart().setLineDiscount(biryani.id, Paise.fromRupees(200));
      cart().setBillDiscount(Paise.fromRupees(999));
      expect(state().billDiscount.value, 4000, reason: '240 less 200 is 40');
    });

    test('a negative bill discount is treated as none', () {
      cart().add(biryani);
      cart().setBillDiscount(const Paise(-100));
      expect(state().billDiscount.value, 0);
    });
  });

  group('order type', () {
    test('defaults to dine in', () {
      expect(state().orderType, OrderType.dine);
    });

    test('can be changed', () {
      cart().setOrderType(OrderType.aggregator);
      expect(state().orderType, OrderType.aggregator);
    });
  });

  group('clearing', () {
    test('empties everything, discounts and order type included', () {
      cart().add(biryani);
      cart().setBillDiscount(Paise.fromRupees(10));
      cart().setOrderType(OrderType.takeaway);

      cart().clear();

      expect(state().isEmpty, isTrue);
      expect(state().billDiscount.value, 0);
      expect(state().orderType, OrderType.dine,
          reason: 'the next customer is a fresh bill');
    });
  });

  group('the price snapshot', () {
    test('a menu price change mid-order does not change what is quoted',
        () async {
      cart().add(biryani);
      expect(state().entries.single.unitPrice.value, 24000);

      // The owner edits the price while the bill is open at the counter.
      await (f.db.update(f.db.items)..where((i) => i.id.equals(biryani.id)))
          .write(ItemsCompanion(
        pricePaise: Value(Paise.fromRupees(500)),
        updatedAt: Value(DateTime(2026, 7, 1)),
      ));

      expect(
        state().entries.single.unitPrice.value,
        24000,
        reason: 'the customer pays what they were quoted',
      );
      expect(state().subtotal.value, 24000);
    });

    test('the Telugu name is carried for the receipt', () {
      cart().add(biryani);
      expect(state().entries.single.nameTe, 'చికెన్ దమ్ బిర్యానీ');
      expect(state().entries.single.toCartLine().nameTeSnapshot,
          'చికెన్ దమ్ బిర్యానీ');
    });

    test('an item with no Telugu name carries null, not an empty string', () {
      cart().add(water);
      expect(state().entries.single.toCartLine().nameTeSnapshot, isNull);
    });
  });

  group('pricing the cart', () {
    const config = TaxConfig(mode: TaxMode.regular5, pricesIncludeTax: false);

    test('an empty cart prices to nothing', () {
      expect(priceCart(state(), config), isNull);
    });

    test('a simple cart matches the tax engine', () {
      cart().add(biryani);
      final bill = priceCart(state(), config)!;
      expect(bill.taxable.value, 24000);
      expect(bill.cgst.value, 600);
      expect(bill.total.value, 25200);
    });

    test('mixed rates come through per block', () {
      cart().add(biryani);
      cart().add(drink);
      cart().add(water);
      final bill = priceCart(state(), config)!;
      expect(bill.rateBlocks, hasLength(2));
      expect(bill.rateBlocks[0].rateBp, 500);
      expect(bill.rateBlocks[1].rateBp, 1800);
    });

    test('discounts reach the engine', () {
      cart().add(biryani);
      cart().setBillDiscount(Paise.fromRupees(40));
      final bill = priceCart(state(), config)!;
      expect(bill.discount.value, 4000);
      expect(bill.taxable.value, 20000);
    });

    test('an aggregator order is untaxed even on a registered outlet', () {
      cart().add(biryani);
      cart().setOrderType(OrderType.aggregator);
      final bill = priceCart(state(), config)!;
      expect(bill.cgst.value, 0);
      expect(bill.docType, DocType.billOfSupply);
      expect(bill.gstPaidByAggregator, isTrue);
    });

    test('the lines handed to the engine keep their snapshots', () {
      cart().add(biryani);
      cart().increment(biryani.id);
      final bill = priceCart(state(), config)!;
      expect(bill.lines.single.nameSnapshot, 'Chicken Dum Biryani');
      expect(bill.lines.single.qty, 2);
      expect(bill.lines.single.unitPrice.value, 24000);
    });
  });
}
