/// Turning a saved bill into paper.
///
/// The ordering rule from the brief lives at the call site, but it is worth
/// stating here because this class is what makes it safe to follow: **nothing
/// in this file can lose a bill**. Every method takes a bill that is already
/// committed, reads it back from the database, and prints it. A failure
/// returns a [PrintResult] the screen can offer a retry for; it never rolls
/// anything back, because there is nothing of the sale left to roll back.
library;

import 'dart:convert';


import '../core/domain.dart';
import '../core/invoice_no.dart';
import '../core/money.dart';
import '../core/receipt.dart';
import '../core/tax.dart';
import '../data/db.dart';
import 'print_queue.dart';
import 'printer.dart';
import 'receipt_renderer.dart';

class PrintService {
  /// [db] is positional because a private field cannot be a NAMED
  /// initializing formal in Dart: named parameters may not start with an
  /// underscore.
  PrintService(
    this._db, {
    required this.printer,
    PrintQueue? queue,
  }) : _queue = queue ?? PrintQueue();

  final PosDatabase _db;

  /// The printer in use. Swapped when the owner changes the connection.
  final Printer printer;
  final PrintQueue _queue;

  PrintQueue get queue => _queue;

  /// Prints a bill that is already saved.
  ///
  /// Reads everything back from the database rather than taking it from the
  /// screen, so a reprint months later produces exactly the same paper as the
  /// original: the snapshots on `bill_line` are the source of truth, not
  /// whatever the menu says today.
  Future<PrintResult> printBill(
    String billId, {
    bool duplicate = false,
  }) =>
      _queue.add(() async {
        final doc = await buildDocFor(billId, duplicate: duplicate);
        if (doc == null) {
          return const PrintResult.failure('That bill could not be found.');
        }

        final config = await printerConfig();

        try {
          final bitmap = await renderReceipt(doc, width: config.widthPx);
          return await printer.printBitmap(
            bitmap,
            config: config,
            jobName: doc.invoiceNo,
          );
        } on Object catch (e) {
          return PrintResult.failure(
            'The receipt could not be prepared.',
            detail: '$e',
          );
        }
      });

  /// A one-off test page, for the printer settings screen.
  Future<PrintResult> printTestPage() => _queue.add(() async {
        final outlet = await _db.select(_db.outlets).getSingleOrNull();
        final config = await printerConfig();

        final doc = ReceiptDoc(
          invoiceNo: 'test-page',
          blocks: [
            const TextLine(
              'PRINTER TEST',
              align: Align.centre,
              bold: true,
              scale: TextScale.large,
            ),
            const SpacerBlock(),
            TextLine(outlet?.name ?? 'Billing',
                align: Align.centre, bold: true),
            const DividerBlock(),
            // If this line is boxes rather than Telugu, the bitmap path is
            // broken, which is exactly what a test page is for.
            const TextLine('చికెన్ దమ్ బిర్యానీ', align: Align.centre),
            const TextLine('మజ్జిగ · పెసరట్టు', align: Align.centre),
            const SpacerBlock(),
            const TwoColumn('Rupee sign', '₹1,234.50'),
            const TwoColumn('Width', ''),
            TwoColumn('Dots across', '${config.widthPx}'),
            TwoColumn('Raster', config.useEscStar ? 'ESC *' : 'GS v 0'),
            TwoColumn('Auto cut', config.autoCut ? 'Yes' : 'No'),
            const DividerBlock(),
            const TextLine(
              'If the Telugu above reads correctly and the ruler below '
              'reaches both edges, this printer is set up right.',
              align: Align.centre,
              scale: TextScale.small,
            ),
            const SpacerBlock(),
            // A full-width row of characters: if it wraps or is clipped, the
            // configured width does not match the actual head.
            const TextLine(
              '|....|....|....|....|....|....|....|....|....|....|',
              align: Align.centre,
              scale: TextScale.small,
            ),
            const SpacerBlock(2),
          ],
        );

        try {
          final bitmap = await renderReceipt(doc, width: config.widthPx);
          return await printer.printBitmap(
            bitmap,
            config: config,
            jobName: 'test-page',
          );
        } on Object catch (e) {
          return PrintResult.failure(
            'The test page could not be prepared.',
            detail: '$e',
          );
        }
      });

  /// The printer settings stored on the device row.
  Future<PrinterConfig> printerConfig() async {
    final device = await _db.select(_db.devices).getSingleOrNull();
    if (device == null) return const PrinterConfig();
    try {
      final json = jsonDecode(device.printerCfg) as Map<String, Object?>;
      return PrinterConfig.fromJson(json);
    } on Object {
      // A corrupt config must not stop the restaurant billing. Fall back to
      // the defaults and let the settings screen fix it.
      return const PrinterConfig();
    }
  }

  /// Rebuilds the receipt for a saved bill.
  ///
  /// Public because the fake-printer tests and the settings preview both want
  /// the document without printing it.
  Future<ReceiptDoc?> buildDocFor(
    String billId, {
    bool duplicate = false,
  }) async {
    final bill = await (_db.select(_db.bills)..where((b) => b.id.equals(billId)))
        .getSingleOrNull();
    if (bill == null) return null;

    final outlet = await _db.select(_db.outlets).getSingleOrNull();
    final device = await _db.select(_db.devices).getSingleOrNull();
    if (outlet == null || device == null) return null;

    final lines = await (_db.select(_db.billLines)
          ..where((l) => l.billId.equals(billId)))
        .get();
    final payments = await (_db.select(_db.payments)
          ..where((p) => p.billId.equals(billId)))
        .get();

    final cashier = await (_db.select(_db.users)
          ..where((u) => u.id.equals(bill.createdBy)))
        .getSingleOrNull();

    final invoiceNo = InvoiceNo.tryParse(bill.invoiceNo) ??
        InvoiceNo.build(
          devicePrefix: device.seriesPrefix,
          fy: bill.fy,
          seq: bill.deviceSeq,
        );

    // Rebuild the tax blocks from the stored line splits rather than
    // recomputing them. Recomputing would use today's rates, and a reprint of
    // a year-old bill must show what was charged then.
    final byRate = <int, List<BillLineRow>>{};
    for (final l in lines) {
      if (l.taxRate == 0) continue;
      byRate.putIfAbsent(l.taxRate, () => []).add(l);
    }
    final rateBlocks = (byRate.keys.toList()..sort())
        .map((bp) {
          final group = byRate[bp]!;
          return TaxRateBlock(
            rateBp: bp,
            taxable: group.fold(Paise.zero, (Paise s, l) => s + l.taxable),
            cgst: group.fold(Paise.zero, (Paise s, l) => s + l.cgst),
            sgst: group.fold(Paise.zero, (Paise s, l) => s + l.sgst),
          );
        })
        .toList(growable: false);

    final computed = ComputedBill(
      docType: bill.docType,
      orderType: bill.orderType,
      lines: const [],
      rateBlocks: rateBlocks,
      subtotal: bill.subtotal,
      discount: bill.discount,
      taxable: bill.taxable,
      cgst: bill.cgst,
      sgst: bill.sgst,
      roundOff: bill.roundOff,
      total: bill.total,
      compositionTurnover: bill.compositionTurnover,
      showsTax: bill.cgst.isPositive || bill.sgst.isPositive,
      sacCode: outlet.sacCode,
    );

    return buildReceipt(
      outlet: ReceiptOutlet(
        name: outlet.name,
        address: outlet.address,
        phone: outlet.phone,
        fssaiNo: outlet.fssaiNo,
        taxMode: outlet.taxMode,
        gstin: outlet.gstin,
        billFooter: outlet.billFooter,
        upiVpa: outlet.upiVpa,
        sacCode: outlet.sacCode,
      ),
      bill: computed,
      invoiceNo: invoiceNo,
      at: bill.createdAt,
      businessDate: bill.businessDate,
      lines: [
        for (final l in lines)
          ReceiptLine(
            name: l.nameSnapshot,
            nameTe: l.nameTeSnapshot,
            qty: l.qty,
            unitPrice: l.unitPrice,
            lineTotal: l.lineTotal,
          ),
      ],
      payments: [
        for (final p in payments) (mode: p.mode, amount: p.amount),
      ],
      cashierName: cashier?.name ?? '',
      duplicate: duplicate,
      cancelled: bill.status == BillStatus.cancelled,
      cancelReason: bill.cancelReason,
    );
  }
}
