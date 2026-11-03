/// The billing and tax engine. Pure Dart: no Flutter, no database, no clock.
///
/// Everything here is a function of its arguments, so the whole thing is
/// testable in milliseconds and the hard rules live in one place.
///
/// Order of operations, fixed and tested:
///   1. line discounts
///   2. the bill discount, spread across lines in proportion to their value
///   3. tax per line, at that line's own rate, to the paisa
///   4. CGST and SGST as equal halves
///   5. the total rounded to the nearest rupee, the difference booked as
///      round-off
library;

import 'money.dart';

/// How the outlet is registered. Set once in settings, recorded over time in
/// `tax_profile_history` so old bills can be explained.
enum TaxMode {
  /// Below the registration threshold. A plain bill, no tax lines at all.
  unregistered,

  /// Composition scheme. Prints a Bill of Supply with no tax shown and the
  /// required declaration. A 5% turnover figure is computed for reporting only,
  /// and is never charged to the customer.
  composition,

  /// Regular registration. The outlet default for new items is 5%.
  regular5,

  /// Regular registration. The outlet default for new items is 18%.
  regular18;

  /// Whether a bill in this mode shows tax lines to the customer.
  bool get showsTax => this == regular5 || this == regular18;

  /// The rate a newly created menu item gets by default.
  TaxClass get defaultItemClass => switch (this) {
        regular18 => TaxClass.gst18,
        regular5 => TaxClass.gst5,
        // Nothing is taxed in these modes, but items still carry a class so
        // that switching to a regular mode later does not need a data migration.
        unregistered || composition => TaxClass.gst5,
      };
}

/// The rate band an item sits in. Stored per item, snapshotted onto every line.
///
/// This is what decides a line's rate: the item wins over the outlet's mode, so
/// cooked food at 5% and a sealed bottle at 18% can share one bill. The outlet
/// mode only decides *whether* tax applies at all, and what new items default to.
enum TaxClass {
  gst5(500),
  gst18(1800),
  nonGst(0);

  const TaxClass(this.basisPoints);

  /// The full GST rate in basis points. 500 bp is 5%.
  final int basisPoints;

  /// Half the rate, which is what CGST and what SGST each come to.
  int get halfBasisPoints => basisPoints ~/ 2;

  static TaxClass fromBasisPoints(int bp) => switch (bp) {
        500 => gst5,
        1800 => gst18,
        0 => nonGst,
        _ => throw ArgumentError.value(bp, 'bp', 'not a known GST rate'),
      };
}

/// Where the order came from. Aggregator orders are kept apart because on
/// Swiggy and Zomato the aggregator, not the restaurant, pays the GST under
/// section 9(5).
enum OrderType { dine, takeaway, aggregator }

/// What the document is called in law, which decides the printed heading.
enum DocType {
  /// A tax invoice. Shows CGST and SGST.
  invoice,

  /// No tax charged: composition scheme, unregistered, or an aggregator order.
  /// Carries the composition declaration when the mode calls for it.
  billOfSupply,

  /// Reserved for a later phase. Nothing in Phase 1 creates one.
  creditNote,
}

/// The outlet's tax configuration at the moment of billing.
class TaxConfig {
  const TaxConfig({
    required this.mode,
    required this.pricesIncludeTax,
    this.sacCode = '9963',
  });

  final TaxMode mode;

  /// Whether menu prices already contain the tax. Changes the arithmetic, not
  /// the printed total: with inclusive prices the customer pays the menu price
  /// and the tax is backed out of it.
  final bool pricesIncludeTax;

  /// Printed on tax invoices. Configurable, as 9963 is the restaurant-service
  /// code but the CA may want something else. See CA_REVIEW.md.
  final String sacCode;
}

/// One line as the billing screen holds it, before tax is worked out.
class CartLine {
  const CartLine({
    required this.itemId,
    required this.nameSnapshot,
    required this.unitPrice,
    required this.qty,
    required this.taxClass,
    this.lineDiscount = Paise.zero,
    this.nameTeSnapshot,
  });

  final String itemId;

  /// The item name as it is *now*. Copied onto the bill line so that renaming
  /// the item later cannot change this bill.
  final String nameSnapshot;
  final String? nameTeSnapshot;

  /// The price as it is now, likewise snapshotted.
  final Paise unitPrice;
  final int qty;
  final TaxClass taxClass;

  /// A discount on this line only, in money. Applied before the bill discount.
  final Paise lineDiscount;

  /// Price times quantity, before any discount.
  Paise get gross => unitPrice * qty;
}

/// A line with its tax resolved. This is what becomes a `bill_line` row.
class ComputedLine {
  const ComputedLine({
    required this.itemId,
    required this.nameSnapshot,
    required this.nameTeSnapshot,
    required this.unitPrice,
    required this.qty,
    required this.taxRateBp,
    required this.lineDiscount,
    required this.lineTotal,
    required this.taxable,
    required this.cgst,
    required this.sgst,
  });

  final String itemId;
  final String nameSnapshot;
  final String? nameTeSnapshot;
  final Paise unitPrice;
  final int qty;

  /// The rate actually applied, snapshotted in basis points. A later change to
  /// the item's tax class cannot alter this bill.
  final int taxRateBp;

  /// This line's share of every discount: its own, plus its proportional share
  /// of the bill discount.
  final Paise lineDiscount;

  /// What this line contributes to the total, tax included.
  /// Always equals `taxable + cgst + sgst`.
  final Paise lineTotal;

  final Paise taxable;
  final Paise cgst;
  final Paise sgst;

  Paise get tax => cgst + sgst;
}

/// Tax at one rate, summed. A bill carries one of these per rate in play, so a
/// mixed 5% and 18% bill prints two blocks.
class TaxRateBlock {
  const TaxRateBlock({
    required this.rateBp,
    required this.taxable,
    required this.cgst,
    required this.sgst,
  });

  final int rateBp;
  final Paise taxable;
  final Paise cgst;
  final Paise sgst;

  /// `"2.5"` for the CGST column header at 5%.
  String get halfRateLabel => _formatBp(rateBp ~/ 2);

  /// `"5"` for a "Taxable @ 5%" row.
  String get fullRateLabel => _formatBp(rateBp);

  static String _formatBp(int bp) {
    if (bp % 100 == 0) return (bp ~/ 100).toString();
    final s = (bp / 100).toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
}

/// A fully computed bill, ready to be saved and printed.
class ComputedBill {
  const ComputedBill({
    required this.docType,
    required this.orderType,
    required this.lines,
    required this.rateBlocks,
    required this.subtotal,
    required this.discount,
    required this.taxable,
    required this.cgst,
    required this.sgst,
    required this.roundOff,
    required this.total,
    required this.compositionTurnover,
    required this.showsTax,
    required this.sacCode,
  });

  final DocType docType;
  final OrderType orderType;
  final List<ComputedLine> lines;

  /// One block per rate in play, ascending by rate. Empty when no tax is shown.
  final List<TaxRateBlock> rateBlocks;

  /// Sum of price times quantity across lines, before any discount, in the
  /// menu's own terms (inclusive or exclusive as configured).
  final Paise subtotal;

  /// Every discount: line discounts plus the bill discount.
  final Paise discount;

  /// The pre-tax value of the sale. Always exclusive of tax.
  final Paise taxable;

  final Paise cgst;
  final Paise sgst;

  /// The difference between the exact total and the nearest rupee.
  final Paise roundOff;

  /// What the customer pays. Always a whole number of rupees.
  final Paise total;

  /// Composition scheme only: 5% of turnover, for the owner's own reporting.
  /// Never charged, never printed on the bill. Zero in every other mode.
  final Paise compositionTurnover;

  /// Whether this document shows tax lines.
  final bool showsTax;

  /// The SAC printed on a tax invoice.
  final String sacCode;

  Paise get tax => cgst + sgst;

  /// True when the restaurant does not owe the GST on this bill, because the
  /// aggregator pays it under section 9(5). Reports use this to keep aggregator
  /// orders out of the GST-payable figure while still counting the turnover.
  bool get gstPaidByAggregator => orderType == OrderType.aggregator;
}

/// Thrown when a cart cannot make a valid bill.
class BillingError implements Exception {
  BillingError(this.message);
  final String message;
  @override
  String toString() => 'BillingError: $message';
}

/// Works out a bill from a cart. The one entry point; nothing else computes tax.
///
/// [billDiscount] is a money amount off the whole bill, spread across lines in
/// proportion to their post-line-discount value.
ComputedBill computeBill({
  required List<CartLine> cart,
  required TaxConfig config,
  required OrderType orderType,
  Paise billDiscount = Paise.zero,
}) {
  if (cart.isEmpty) {
    throw BillingError('A bill must have at least one line.');
  }
  if (cart.any((l) => l.qty <= 0)) {
    throw BillingError('Quantity must be at least 1 on every line.');
  }
  if (billDiscount.isNegative) {
    throw BillingError('A discount cannot be negative.');
  }

  // --- 1. line discounts -----------------------------------------------
  final afterLineDiscount = <Paise>[];
  for (final line in cart) {
    if (line.lineDiscount.isNegative) {
      throw BillingError('A line discount cannot be negative.');
    }
    if (line.lineDiscount > line.gross) {
      throw BillingError(
        'The discount on "${line.nameSnapshot}" is more than the line itself.',
      );
    }
    afterLineDiscount.add(line.gross - line.lineDiscount);
  }

  final subtotal = cart.fold(Paise.zero, (sum, l) => sum + l.gross);
  final lineDiscountTotal =
      cart.fold(Paise.zero, (sum, l) => sum + l.lineDiscount);
  final afterLineDiscountTotal =
      afterLineDiscount.fold(Paise.zero, (sum, a) => sum + a);

  if (billDiscount > afterLineDiscountTotal) {
    throw BillingError('The bill discount is more than the bill itself.');
  }

  // --- 2. the bill discount, spread by value ---------------------------
  // Weighted so a line that is worth more absorbs more of the discount, and
  // allocateByWeights guarantees the parts add back up to the discount exactly.
  final billDiscountShares = billDiscount.isZero
      ? List<Paise>.filled(cart.length, Paise.zero)
      : billDiscount
          .allocateByWeights(afterLineDiscount.map((p) => p.value).toList());

  // Does this document carry tax at all?
  //
  // Aggregator orders never do: the aggregator pays the GST under section 9(5),
  // so charging it again here would double it. Composition and unregistered
  // outlets never do either.
  final taxed = config.mode.showsTax && orderType != OrderType.aggregator;

  // --- 3 and 4. tax per line, split into equal halves ------------------
  final lines = <ComputedLine>[];
  for (var i = 0; i < cart.length; i++) {
    final line = cart[i];
    final net = afterLineDiscount[i] - billDiscountShares[i];
    final rateBp = taxed ? line.taxClass.basisPoints : 0;

    Paise taxable;
    Paise half;

    if (!taxed || rateBp == 0) {
      taxable = net;
      half = Paise.zero;
    } else if (config.pricesIncludeTax) {
      // The menu price already contains the tax, so back it out. Each half is
      // net * (bp/2) / (10000 + bp), and the taxable value is whatever is left.
      // Doing it this way keeps taxable + cgst + sgst exactly equal to the
      // price the customer was quoted.
      final halfBp = rateBp ~/ 2;
      half = Paise(_divRound(net.value * halfBp, 10000 + rateBp));
      taxable = net - half - half;
    } else {
      // The menu price is pre-tax, so add the tax on top.
      taxable = net;
      half = taxable.percentBp(rateBp ~/ 2);
    }

    lines.add(ComputedLine(
      itemId: line.itemId,
      nameSnapshot: line.nameSnapshot,
      nameTeSnapshot: line.nameTeSnapshot,
      unitPrice: line.unitPrice,
      qty: line.qty,
      taxRateBp: rateBp,
      lineDiscount: line.lineDiscount + billDiscountShares[i],
      lineTotal: taxable + half + half,
      taxable: taxable,
      cgst: half,
      sgst: half,
    ));
  }

  // --- rate blocks, ascending ------------------------------------------
  final byRate = <int, List<ComputedLine>>{};
  for (final l in lines) {
    if (l.taxRateBp == 0) continue;
    byRate.putIfAbsent(l.taxRateBp, () => []).add(l);
  }
  final rateBlocks = (byRate.keys.toList()..sort())
      .map((bp) {
        final group = byRate[bp]!;
        return TaxRateBlock(
          rateBp: bp,
          taxable: group.fold(Paise.zero, (s, l) => s + l.taxable),
          cgst: group.fold(Paise.zero, (s, l) => s + l.cgst),
          sgst: group.fold(Paise.zero, (s, l) => s + l.sgst),
        );
      })
      .toList(growable: false);

  final taxableTotal = lines.fold(Paise.zero, (s, l) => s + l.taxable);
  final cgstTotal = lines.fold(Paise.zero, (s, l) => s + l.cgst);
  final sgstTotal = lines.fold(Paise.zero, (s, l) => s + l.sgst);

  // --- 5. round off to the nearest rupee -------------------------------
  final exact = taxableTotal + cgstTotal + sgstTotal;
  final total = exact.roundToRupee;
  final roundOff = total - exact;

  // Composition scheme: 5% of turnover, computed for the owner's own reporting
  // and never charged to anyone.
  final compositionTurnover = config.mode == TaxMode.composition
      ? taxableTotal.percentBp(500)
      : Paise.zero;

  final docType = taxed ? DocType.invoice : DocType.billOfSupply;

  return ComputedBill(
    docType: docType,
    orderType: orderType,
    lines: lines,
    rateBlocks: rateBlocks,
    subtotal: subtotal,
    discount: lineDiscountTotal + billDiscount,
    taxable: taxableTotal,
    cgst: cgstTotal,
    sgst: sgstTotal,
    roundOff: roundOff,
    total: total,
    compositionTurnover: compositionTurnover,
    showsTax: taxed,
    sacCode: config.sacCode,
  );
}

int _divRound(int numerator, int denominator) {
  assert(denominator > 0);
  if (numerator.isNegative) {
    return -((-numerator * 2 + denominator) ~/ (denominator * 2));
  }
  return (numerator * 2 + denominator) ~/ (denominator * 2);
}
