/// What goes on a receipt, as data rather than pixels.
///
/// Pure Dart: no Flutter, no printer, no bitmap. That matters because this is
/// where the legal requirements live, and they deserve tests that run in
/// milliseconds without a rendering engine:
///
///   - the FSSAI number appears on every bill in every tax mode
///   - a tax invoice says TAX INVOICE; a composition or unregistered bill says
///     BILL OF SUPPLY and carries the composition declaration where required
///   - a reprint is marked DUPLICATE
///   - tax is shown per rate, so a 5% and an 18% line can share one bill
///
/// The renderer in `printing/` turns this into a bitmap. Swapping the renderer,
/// or printing to a file instead of paper, changes nothing here.
library;

import 'business_date.dart';
import 'domain.dart';
import 'invoice_no.dart';
import 'money.dart';
import 'tax.dart';

/// How a block of text sits on the paper.
enum Align { left, centre, right }

/// Relative text size. The renderer decides actual pixels.
enum TextScale {
  /// Item names, totals breakdown.
  normal,

  /// Fine print: the declaration, the footer.
  small,

  /// The shop name, the grand total, DUPLICATE.
  large,
}

/// One thing on the receipt.
sealed class ReceiptBlock {
  const ReceiptBlock();
}

/// A line of text across the paper.
class TextLine extends ReceiptBlock {
  const TextLine(
    this.text, {
    this.align = Align.left,
    this.bold = false,
    this.scale = TextScale.normal,
  });

  final String text;
  final Align align;
  final bool bold;
  final TextScale scale;
}

/// Left text, right text, on one line. Used for every amount.
class TwoColumn extends ReceiptBlock {
  const TwoColumn(
    this.left,
    this.right, {
    this.bold = false,
    this.scale = TextScale.normal,
  });

  final String left;
  final String right;
  final bool bold;
  final TextScale scale;
}

/// An item row: quantity and name on the left, amount on the right, with the
/// Telugu name underneath when there is one.
class ItemRowBlock extends ReceiptBlock {
  const ItemRowBlock({
    required this.qty,
    required this.name,
    required this.amount,
    this.nameTe,
    this.unitPrice,
  });

  final int qty;
  final String name;
  final String? nameTe;
  final String amount;
  final String? unitPrice;
}

/// A horizontal rule.
class DividerBlock extends ReceiptBlock {
  const DividerBlock();
}

/// Vertical space, in multiples of a line.
class SpacerBlock extends ReceiptBlock {
  const SpacerBlock([this.lines = 1]);
  final int lines;
}

/// A ruler spanning the full printable width, with ticks.
///
/// Drawn rather than typed out as characters: a row of `|....|....` is
/// whatever width the font makes it, which on the first test page fell well
/// short of the paper and made a correctly configured printer look wrong.
/// This is laid out to the exact content width, so if it does not reach both
/// edges the configured width really is wrong.
class RulerBlock extends ReceiptBlock {
  const RulerBlock();
}

/// A QR code, for UPI payment.
class QrBlock extends ReceiptBlock {
  const QrBlock(this.data, {this.caption});
  final String data;
  final String? caption;
}

/// A complete receipt, ready to render.
class ReceiptDoc {
  const ReceiptDoc({required this.blocks, required this.invoiceNo});

  final List<ReceiptBlock> blocks;

  /// For naming the file the fake printer writes.
  final String invoiceNo;
}

/// Everything about the outlet the receipt needs.
class ReceiptOutlet {
  const ReceiptOutlet({
    required this.name,
    required this.address,
    required this.phone,
    required this.fssaiNo,
    required this.taxMode,
    this.gstin,
    this.billFooter = '',
    this.upiVpa,
    this.sacCode = '9963',
  });

  final String name;
  final String address;
  final String phone;
  final String fssaiNo;
  final TaxMode taxMode;
  final String? gstin;
  final String billFooter;
  final String? upiVpa;
  final String sacCode;
}

/// One line as it was sold.
class ReceiptLine {
  const ReceiptLine({
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.lineTotal,
    this.nameTe,
  });

  final String name;
  final String? nameTe;
  final int qty;
  final Paise unitPrice;
  final Paise lineTotal;
}

/// The declaration a composition dealer must print, per rule 5(1)(f).
///
/// The exact wording is in CA_REVIEW.md section 4 for the restaurant's CA to
/// approve. Changing it is a one-line change here.
const String kCompositionDeclaration =
    'Composition taxable person, not eligible to collect tax on supplies.';

/// Builds the receipt.
///
/// [showTelugu] adds the Telugu item name under each English one. It does not
/// translate the labels: a bill has to stay readable to an accountant, and
/// mixed-script labels help nobody.
ReceiptDoc buildReceipt({
  required ReceiptOutlet outlet,
  required ComputedBill bill,
  required InvoiceNo invoiceNo,
  required DateTime at,
  required BusinessDate businessDate,
  required List<ReceiptLine> lines,
  required List<({PaymentMode mode, Paise amount})> payments,
  required String cashierName,
  bool duplicate = false,
  bool cancelled = false,
  String? cancelReason,
  bool showTelugu = true,
}) {
  final blocks = <ReceiptBlock>[];

  // --- a reprint says so, at the top where it cannot be missed ---------
  if (duplicate) {
    blocks
      ..add(const TextLine(
        'DUPLICATE',
        align: Align.centre,
        bold: true,
        scale: TextScale.large,
      ))
      ..add(const SpacerBlock());
  }

  if (cancelled) {
    blocks
      ..add(const TextLine(
        'CANCELLED',
        align: Align.centre,
        bold: true,
        scale: TextScale.large,
      ))
      ..add(TextLine(
        cancelReason == null ? '' : 'Reason: $cancelReason',
        align: Align.centre,
        scale: TextScale.small,
      ))
      ..add(const SpacerBlock());
  }

  // --- the shop -------------------------------------------------------
  blocks
    ..add(TextLine(
      outlet.name,
      align: Align.centre,
      bold: true,
      scale: TextScale.large,
    ))
    ..add(TextLine(outlet.address,
        align: Align.centre, scale: TextScale.small))
    ..add(TextLine('Ph: ${outlet.phone}',
        align: Align.centre, scale: TextScale.small));

  // The brief: the FSSAI number appears on EVERY bill, in EVERY tax mode.
  blocks.add(TextLine(
    'FSSAI: ${outlet.fssaiNo}',
    align: Align.centre,
    scale: TextScale.small,
  ));

  if (outlet.gstin != null && outlet.gstin!.isNotEmpty) {
    blocks.add(TextLine(
      'GSTIN: ${outlet.gstin}',
      align: Align.centre,
      scale: TextScale.small,
    ));
  }

  // --- what this document is ------------------------------------------
  blocks
    ..add(const SpacerBlock())
    ..add(TextLine(
      _documentHeading(bill),
      align: Align.centre,
      bold: true,
    ));

  if (bill.orderType == OrderType.aggregator) {
    blocks.add(const TextLine(
      'Aggregator order',
      align: Align.centre,
      scale: TextScale.small,
    ));
  }

  blocks
    ..add(const DividerBlock())
    ..add(TwoColumn('Bill', invoiceNo.formatted, scale: TextScale.small))
    ..add(TwoColumn('Date', _formatDateTime(at), scale: TextScale.small))
    ..add(TwoColumn('Day', businessDate.iso, scale: TextScale.small))
    ..add(TwoColumn('Type', _orderTypeLabel(bill.orderType),
        scale: TextScale.small))
    ..add(TwoColumn('By', cashierName, scale: TextScale.small));

  if (bill.showsTax) {
    blocks.add(TwoColumn('SAC', outlet.sacCode, scale: TextScale.small));
  }

  // --- the items ------------------------------------------------------
  blocks.add(const DividerBlock());
  for (final l in lines) {
    blocks.add(ItemRowBlock(
      qty: l.qty,
      name: l.name,
      nameTe: showTelugu ? l.nameTe : null,
      amount: l.lineTotal.plain,
      unitPrice: l.qty > 1 ? l.unitPrice.plain : null,
    ));
  }
  blocks.add(const DividerBlock());

  // --- the money ------------------------------------------------------
  blocks.add(TwoColumn('Subtotal', bill.subtotal.plain));

  if (bill.discount.isPositive) {
    blocks.add(TwoColumn('Discount', '-${bill.discount.plain}'));
  }

  // One block per rate in play, so a mixed-rate bill is itemised properly
  // rather than collapsed into a single misleading figure.
  for (final b in bill.rateBlocks) {
    blocks
      ..add(TwoColumn(
        'Taxable @ ${b.fullRateLabel}%',
        b.taxable.plain,
        scale: TextScale.small,
      ))
      ..add(TwoColumn('CGST ${b.halfRateLabel}%', b.cgst.plain))
      ..add(TwoColumn('SGST ${b.halfRateLabel}%', b.sgst.plain));
  }

  if (!bill.roundOff.isZero) {
    final sign = bill.roundOff.isNegative ? '-' : '+';
    blocks.add(TwoColumn('Round off', '$sign${bill.roundOff.abs.plain}'));
  }

  blocks
    ..add(const DividerBlock())
    ..add(TwoColumn(
      'TOTAL',
      bill.total.plain,
      bold: true,
      scale: TextScale.large,
    ));

  // --- how they paid ---------------------------------------------------
  if (payments.isNotEmpty) {
    blocks.add(const SpacerBlock());
    for (final p in payments) {
      blocks.add(TwoColumn(
        _paymentLabel(p.mode),
        p.amount.plain,
        scale: TextScale.small,
      ));
    }
  }

  // --- declarations and footer -----------------------------------------
  if (outlet.taxMode == TaxMode.composition) {
    blocks
      ..add(const SpacerBlock())
      ..add(const TextLine(
        kCompositionDeclaration,
        align: Align.centre,
        scale: TextScale.small,
      ));
  }

  if (bill.gstPaidByAggregator) {
    blocks
      ..add(const SpacerBlock())
      ..add(const TextLine(
        'Tax on this order is paid by the aggregator.',
        align: Align.centre,
        scale: TextScale.small,
      ));
  }

  if (outlet.upiVpa != null && outlet.upiVpa!.isNotEmpty && !cancelled) {
    blocks
      ..add(const SpacerBlock())
      ..add(QrBlock(
        _upiUri(
          vpa: outlet.upiVpa!,
          name: outlet.name,
          amount: bill.total,
          note: invoiceNo.formatted,
        ),
        caption: 'Scan to pay by UPI',
      ));
  }

  if (outlet.billFooter.isNotEmpty) {
    blocks
      ..add(const SpacerBlock())
      ..add(TextLine(
        outlet.billFooter,
        align: Align.centre,
        scale: TextScale.small,
      ));
  }

  blocks.add(const SpacerBlock(2));

  return ReceiptDoc(blocks: blocks, invoiceNo: invoiceNo.formatted);
}

String _documentHeading(ComputedBill bill) => switch (bill.docType) {
      DocType.invoice => 'TAX INVOICE',
      DocType.billOfSupply => 'BILL OF SUPPLY',
      DocType.creditNote => 'CREDIT NOTE',
    };

String _orderTypeLabel(OrderType t) => switch (t) {
      OrderType.dine => 'Dine in',
      OrderType.takeaway => 'Takeaway',
      OrderType.aggregator => 'Aggregator',
    };

String _paymentLabel(PaymentMode m) => switch (m) {
      PaymentMode.cash => 'Cash',
      PaymentMode.upi => 'UPI',
      PaymentMode.card => 'Card',
      PaymentMode.aggregator => 'Aggregator',
      PaymentMode.credit => 'Credit',
    };

/// `02/11/2026 14:35`. Deliberately not `intl`: this is pure Dart, and a
/// receipt date needs one fixed format, not a locale-sensitive one.
String _formatDateTime(DateTime at) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(at.day)}/${two(at.month)}/${at.year} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// A UPI intent URI, per the NPCI deep-linking spec.
///
/// `am` is in rupees with two decimals, which is what UPI apps expect, even
/// though everything else in this codebase is paise.
String _upiUri({
  required String vpa,
  required String name,
  required Paise amount,
  required String note,
}) {
  final params = {
    'pa': vpa,
    'pn': name,
    'am': amount.plain,
    'cu': 'INR',
    'tn': note,
  };
  final query = params.entries
      .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
      .join('&');
  return 'upi://pay?$query';
}
