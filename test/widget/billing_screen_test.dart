/// The billing screen and a complete sale, driven through the UI.
library;

import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/features/billing/billing_screen.dart';
import 'package:restaurant_pos/printing/fake_printer.dart';
import 'package:restaurant_pos/printing/print_service.dart';
import 'package:restaurant_pos/printing/printer.dart';
import 'package:restaurant_pos/providers.dart';

import 'harness.dart';


/// A print service that reports a result without rendering anything.
///
/// Rendering calls `Picture.toImage`, which does real engine work that a
/// widget test's fake clock never pumps: the future simply never completes and
/// the screen sits on its spinner. The rendering itself is covered by
/// test/printing; what these tests need is the UI contract around it — the
/// bill is saved first, a failure offers a retry, and nothing blocks the next
/// sale.
class _StubPrintService extends PrintService {
  _StubPrintService(super.db, {required super.printer});

  bool shouldFail = false;
  int calls = 0;

  @override
  Future<PrintResult> printBill(String billId, {bool duplicate = false}) async {
    calls++;
    if (shouldFail) {
      shouldFail = false;
      return const PrintResult.failure('The printer did not respond.');
    }
    return const PrintResult.success(artefactPath: '/stub/receipt.png');
  }
}

void main() {
  late PosDatabase db;
  late String ownerId;

  Future<void> seed({TaxMode mode = TaxMode.regular5}) async {
    db = PosDatabase.memory();
    final setup = SetupRepository(db);
    final r = await setup.completeSetup(SetupDetails(
      outletName: 'Annapurna Mess',
      address: 'Main Road',
      phone: '9000000000',
      fssaiNo: '12345678901234',
      taxMode: mode,
      gstin: mode == TaxMode.regular5 ? '37ABCDE1234F1Z5' : null,
      ownerName: 'Ravi',
      ownerPin: '1357',
      devicePrefix: 'A',
    ));
    ownerId = r.ownerId;

    final menu = MenuRepository(db, deviceId: r.deviceId);
    final cat =
        await menu.createCategory(nameEn: 'Biryani', byUserId: ownerId);
    await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      nameTe: 'చికెన్ దమ్ బిర్యానీ',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );
    await menu.createItem(
      categoryId: cat,
      nameEn: 'Buttermilk',
      price: Paise.fromRupees(30),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );
  }

  setUp(() => seed());
  tearDown(() => db.close());


  /// Taps an item's tile in the GRID.
  ///
  /// Once an item is on the bill its name appears twice, in the grid tile and
  /// in the cart row, so a bare text finder is ambiguous.
  Future<void> tapItem(WidgetTester tester, String name) async {
    final tile = find.descendant(
      of: find.byType(GridView),
      matching: find.text(name),
    );
    expect(tile, findsOneWidget, reason: 'no single grid tile for "$name"');
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }


  /// Confirms the sale. The stub print service completes immediately, so the
  /// screen settles.
  Future<void> confirmSale(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('confirm-sale')));
    await tester.pumpAndSettle();
  }

  late _StubPrintService stubPrinting;

  Future<void> show(WidgetTester tester, {Size? size}) async {
    await pumpScreen(
      tester,
      db: db,
      size: size ?? const Size(1280, 800),
      child: const BillingScreen(),
      printService: (database) {
        stubPrinting = _StubPrintService(
          database,
          printer: FakePrinter(directory: Directory.systemTemp),
        );
        return stubPrinting;
      },
      before: (c) => c.read(sessionProvider.notifier).signIn(Session(
            userId: ownerId,
            name: 'Ravi',
            role: UserRole.owner,
            startedAt: DateTime(2026, 6, 1),
          )),
    );
    await tester.pumpAndSettle();
  }

  group('the grid', () {
    testWidgets('shows sellable items with prices', (tester) async {
      await show(tester);
      expect(find.text('Chicken Dum Biryani'), findsOneWidget);
      expect(find.text('Buttermilk'), findsOneWidget);
      expect(find.text('₹240'), findsOneWidget);
    });

    testWidgets('renders on a phone without overflow', (tester) async {
      await show(tester, size: const Size(390, 844));
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders on a narrow phone without overflow', (tester) async {
      await show(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('search filters by English name', (tester) async {
      await show(tester);
      await tester.enterText(find.byKey(const Key('item-search')), 'butter');
      await tester.pumpAndSettle();
      expect(find.text('Buttermilk'), findsOneWidget);
      expect(find.text('Chicken Dum Biryani'), findsNothing);
    });

    testWidgets('search finds the Telugu name too', (tester) async {
      await show(tester);
      await tester.enterText(
        find.byKey(const Key('item-search')),
        'బిర్యానీ',
      );
      await tester.pumpAndSettle();
      expect(find.text('Chicken Dum Biryani'), findsOneWidget);
      expect(find.text('Buttermilk'), findsNothing);
    });

    testWidgets('a disabled item is not sellable', (tester) async {
      final items = await db.select(db.items).get();
      final menu = MenuRepository(
        db,
        deviceId: (await db.select(db.devices).getSingle()).id,
      );
      await menu.setItemActive(
        id: items.first.id,
        isActive: false,
        byUserId: ownerId,
      );

      await show(tester);
      expect(find.text('Chicken Dum Biryani'), findsNothing);
      expect(find.text('Buttermilk'), findsOneWidget);
    });
  });

  group('building a bill', () {
    testWidgets('tapping an item puts it on the bill', (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');

      expect(find.text('1 item'), findsOneWidget);
      expect(find.text('Total'), findsOneWidget);
    });

    testWidgets('tapping twice makes one line of two, not two lines',
        (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');
      await tapItem(tester, 'Chicken Dum Biryani');

      expect(find.text('2 items'), findsOneWidget);
      expect(find.text('2 × ₹240'), findsOneWidget);
    });

    testWidgets('the total matches the tax engine', (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');

      // 240 + 2.5% + 2.5% = 252
      expect(find.text('₹252'), findsWidgets);
      expect(find.text('CGST 2.5%'), findsOneWidget);
      expect(find.text('SGST 2.5%'), findsOneWidget);
    });

    testWidgets('an unregistered outlet shows no tax lines', (tester) async {
      await db.close();
      await seed(mode: TaxMode.unregistered);
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');

      expect(find.textContaining('CGST'), findsNothing);
      expect(find.text('₹240'), findsWidgets);
    });

    testWidgets('clearing empties the bill', (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();

      expect(find.textContaining('No items yet'), findsOneWidget);
    });

    testWidgets('order type can be switched', (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');

      await tester.tap(find.text('Online'));
      await tester.pumpAndSettle();

      // Aggregator orders carry no tax, even on a registered outlet.
      expect(find.textContaining('CGST'), findsNothing);
    });
  });

  group('a complete sale', () {
    testWidgets('saves a bill with a number, lines and a payment',
        (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');
      await tester.tap(find.byKey(const Key('charge')));
      await tester.pumpAndSettle();

      expect(find.text('Collect payment'), findsOneWidget);

      await tester.tap(find.byKey(const Key('pay-full')));
      await tester.pumpAndSettle();
      await confirmSale(tester);

      expect(find.text('Bill saved'), findsOneWidget);
      expect(find.text('A/2627/000001'), findsOneWidget);

      final bill = await db.select(db.bills).getSingle();
      expect(bill.invoiceNo, 'A/2627/000001');
      expect(bill.total.value, 25200);
      expect(bill.status, BillStatus.paid);

      expect(await db.select(db.billLines).get(), hasLength(1));
      expect(await db.select(db.payments).get(), hasLength(1));
      expect(await db.select(db.auditLog).get(), isNotEmpty);
      expect(await db.select(db.outbox).get(), isNotEmpty);
    });

    testWidgets('the cart is empty afterwards, ready for the next customer',
        (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');
      await tester.tap(find.byKey(const Key('charge')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pay-full')));
      await tester.pumpAndSettle();
      await confirmSale(tester);
      await tester.tap(find.byKey(const Key('next-bill')));
      await tester.pumpAndSettle();

      expect(find.textContaining('No items yet'), findsOneWidget);
    });

    testWidgets('two sales take consecutive numbers', (tester) async {
      Future<void> sell() async {
        await tapItem(tester, 'Buttermilk');
        await tester.tap(find.byKey(const Key('charge')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('pay-full')));
        await tester.pumpAndSettle();
        await confirmSale(tester);
        await tester.tap(find.byKey(const Key('next-bill')));
        await tester.pumpAndSettle();
      }

      await show(tester);
      await sell();
      await sell();

      final bills = await (db.select(db.bills)
            ..orderBy([(b) => OrderingTerm.asc(b.deviceSeq)]))
          .get();
      expect(bills.map((b) => b.invoiceNo),
          ['A/2627/000001', 'A/2627/000002']);
    });
  });

  group('split payments', () {
    testWidgets('Charge stays disabled until the tenders balance',
        (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');
      await tester.tap(find.byKey(const Key('charge')));
      await tester.pumpAndSettle();

      // Nothing tendered yet.
      final before = tester.widget<FilledButton>(
        find.byKey(const Key('confirm-sale')),
      );
      expect(before.onPressed, isNull,
          reason: 'commitSale refuses an unbalanced bill anyway');

      // Part of it.
      await tester.enterText(find.byKey(const Key('part-amount')), '100');
      await tester.tap(find.byKey(const Key('add-part')));
      await tester.pumpAndSettle();

      final mid = tester.widget<FilledButton>(
        find.byKey(const Key('confirm-sale')),
      );
      expect(mid.onPressed, isNull);
      expect(find.text('Still due'), findsOneWidget);

      // The rest.
      await tester.tap(find.byKey(const Key('pay-full')));
      await tester.pumpAndSettle();

      final after = tester.widget<FilledButton>(
        find.byKey(const Key('confirm-sale')),
      );
      expect(after.onPressed, isNotNull);
    });

    testWidgets('a split writes one payment row per tender', (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');
      await tester.tap(find.byKey(const Key('charge')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('part-amount')), '200');
      await tester.tap(find.byKey(const Key('add-part')));
      await tester.pumpAndSettle();

      await tester.tap(find.text('UPI'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pay-full')));
      await tester.pumpAndSettle();
      await confirmSale(tester);

      final payments = await db.select(db.payments).get();
      expect(payments, hasLength(2));
      expect(
        payments.fold(Paise.zero, (Paise s, p) => s + p.amount).value,
        25200,
      );
      expect(payments.map((p) => p.mode).toSet(),
          {PaymentMode.cash, PaymentMode.upi});
    });

    testWidgets('a tender larger than what is due is capped, not recorded',
        (tester) async {
      await show(tester);
      await tapItem(tester, 'Buttermilk');
      await tester.tap(find.byKey(const Key('charge')));
      await tester.pumpAndSettle();

      // Buttermilk is ₹30 + tax = ₹32. Hand over ₹500.
      await tester.enterText(find.byKey(const Key('part-amount')), '500');
      await tester.tap(find.byKey(const Key('add-part')));
      await tester.pumpAndSettle();
      await confirmSale(tester);

      final payment = await db.select(db.payments).getSingle();
      final bill = await db.select(db.bills).getSingle();
      expect(
        payment.amount.value,
        bill.total.value,
        reason: 'the excess is change, not a payment',
      );
    });

    testWidgets('undo removes the last tender', (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');
      await tester.tap(find.byKey(const Key('charge')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('part-amount')), '100');
      await tester.tap(find.byKey(const Key('add-part')));
      await tester.pumpAndSettle();
      expect(find.text('Received'), findsOneWidget);

      await tester.tap(find.text('Undo last'));
      await tester.pumpAndSettle();
      expect(find.text('Received'), findsNothing);
    });
  });

  group('printing after the sale', () {
    testWidgets('a saved bill prints, and says so', (tester) async {
      await show(tester);
      await tapItem(tester, 'Chicken Dum Biryani');
      await tester.tap(find.byKey(const Key('charge')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pay-full')));
      await tester.pumpAndSettle();
      await confirmSale(tester);

      expect(find.text('Bill saved'), findsOneWidget);
      expect(find.text('Receipt printed'), findsOneWidget);
      expect(find.byKey(const Key('print-failed')), findsNothing);
    });

    testWidgets('a printer failure keeps the bill and offers a retry',
        (tester) async {
      await show(tester);
      stubPrinting.shouldFail = true;

      await tapItem(tester, 'Chicken Dum Biryani');
      await tester.tap(find.byKey(const Key('charge')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pay-full')));
      await tester.pumpAndSettle();
      await confirmSale(tester);

      // The bill is saved regardless.
      final bill = await db.select(db.bills).getSingle();
      expect(bill.invoiceNo, 'A/2627/000001');
      expect(bill.status, BillStatus.paid);

      // And the failure is shown, with a way out.
      expect(find.text('Bill saved'), findsOneWidget);
      expect(find.byKey(const Key('print-failed')), findsOneWidget);
      expect(find.byKey(const Key('retry-print')), findsOneWidget);

      // Next bill is NOT blocked by the printer problem.
      final next = tester.widget<FilledButton>(
        find.byKey(const Key('next-bill')),
      );
      expect(next.onPressed, isNotNull,
          reason: 'a printer problem must never block the next sale');

      // And the retry works.
      await tester.tap(find.byKey(const Key('retry-print')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('print-failed')), findsNothing);
      expect(find.text('Receipt printed'), findsOneWidget);
    });
  });
}
