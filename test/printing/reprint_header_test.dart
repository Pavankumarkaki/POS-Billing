/// What a reprint puts in the header.
///
/// The bill's own figures come from the bill: amounts, tax splits, document
/// type, invoice number. The header around them, the outlet's name and
/// licence numbers, did not: it was rebuilt from today's outlet row.
///
/// That was harmless while those fields could only be set during first-run
/// setup. Settings can now change them, so it is reachable, and the GSTIN case
/// produces a document that is not valid: a tax invoice with no GSTIN on it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/receipt.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/outlet_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/printing/fake_printer.dart';
import 'package:restaurant_pos/printing/print_service.dart';

import 'dart:io';

void main() {
  late PosDatabase db;
  late PrintService printing;
  late OutletRepository outlets;
  late String ownerId;
  late String deviceId;
  late String itemId;

  setUp(() async {
    db = PosDatabase.memory();
    final setup = SetupRepository(db);
    final r = await setup.completeSetup(
      const SetupDetails(
        outletName: 'Annapurna Mess',
        address: 'Main Road',
        phone: '9000000000',
        fssaiNo: '12345678901234',
        taxMode: TaxMode.regular5,
        gstin: '37ABCDE1234F1Z5',
        ownerName: 'Ravi',
        ownerPin: '1357',
        devicePrefix: 'A',
      ),
      at: DateTime(2026, 4, 1, 10),
    );
    ownerId = r.ownerId;
    deviceId = r.deviceId;

    final menu = MenuRepository(db, deviceId: deviceId);
    final cat = await menu.createCategory(nameEn: 'Biryani', byUserId: ownerId);
    itemId = await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );

    printing = PrintService(
      db,
      printer: FakePrinter(directory: Directory.systemTemp),
    );
    outlets = OutletRepository(db);
  });

  tearDown(() => db.close());

  Future<SavedBill> sell() async {
    final outlet = await db.select(db.outlets).getSingle();
    final computed = computeBill(
      cart: [
        CartLine(
          itemId: itemId,
          nameSnapshot: 'Chicken Dum Biryani',
          unitPrice: Paise.fromRupees(240),
          qty: 1,
          taxClass: TaxClass.gst5,
        ),
      ],
      config: TaxConfig(
        mode: outlet.taxMode,
        pricesIncludeTax: outlet.pricesIncludeTax,
      ),
      orderType: OrderType.dine,
    );
    return BillRepository(db).commitSale(
      computed: computed,
      payments: [PaymentIntent(PaymentMode.cash, computed.total)],
      deviceId: deviceId,
      userId: ownerId,
    );
  }

  /// Every line of text on the receipt, flattened.
  List<String> textOf(ReceiptDoc doc) => [
        for (final b in doc.blocks)
          if (b is TextLine)
            b.text
          else if (b is TwoColumn)
            '${b.left} ${b.right}'
          else if (b is ItemRowBlock)
            b.name,
      ];

  group('a reprint reproduces the document that was issued', () {
    test('it keeps the GSTIN after the outlet goes unregistered', () async {
      // The case that makes this more than tidiness. The bill is a tax
      // invoice and still says so, so a tax invoice with no GSTIN on it is
      // not a valid document.
      final bill = await sell();

      await outlets.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.unregistered,
        ),
        byUserId: ownerId,
      );

      final doc = await printing.buildDocFor(bill.id, duplicate: true);
      final text = textOf(doc!).join(' | ');

      expect(text, contains('TAX INVOICE'),
          reason: 'the bill itself has not changed');
      expect(
        text,
        contains('37ABCDE1234F1Z5'),
        reason: 'the GSTIN it was issued under',
      );
    });

    test('it keeps the FSSAI number the bill was issued under', () async {
      final bill = await sell();

      await outlets.updateBillDetails(
        const BillDetails(
          fssaiNo: '99999999999999',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      final doc = await printing.buildDocFor(bill.id, duplicate: true);
      final text = textOf(doc!).join(' | ');

      expect(text, contains('12345678901234'));
      expect(text, isNot(contains('99999999999999')));
    });

    test('a bill rung up after the change uses the new details', () async {
      await outlets.updateBillDetails(
        const BillDetails(
          fssaiNo: '99999999999999',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      final bill = await sell();
      final doc = await printing.buildDocFor(bill.id, duplicate: true);
      final text = textOf(doc!).join(' | ');

      expect(text, contains('99999999999999'));
      expect(text, isNot(contains('12345678901234')));
    });
  });
}
