/// The receipt document: the legal requirements, as data.
///
/// These run without a rendering engine, which is the point of separating the
/// document from the bitmap: the rules that matter are testable in
/// milliseconds.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/invoice_no.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/receipt.dart';
import 'package:restaurant_pos/core/tax.dart';

ReceiptOutlet outlet({
  TaxMode mode = TaxMode.regular5,
  String? gstin = '37ABCDE1234F1Z5',
  String footer = '',
  String? upi,
}) =>
    ReceiptOutlet(
      name: 'Annapurna Mess',
      address: 'Main Road, Vijayawada',
      phone: '9000000000',
      fssaiNo: '12345678901234',
      taxMode: mode,
      gstin: mode == TaxMode.regular5 || mode == TaxMode.regular18
          ? gstin
          : null,
      billFooter: footer,
      upiVpa: upi,
    );

ComputedBill priced({
  TaxMode mode = TaxMode.regular5,
  OrderType orderType = OrderType.dine,
  bool mixedRates = false,
  int qty = 1,
}) =>
    computeBill(
      cart: [
        CartLine(
          itemId: 'a',
          nameSnapshot: 'Chicken Dum Biryani',
          nameTeSnapshot: 'చికెన్ దమ్ బిర్యానీ',
          unitPrice: Paise.fromRupees(240),
          qty: qty,
          taxClass: TaxClass.gst5,
        ),
        if (mixedRates)
          CartLine(
            itemId: 'b',
            nameSnapshot: 'Bottled soft drink',
            unitPrice: Paise.fromRupees(100),
            qty: 1,
            taxClass: TaxClass.gst18,
          ),
      ],
      config: TaxConfig(mode: mode, pricesIncludeTax: false),
      orderType: orderType,
    );

ReceiptDoc build({
  TaxMode mode = TaxMode.regular5,
  OrderType orderType = OrderType.dine,
  bool duplicate = false,
  bool cancelled = false,
  String? cancelReason,
  bool showTelugu = true,
  bool mixedRates = false,
  String footer = '',
  String? upi,
  List<({PaymentMode mode, Paise amount})>? payments,
}) {
  final bill = priced(mode: mode, orderType: orderType, mixedRates: mixedRates);
  return buildReceipt(
    outlet: outlet(mode: mode, footer: footer, upi: upi),
    bill: bill,
    invoiceNo: InvoiceNo.build(
      devicePrefix: 'A',
      fy: const FinancialYear(2026),
      seq: 123,
    ),
    at: DateTime(2026, 11, 2, 14, 35),
    businessDate: const BusinessDate(2026, 11, 2),
    lines: [
      const ReceiptLine(
        name: 'Chicken Dum Biryani',
        nameTe: 'చికెన్ దమ్ బిర్యానీ',
        qty: 1,
        unitPrice: Paise(24000),
        lineTotal: Paise(24000),
      ),
      if (mixedRates)
        const ReceiptLine(
          name: 'Bottled soft drink',
          qty: 1,
          unitPrice: Paise(10000),
          lineTotal: Paise(10000),
        ),
    ],
    payments: payments ??
        [(mode: PaymentMode.cash, amount: bill.total)],
    cashierName: 'Ravi',
    duplicate: duplicate,
    cancelled: cancelled,
    cancelReason: cancelReason,
    showTelugu: showTelugu,
  );
}

/// All the text on a receipt, flattened, for asserting on content.
List<String> textOf(ReceiptDoc doc) => [
      for (final b in doc.blocks)
        ...switch (b) {
          TextLine(:final text) => [text],
          TwoColumn(:final left, :final right) => [left, right],
          ItemRowBlock(:final name, :final nameTe, :final amount) => [
              name,
              ?nameTe,
              amount,
            ],
          QrBlock(:final data, :final caption) => [
              data,
              ?caption,
            ],
          DividerBlock() || SpacerBlock() => <String>[],
        },
    ];

bool has(ReceiptDoc doc, String needle) =>
    textOf(doc).any((t) => t.contains(needle));

void main() {
  group('the FSSAI number appears in every tax mode', () {
    for (final mode in TaxMode.values) {
      test('$mode', () {
        expect(
          has(build(mode: mode), 'FSSAI: 12345678901234'),
          isTrue,
          reason: 'the brief requires it on every bill, in every mode',
        );
      });
    }

    test('and on an aggregator order', () {
      expect(
        has(build(orderType: OrderType.aggregator), 'FSSAI: 12345678901234'),
        isTrue,
      );
    });

    test('and on a reprint', () {
      expect(has(build(duplicate: true), 'FSSAI: 12345678901234'), isTrue);
    });

    test('and on a cancelled bill', () {
      expect(has(build(cancelled: true), 'FSSAI: 12345678901234'), isTrue);
    });
  });

  group('the document heading', () {
    test('regular GST prints TAX INVOICE', () {
      expect(has(build(mode: TaxMode.regular5), 'TAX INVOICE'), isTrue);
      expect(has(build(mode: TaxMode.regular18), 'TAX INVOICE'), isTrue);
    });

    test('composition prints BILL OF SUPPLY', () {
      final doc = build(mode: TaxMode.composition);
      expect(has(doc, 'BILL OF SUPPLY'), isTrue);
      expect(has(doc, 'TAX INVOICE'), isFalse);
    });

    test('unregistered prints BILL OF SUPPLY', () {
      final doc = build(mode: TaxMode.unregistered);
      expect(has(doc, 'BILL OF SUPPLY'), isTrue);
      expect(has(doc, 'TAX INVOICE'), isFalse);
    });

    test('an aggregator order prints BILL OF SUPPLY even on a tax invoice '
        'outlet', () {
      final doc = build(orderType: OrderType.aggregator);
      expect(has(doc, 'BILL OF SUPPLY'), isTrue);
      expect(has(doc, 'Aggregator order'), isTrue);
    });
  });

  group('the composition declaration', () {
    test('is printed under composition', () {
      expect(
        has(build(mode: TaxMode.composition), kCompositionDeclaration),
        isTrue,
        reason: 'rule 5(1)(f) requires it on every bill of supply',
      );
    });

    test('is not printed in any other mode', () {
      for (final mode in [
        TaxMode.unregistered,
        TaxMode.regular5,
        TaxMode.regular18,
      ]) {
        expect(
          has(build(mode: mode), kCompositionDeclaration),
          isFalse,
          reason: '$mode',
        );
      }
    });
  });

  group('tax lines', () {
    test('a regular bill shows CGST and SGST at half the rate each', () {
      final doc = build(mode: TaxMode.regular5);
      expect(has(doc, 'CGST 2.5%'), isTrue);
      expect(has(doc, 'SGST 2.5%'), isTrue);
    });

    test('an 18% ITEM shows 9% each side, whatever the outlet mode', () {
      // The rate comes from the item, not the outlet: that is the answer to
      // Q3. A gst5 item on a regular_18 outlet is still taxed at 5%.
      final doc = build(mixedRates: true);
      expect(has(doc, 'CGST 9%'), isTrue, reason: 'the gst18 line');
      expect(has(doc, 'CGST 2.5%'), isTrue, reason: 'the gst5 line');
    });

    test('a gst5 item on a regular_18 outlet is still taxed at 5%', () {
      final doc = build(mode: TaxMode.regular18);
      expect(has(doc, 'CGST 2.5%'), isTrue);
      expect(has(doc, 'CGST 9%'), isFalse,
          reason: 'the outlet mode sets defaults, the item sets the rate');
    });

    test('a mixed-rate bill shows one block per rate', () {
      final doc = build(mixedRates: true);
      expect(has(doc, 'CGST 2.5%'), isTrue);
      expect(has(doc, 'CGST 9%'), isTrue);
      expect(has(doc, 'Taxable @ 5%'), isTrue);
      expect(has(doc, 'Taxable @ 18%'), isTrue);
    });

    test('composition and unregistered show no tax lines at all', () {
      for (final mode in [TaxMode.composition, TaxMode.unregistered]) {
        final doc = build(mode: mode);
        expect(has(doc, 'CGST'), isFalse, reason: '$mode');
        expect(has(doc, 'SGST'), isFalse, reason: '$mode');
      }
    });

    test('an aggregator order shows no tax and says who pays it', () {
      final doc = build(orderType: OrderType.aggregator);
      expect(has(doc, 'CGST'), isFalse);
      expect(has(doc, 'paid by the aggregator'), isTrue);
    });
  });

  group('SAC', () {
    test('is printed on a tax invoice', () {
      expect(has(build(mode: TaxMode.regular5), '9963'), isTrue);
    });

    test('is not printed where no tax is charged', () {
      expect(has(build(mode: TaxMode.composition), '9963'), isFalse);
      expect(has(build(mode: TaxMode.unregistered), '9963'), isFalse);
    });

    test('is configurable', () {
      final bill = priced();
      final doc = buildReceipt(
        outlet: const ReceiptOutlet(
          name: 'X',
          address: 'Y',
          phone: '1',
          fssaiNo: '12345678901234',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
          sacCode: '996331',
        ),
        bill: bill,
        invoiceNo: InvoiceNo.build(
          devicePrefix: 'A',
          fy: const FinancialYear(2026),
          seq: 1,
        ),
        at: DateTime(2026, 11, 2, 14, 35),
        businessDate: const BusinessDate(2026, 11, 2),
        lines: const [],
        payments: const [],
        cashierName: 'Ravi',
      );
      expect(has(doc, '996331'), isTrue);
    });
  });

  group('reprints and cancellations', () {
    test('a reprint is marked DUPLICATE', () {
      expect(has(build(duplicate: true), 'DUPLICATE'), isTrue);
    });

    test('an original is not', () {
      expect(has(build(), 'DUPLICATE'), isFalse);
    });

    test('DUPLICATE is the first thing on the paper', () {
      final doc = build(duplicate: true);
      final first = doc.blocks.first;
      expect(first, isA<TextLine>());
      expect((first as TextLine).text, 'DUPLICATE');
      expect(first.scale, TextScale.large,
          reason: 'it must not be missable');
    });

    test('a cancelled bill says so, with the reason', () {
      final doc = build(cancelled: true, cancelReason: 'Wrong item entered');
      expect(has(doc, 'CANCELLED'), isTrue);
      expect(has(doc, 'Wrong item entered'), isTrue);
    });

    test('a cancelled bill keeps its number and total', () {
      final doc = build(cancelled: true, cancelReason: 'Test bill');
      expect(has(doc, 'A/2627/000123'), isTrue);
      expect(has(doc, '252.00'), isTrue);
    });
  });

  group('Telugu', () {
    test('the item name appears in both scripts when asked', () {
      final doc = build(showTelugu: true);
      expect(has(doc, 'Chicken Dum Biryani'), isTrue);
      expect(has(doc, 'చికెన్ దమ్ బిర్యానీ'), isTrue);
    });

    test('and only English when not', () {
      final doc = build(showTelugu: false);
      expect(has(doc, 'Chicken Dum Biryani'), isTrue);
      expect(has(doc, 'చికెన్ దమ్ బిర్యానీ'), isFalse);
    });

    test('labels stay in English, so an accountant can read the bill', () {
      final doc = build(showTelugu: true);
      expect(has(doc, 'TOTAL'), isTrue);
      expect(has(doc, 'Subtotal'), isTrue);
    });
  });

  group('the essentials every bill carries', () {
    test('shop, invoice number, date, cashier and total', () {
      final doc = build();
      expect(has(doc, 'Annapurna Mess'), isTrue);
      expect(has(doc, 'Main Road, Vijayawada'), isTrue);
      expect(has(doc, '9000000000'), isTrue);
      expect(has(doc, 'A/2627/000123'), isTrue);
      expect(has(doc, '02/11/2026 14:35'), isTrue);
      expect(has(doc, 'Ravi'), isTrue);
      expect(has(doc, 'TOTAL'), isTrue);
      expect(has(doc, '252.00'), isTrue);
    });

    test('the business date, which is what reports group by', () {
      expect(has(build(), '2026-11-02'), isTrue);
    });

    test('GSTIN appears when registered, and not otherwise', () {
      expect(has(build(mode: TaxMode.regular5), 'GSTIN'), isTrue);
      expect(has(build(mode: TaxMode.unregistered), 'GSTIN'), isFalse);
    });

    test('payments are listed, split included', () {
      final doc = build(payments: [
        (mode: PaymentMode.cash, amount: Paise.fromRupees(200)),
        (mode: PaymentMode.upi, amount: const Paise(5200)),
      ]);
      expect(has(doc, 'Cash'), isTrue);
      expect(has(doc, 'UPI'), isTrue);
      expect(has(doc, '200.00'), isTrue);
    });

    test('a custom footer is printed', () {
      expect(has(build(footer: 'Thank you, come again'),
          'Thank you, come again'), isTrue);
    });
  });

  group('the UPI QR', () {
    test('is included when a VPA is configured', () {
      final doc = build(upi: 'annapurna@okaxis');
      final qr = doc.blocks.whereType<QrBlock>().toList();
      expect(qr, hasLength(1));
      expect(qr.single.data, startsWith('upi://pay?'));
      expect(qr.single.data, contains('pa=annapurna%40okaxis'));
      expect(qr.single.data, contains('am=252.00'));
      expect(qr.single.data, contains('cu=INR'));
    });

    test('is omitted when no VPA is set', () {
      expect(build().blocks.whereType<QrBlock>(), isEmpty);
    });

    test('is omitted on a cancelled bill, which must not invite payment', () {
      final doc = build(upi: 'annapurna@okaxis', cancelled: true);
      expect(doc.blocks.whereType<QrBlock>(), isEmpty);
    });

    test('the amount is in rupees, as UPI apps expect', () {
      final doc = build(upi: 'x@y');
      final data = doc.blocks.whereType<QrBlock>().single.data;
      expect(data, contains('am=252.00'));
      expect(data, isNot(contains('am=25200')));
    });
  });

  group('round off', () {
    test('appears only when there is one', () {
      // 240 at 5% is exactly 252.00, so no rounding.
      expect(has(build(), 'Round off'), isFalse);
    });

    test('is shown with its sign when there is', () {
      final bill = computeBill(
        cart: [
          CartLine(
            itemId: 'a',
            nameSnapshot: 'Pesarattu',
            unitPrice: Paise.fromRupees(70),
            qty: 1,
            taxClass: TaxClass.gst5,
          ),
        ],
        config: const TaxConfig(
          mode: TaxMode.regular5,
          pricesIncludeTax: false,
        ),
        orderType: OrderType.dine,
      );
      final doc = buildReceipt(
        outlet: outlet(),
        bill: bill,
        invoiceNo: InvoiceNo.build(
          devicePrefix: 'A',
          fy: const FinancialYear(2026),
          seq: 1,
        ),
        at: DateTime(2026, 11, 2, 14, 35),
        businessDate: const BusinessDate(2026, 11, 2),
        lines: const [],
        payments: const [],
        cashierName: 'Ravi',
      );
      // 73.50 rounds to 74.00, so +0.50.
      expect(has(doc, 'Round off'), isTrue);
      expect(has(doc, '+0.50'), isTrue);
      expect(has(doc, '74.00'), isTrue);
    });
  });
}
