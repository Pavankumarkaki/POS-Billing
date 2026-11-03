/// The cart: what is on the bill before it is saved.
///
/// Holds a snapshot of each item at the moment it was added, not a reference
/// to the menu row. If the owner edits a price on another device, or in another
/// tab, while a bill is open at the counter, the customer still pays what they
/// were quoted. The same snapshot is what `commitSale` writes to `bill_line`.
///
/// This is state, not arithmetic. Every total comes from `computeBill` in
/// `core/tax.dart`, so there is exactly one place where tax is worked out.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/tax.dart';
import '../../data/db.dart';

/// One line in the cart.
class CartEntry {
  const CartEntry({
    required this.itemId,
    required this.nameEn,
    required this.nameTe,
    required this.unitPrice,
    required this.taxClass,
    required this.qty,
    this.lineDiscount = Paise.zero,
  });

  final String itemId;
  final String nameEn;
  final String nameTe;
  final Paise unitPrice;
  final TaxClass taxClass;
  final int qty;
  final Paise lineDiscount;

  Paise get gross => unitPrice * qty;

  CartEntry copyWith({int? qty, Paise? lineDiscount}) => CartEntry(
        itemId: itemId,
        nameEn: nameEn,
        nameTe: nameTe,
        unitPrice: unitPrice,
        taxClass: taxClass,
        qty: qty ?? this.qty,
        lineDiscount: lineDiscount ?? this.lineDiscount,
      );

  CartLine toCartLine() => CartLine(
        itemId: itemId,
        nameSnapshot: nameEn,
        nameTeSnapshot: nameTe.isEmpty ? null : nameTe,
        unitPrice: unitPrice,
        qty: qty,
        taxClass: taxClass,
        lineDiscount: lineDiscount,
      );
}

/// Everything the billing screen holds before the sale is committed.
class CartState {
  const CartState({
    this.entries = const [],
    this.orderType = OrderType.dine,
    this.billDiscount = Paise.zero,
  });

  /// In the order they were added, so the receipt reads the way the order was
  /// taken rather than alphabetically.
  final List<CartEntry> entries;

  final OrderType orderType;
  final Paise billDiscount;

  bool get isEmpty => entries.isEmpty;
  bool get isNotEmpty => entries.isNotEmpty;

  /// Total number of things, not lines. "3 items" means three plates.
  int get itemCount => entries.fold(0, (sum, e) => sum + e.qty);

  Paise get subtotal => entries.fold(Paise.zero, (sum, e) => sum + e.gross);

  int qtyOf(String itemId) =>
      entries.where((e) => e.itemId == itemId).fold(0, (s, e) => s + e.qty);

  CartState copyWith({
    List<CartEntry>? entries,
    OrderType? orderType,
    Paise? billDiscount,
  }) =>
      CartState(
        entries: entries ?? this.entries,
        orderType: orderType ?? this.orderType,
        billDiscount: billDiscount ?? this.billDiscount,
      );
}

class CartNotifier extends Notifier<CartState> {
  @override
  CartState build() => const CartState();

  /// Adds one of [item], or increments it if it is already on the bill.
  ///
  /// Tapping the same tile twice means two plates, not two lines: a receipt
  /// reading "1 Biryani / 1 Biryani" would look like a mistake to a customer.
  void add(ItemRow item) {
    final index = state.entries.indexWhere((e) => e.itemId == item.id);
    if (index >= 0) {
      increment(item.id);
      return;
    }
    state = state.copyWith(entries: [
      ...state.entries,
      CartEntry(
        itemId: item.id,
        nameEn: item.nameEn,
        nameTe: item.nameTe,
        unitPrice: item.pricePaise,
        taxClass: item.taxClass,
        qty: 1,
      ),
    ]);
  }

  void increment(String itemId) => _update(itemId, (e) {
        // A plausible ceiling. Without one, a stuck finger can bill 900 plates
        // and the mistake is only caught when the customer reads the total.
        if (e.qty >= 999) return e;
        return e.copyWith(qty: e.qty + 1);
      });

  /// Decrements, removing the line when it reaches zero.
  void decrement(String itemId) {
    final entry = state.entries.where((e) => e.itemId == itemId).firstOrNull;
    if (entry == null) return;
    if (entry.qty <= 1) {
      remove(itemId);
      return;
    }
    _update(itemId, (e) => e.copyWith(qty: e.qty - 1));
  }

  void setQty(String itemId, int qty) {
    if (qty <= 0) {
      remove(itemId);
      return;
    }
    _update(itemId, (e) => e.copyWith(qty: qty > 999 ? 999 : qty));
  }

  void remove(String itemId) => state = state.copyWith(
        entries:
            state.entries.where((e) => e.itemId != itemId).toList(growable: false),
      );

  /// A discount on one line. Clamped to the line's own value: a discount
  /// bigger than the line would make the bill negative.
  void setLineDiscount(String itemId, Paise discount) => _update(itemId, (e) {
        final capped = discount.isNegative
            ? Paise.zero
            : (discount > e.gross ? e.gross : discount);
        return e.copyWith(lineDiscount: capped);
      });

  /// A discount on the whole bill, spread across lines by `computeBill`.
  void setBillDiscount(Paise discount) {
    final afterLines = state.entries.fold(
      Paise.zero,
      (Paise sum, e) => sum + (e.gross - e.lineDiscount),
    );
    final capped = discount.isNegative
        ? Paise.zero
        : (discount > afterLines ? afterLines : discount);
    state = state.copyWith(billDiscount: capped);
  }

  void setOrderType(OrderType type) => state = state.copyWith(orderType: type);

  void clear() => state = const CartState();

  void _update(String itemId, CartEntry Function(CartEntry) change) {
    state = state.copyWith(
      entries: [
        for (final e in state.entries)
          if (e.itemId == itemId) change(e) else e,
      ],
    );
  }
}

final cartProvider = NotifierProvider<CartNotifier, CartState>(
  CartNotifier.new,
);

/// The cart priced up, or null when it is empty.
///
/// All the arithmetic happens in `computeBill`; this only feeds it the cart and
/// the outlet's tax configuration.
ComputedBill? priceCart(CartState cart, TaxConfig config) {
  if (cart.isEmpty) return null;
  return computeBill(
    cart: [for (final e in cart.entries) e.toCartLine()],
    config: config,
    orderType: cart.orderType,
    billDiscount: cart.billDiscount,
  );
}
