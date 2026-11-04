/// The bills screen: finding a bill, reprinting it, and cancelling it.
///
/// The cancellation path is the one that matters most here. It is the only
/// destructive action in the app, and the brief gates it twice: owner role,
/// then the PIN re-entered.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/features/bills/bills_screen.dart';
import 'package:restaurant_pos/printing/fake_printer.dart';
import 'package:restaurant_pos/printing/print_service.dart';
import 'package:restaurant_pos/printing/printer.dart';
import 'package:restaurant_pos/providers.dart';

import 'harness.dart';

/// Reports a result without rendering. See the note in billing_screen_test.
class _StubPrintService extends PrintService {
  _StubPrintService(super.db, {required super.printer});

  final List<({String billId, bool duplicate})> jobs = [];

  @override
  Future<PrintResult> printBill(String billId, {bool duplicate = false}) async {
    jobs.add((billId: billId, duplicate: duplicate));
    return const PrintResult.success();
  }
}

void main() {
  late PosDatabase db;
  late String ownerId;
  late String staffId;
  late String deviceId;
  late SavedBill bill;
  late _StubPrintService stubPrinting;

  const ownerPin = '1357';

  setUp(() async {
    db = PosDatabase.memory();
    final setup = SetupRepository(db);
    final r = await setup.completeSetup(const SetupDetails(
      outletName: 'Annapurna Mess',
      address: 'Main Road',
      phone: '9000000000',
      fssaiNo: '12345678901234',
      taxMode: TaxMode.regular5,
      gstin: '37ABCDE1234F1Z5',
      ownerName: 'Ravi',
      ownerPin: ownerPin,
      devicePrefix: 'A',
    ));
    ownerId = r.ownerId;
    deviceId = r.deviceId;
    staffId = await setup.addUser(
      name: 'Kiran',
      role: UserRole.staff,
      pin: '2468',
      byUserId: ownerId,
    );

    final menu = MenuRepository(db, deviceId: deviceId);
    final cat =
        await menu.createCategory(nameEn: 'Biryani', byUserId: ownerId);
    final itemId = await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      nameTe: 'చికెన్ దమ్ బిర్యానీ',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );

    final computed = computeBill(
      cart: [
        CartLine(
          itemId: itemId,
          nameSnapshot: 'Chicken Dum Biryani',
          nameTeSnapshot: 'చికెన్ దమ్ బిర్యానీ',
          unitPrice: Paise.fromRupees(240),
          qty: 2,
          taxClass: TaxClass.gst5,
        ),
      ],
      config: const TaxConfig(
        mode: TaxMode.regular5,
        pricesIncludeTax: false,
      ),
      orderType: OrderType.dine,
    );
    bill = await BillRepository(db).commitSale(
      computed: computed,
      payments: [PaymentIntent(PaymentMode.cash, computed.total)],
      deviceId: deviceId,
      userId: ownerId,
    );
  });

  tearDown(() => db.close());

  Future<void> show(
    WidgetTester tester, {
    UserRole role = UserRole.owner,
    Size? size,
  }) async {
    await pumpScreen(
      tester,
      db: db,
      size: size ?? const Size(1280, 800),
      child: const BillsScreen(),
      printService: (database) {
        stubPrinting = _StubPrintService(
          database,
          printer: FakePrinter(directory: Directory.systemTemp),
        );
        return stubPrinting;
      },
      before: (c) => c.read(sessionProvider.notifier).signIn(Session(
            userId: role == UserRole.owner ? ownerId : staffId,
            name: role == UserRole.owner ? 'Ravi' : 'Kiran',
            role: role,
            startedAt: DateTime(2026, 6, 1),
          )),
    );
    await tester.pumpAndSettle();
  }

  /// Enters a PIN on the dialog's keypad.
  Future<void> enterPin(WidgetTester tester, String pin) async {
    for (final d in pin.split('')) {
      await tester.tap(find.widgetWithText(OutlinedButton, d).last);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  group('the list', () {
    testWidgets('shows today bills with number and total', (tester) async {
      await show(tester);
      expect(find.text(bill.invoiceNo.formatted), findsWidgets);
      expect(find.text('₹504'), findsWidgets);
    });

    testWidgets('renders on a phone without overflow', (tester) async {
      await show(tester, size: const Size(390, 844));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the summary strip shows the paid count and total',
        (tester) async {
      await show(tester);
      expect(find.text('1 paid'), findsOneWidget);
      expect(find.text('₹504'), findsWidgets);
    });

    testWidgets('an empty day says so', (tester) async {
      await db.delete(db.payments).go();
      await db.delete(db.billLines).go();
      await db.delete(db.bills).go();
      await show(tester);
      expect(find.textContaining('No bills today yet'), findsOneWidget);
    });
  });

  group('the detail', () {
    testWidgets('shows lines in both scripts and the totals', (tester) async {
      await show(tester);
      await tester.tap(find.text(bill.invoiceNo.formatted).first);
      await tester.pumpAndSettle();

      expect(find.text('2 × Chicken Dum Biryani'), findsOneWidget);
      expect(find.text('చికెన్ దమ్ బిర్యానీ'), findsOneWidget);
      expect(find.text('Paid'), findsOneWidget);
    });

    testWidgets('shows the bill history, so the audit is visible',
        (tester) async {
      await show(tester);
      await tester.tap(find.text(bill.invoiceNo.formatted).first);
      await tester.pumpAndSettle();

      expect(find.text('History'), findsOneWidget);
      expect(find.textContaining('Created'), findsOneWidget);
    });
  });

  group('reprint', () {
    testWidgets('prints marked DUPLICATE and records it', (tester) async {
      await show(tester);
      await tester.tap(find.text(bill.invoiceNo.formatted).first);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('reprint')));
      await tester.pumpAndSettle();

      expect(stubPrinting.jobs, hasLength(1));
      expect(
        stubPrinting.jobs.single.duplicate,
        isTrue,
        reason: 'the brief: reprints must print DUPLICATE',
      );

      final logged = await (db.select(db.auditLog)
            ..where((a) =>
                a.action.equals(AuditAction.billReprinted.wireName)))
          .get();
      expect(logged, hasLength(1), reason: 'and must be logged');
    });

    testWidgets('staff may reprint', (tester) async {
      await show(tester, role: UserRole.staff);
      await tester.tap(find.text(bill.invoiceNo.formatted).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reprint')), findsOneWidget);
    });

    testWidgets('the bill is unchanged by a reprint', (tester) async {
      await show(tester);
      await tester.tap(find.text(bill.invoiceNo.formatted).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reprint')));
      await tester.pumpAndSettle();

      final row = await db.select(db.bills).getSingle();
      expect(row.status, BillStatus.paid);
      expect(row.total.value, 50400);
      expect(row.invoiceNo, bill.invoiceNo.formatted);
    });
  });

  group('cancelling is owner only', () {
    testWidgets('staff never see the button', (tester) async {
      await show(tester, role: UserRole.staff);
      await tester.tap(find.text(bill.invoiceNo.formatted).first);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('cancel-bill')),
        findsNothing,
        reason: 'hidden, not shown and refused',
      );
    });

    testWidgets('the owner sees it', (tester) async {
      await show(tester);
      await tester.tap(find.text(bill.invoiceNo.formatted).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cancel-bill')), findsOneWidget);
    });
  });

  group('the cancel dialog', () {
    Future<void> openDialog(WidgetTester tester) async {
      await show(tester);
      await tester.tap(find.text(bill.invoiceNo.formatted).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cancel-bill')));
      await tester.pumpAndSettle();
    }

    testWidgets('a reason is required before continuing', (tester) async {
      await openDialog(tester);

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('cancel-continue')),
      );
      expect(button.onPressed, isNull, reason: 'no reason picked yet');

      await tester.tap(find.text('Wrong item entered'));
      await tester.pumpAndSettle();

      final ready = tester.widget<FilledButton>(
        find.byKey(const Key('cancel-continue')),
      );
      expect(ready.onPressed, isNotNull);
    });

    testWidgets('Keep bill leaves it alone', (tester) async {
      await openDialog(tester);
      await tester.tap(find.byKey(const Key('keep-bill')));
      await tester.pumpAndSettle();

      final row = await db.select(db.bills).getSingle();
      expect(row.status, BillStatus.paid);
    });

    testWidgets('the PIN is required even though the owner is signed in',
        (tester) async {
      await openDialog(tester);
      await tester.tap(find.text('Wrong item entered'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cancel-continue')));
      await tester.pumpAndSettle();

      expect(find.text('Owner PIN to confirm'), findsOneWidget);

      // Nothing has happened yet.
      final row = await db.select(db.bills).getSingle();
      expect(row.status, BillStatus.paid);
    });

    testWidgets('a wrong PIN refuses and keeps the bill', (tester) async {
      await openDialog(tester);
      await tester.tap(find.text('Wrong item entered'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cancel-continue')));
      await tester.pumpAndSettle();

      await enterPin(tester, '9999');

      expect(find.textContaining('not right'), findsOneWidget);
      final row = await db.select(db.bills).getSingle();
      expect(row.status, BillStatus.paid);
    });

    testWidgets('a wrong PIN here counts towards the lockout', (tester) async {
      await openDialog(tester);
      await tester.tap(find.text('Wrong item entered'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cancel-continue')));
      await tester.pumpAndSettle();

      for (var i = 0; i < 5; i++) {
        await enterPin(tester, '9999');
      }

      // Otherwise this dialog would be a free PIN oracle.
      final user = await (db.select(db.users)
            ..where((u) => u.id.equals(ownerId)))
          .getSingle();
      expect(user.failedAttempts, greaterThanOrEqualTo(5));
      expect(user.lockedUntil, isNotNull);
    });

    testWidgets('the right PIN cancels it, keeping the number and amount',
        (tester) async {
      await openDialog(tester);
      await tester.tap(find.text('Wrong item entered'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cancel-continue')));
      await tester.pumpAndSettle();
      await enterPin(tester, ownerPin);

      final row = await db.select(db.bills).getSingle();
      expect(row.status, BillStatus.cancelled);
      expect(row.cancelReason, 'Wrong item entered');
      expect(row.cancelledBy, ownerId);
      expect(
        row.invoiceNo,
        bill.invoiceNo.formatted,
        reason: 'the number stays',
      );
      expect(row.total.value, 50400, reason: 'the amount stays');
      expect(await db.select(db.billLines).get(), hasLength(1));
    });

    testWidgets('a free-text reason is accepted', (tester) async {
      await openDialog(tester);
      await tester.tap(find.text('Other'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('other-reason')),
        'Kitchen ran out',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cancel-continue')));
      await tester.pumpAndSettle();
      await enterPin(tester, ownerPin);

      final row = await db.select(db.bills).getSingle();
      expect(row.cancelReason, 'Kitchen ran out');
    });
  });

  group('after cancelling', () {
    testWidgets('it shows as cancelled and drops out of the total',
        (tester) async {
      await BillRepository(db).cancelBill(
        billId: bill.id,
        reason: 'Wrong item entered',
        userId: ownerId,
        deviceId: deviceId,
      );

      await show(tester);
      expect(find.text('Cancelled (1)'), findsOneWidget);
      expect(find.textContaining('0 paid'), findsOneWidget);
      expect(find.textContaining('1 cancelled'), findsOneWidget);
    });

    testWidgets('the cancel button is gone, reprint remains', (tester) async {
      await BillRepository(db).cancelBill(
        billId: bill.id,
        reason: 'Wrong item entered',
        userId: ownerId,
        deviceId: deviceId,
      );

      await show(tester);
      await tester.tap(find.text(bill.invoiceNo.formatted).first);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('cancel-bill')), findsNothing);
      expect(
        find.byKey(const Key('reprint')),
        findsOneWidget,
        reason: 'a cancelled bill can still be reprinted as a record',
      );
      expect(find.textContaining('number stays in your records'),
          findsOneWidget);
    });
  });

  group('the list keeps up with what the app does', () {
    testWidgets('a bill saved while the screen is open appears without a '
        'restart', (tester) async {
      // Reported from real use: ring up a bill, switch to Bills, and it is
      // not there until the app is closed and reopened.
      await db.delete(db.payments).go();
      await db.delete(db.billLines).go();
      await db.delete(db.bills).go();

      await show(tester);
      expect(find.textContaining('No bills today yet'), findsOneWidget);

      final computed = computeBill(
        cart: [
          CartLine(
            itemId: 'x',
            nameSnapshot: 'Buttermilk',
            unitPrice: Paise.fromRupees(30),
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
      final fresh = await BillRepository(db).commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: deviceId,
        userId: ownerId,
      );

      await tester.pumpAndSettle();

      expect(
        find.text(fresh.invoiceNo.formatted),
        findsWidgets,
        reason: 'the list must follow the database, not a cached snapshot',
      );
      expect(find.textContaining('No bills today yet'), findsNothing);
    });

    testWidgets('the summary follows too', (tester) async {
      await show(tester);
      expect(find.text('1 paid'), findsOneWidget);

      final computed = computeBill(
        cart: [
          CartLine(
            itemId: 'x',
            nameSnapshot: 'Buttermilk',
            unitPrice: Paise.fromRupees(30),
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
      await BillRepository(db).commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: deviceId,
        userId: ownerId,
      );
      await tester.pumpAndSettle();

      expect(find.text('2 paid'), findsOneWidget);
    });
  });
}
