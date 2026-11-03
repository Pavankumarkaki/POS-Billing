/// Writes sample receipts to `build/receipts/` so they can be looked at.
///
/// Not an assertion-heavy test: its job is to produce the artefact the
/// definition of done asks for, a receipt bitmap you can open and inspect
/// without owning a thermal printer. Run it with:
///
///     flutter test test/printing/sample_receipts_test.dart
///
/// then open `build/receipts/`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/invoice_no.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/receipt.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/printing/fake_printer.dart';
import 'package:restaurant_pos/printing/printer.dart';
import 'package:restaurant_pos/printing/receipt_renderer.dart';
import 'package:restaurant_pos/theme/app_theme.dart';

void main() {
  late Directory out;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final bytes =
        File('assets/fonts/AnekTelugu-Variable.ttf').readAsBytesSync();
    final loader = FontLoader(kFontFamily)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();

    out = Directory('build/receipts');
    if (out.existsSync()) out.deleteSync(recursive: true);
    out.createSync(recursive: true);
  });

  /// One receipt, written as PNG and as the raw printer byte stream.
  Future<void> write(
    WidgetTester tester,
    String name,
    ReceiptDoc doc, {
    int width = 576,
  }) async {
    final bmp = (await tester.runAsync(
      () => renderReceipt(doc, width: width),
    ))!;
    final printer = FakePrinter(directory: out);
    final result = (await tester.runAsync(
      () => printer.printBitmap(
        bmp,
        config: PrinterConfig(widthPx: width),
        jobName: name,
      ),
    ))!;
    expect(result.ok, isTrue, reason: result.error);
    expect(bmp.blackPixels, greaterThan(0), reason: '$name rendered blank');
  }

  ReceiptDoc doc({
    required TaxMode mode,
    OrderType orderType = OrderType.dine,
    bool duplicate = false,
    bool cancelled = false,
    bool mixedRates = false,
    bool longName = false,
    String? upi,
  }) {
    final itemName = longName
        ? 'Special Hyderabadi Gongura Mutton Dum Biryani Family Pack With '
            'Extra Raita And Mirchi Ka Salan'
        : 'Chicken Dum Biryani';

    final cart = [
      CartLine(
        itemId: 'a',
        nameSnapshot: itemName,
        nameTeSnapshot: 'చికెన్ దమ్ బిర్యానీ',
        unitPrice: Paise.fromRupees(240),
        qty: 2,
        taxClass: TaxClass.gst5,
      ),
      CartLine(
        itemId: 'b',
        nameSnapshot: 'Buttermilk',
        nameTeSnapshot: 'మజ్జిగ',
        unitPrice: Paise.fromRupees(30),
        qty: 3,
        taxClass: TaxClass.gst5,
      ),
      if (mixedRates)
        CartLine(
          itemId: 'c',
          nameSnapshot: 'Bottled soft drink',
          nameTeSnapshot: 'శీతల పానీయం',
          unitPrice: Paise.fromRupees(100),
          qty: 1,
          taxClass: TaxClass.gst18,
        ),
    ];

    final bill = computeBill(
      cart: cart,
      config: TaxConfig(mode: mode, pricesIncludeTax: false),
      orderType: orderType,
    );

    return buildReceipt(
      outlet: ReceiptOutlet(
        name: 'Annapurna Mess',
        address: 'Main Road, Vijayawada, Andhra Pradesh 520001',
        phone: '9000000000',
        fssaiNo: '12345678901234',
        taxMode: mode,
        gstin: mode == TaxMode.regular5 || mode == TaxMode.regular18
            ? '37ABCDE1234F1Z5'
            : null,
        billFooter: 'Thank you, come again',
        upiVpa: upi,
      ),
      bill: bill,
      invoiceNo: InvoiceNo.build(
        devicePrefix: 'A',
        fy: const FinancialYear(2026),
        seq: 123,
      ),
      at: DateTime(2026, 11, 2, 14, 35),
      businessDate: const BusinessDate(2026, 11, 2),
      lines: [
        for (final c in cart)
          ReceiptLine(
            name: c.nameSnapshot,
            nameTe: c.nameTeSnapshot,
            qty: c.qty,
            unitPrice: c.unitPrice,
            lineTotal: c.gross,
          ),
      ],
      payments: [(mode: PaymentMode.cash, amount: bill.total)],
      cashierName: 'Ravi',
      duplicate: duplicate,
      cancelled: cancelled,
      cancelReason: cancelled ? 'Wrong item entered' : null,
    );
  }

  testWidgets('writes one receipt per interesting case', (tester) async {
    await write(tester, '01-regular-5pct', doc(mode: TaxMode.regular5));
    await write(tester, '02-composition', doc(mode: TaxMode.composition));
    await write(tester, '03-unregistered', doc(mode: TaxMode.unregistered));
    await write(
      tester,
      '04-mixed-rates',
      doc(mode: TaxMode.regular5, mixedRates: true),
    );
    await write(
      tester,
      '05-aggregator',
      doc(mode: TaxMode.regular5, orderType: OrderType.aggregator),
    );
    await write(
      tester,
      '06-duplicate',
      doc(mode: TaxMode.regular5, duplicate: true),
    );
    await write(
      tester,
      '07-cancelled',
      doc(mode: TaxMode.regular5, cancelled: true),
    );
    await write(
      tester,
      '08-long-item-name',
      doc(mode: TaxMode.regular5, longName: true),
    );
    await write(
      tester,
      '09-with-upi-qr',
      doc(mode: TaxMode.regular5, upi: 'annapurna@okaxis'),
    );
    // A 58 mm printer, to show the layout is not hard-coded to 80 mm.
    await write(
      tester,
      '10-58mm-narrow',
      doc(mode: TaxMode.regular5),
      width: 384,
    );

    final pngs = out
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.png'))
        .toList();
    expect(pngs, hasLength(10));
  });
}
