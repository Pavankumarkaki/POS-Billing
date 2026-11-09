/// The reports screen.
///
/// The figures themselves are tested in test/data/reports_test.dart. What
/// matters here is that the screen shows the right ones, is owner-only, and
/// does not overflow with real-looking numbers in it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/features/reports/reports_screen.dart';
import 'package:restaurant_pos/providers.dart';

import 'harness.dart';

void main() {
  late PosDatabase db;
  late String ownerId;
  late String staffId;
  late String deviceId;
  late String biryaniId;

  /// A fixed Thursday, so "this week" and "this month" both span more than
  /// one day whatever day the suite is actually run on. A Monday leaves the
  /// week one day long, and the 1st leaves the month one day long, and in
  /// both cases the by-day chart correctly does not appear.
  const pinnedDay = BusinessDate(2026, 6, 18);
  final pinnedAt = DateTime(2026, 6, 18, 12);

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
    ), at: DateTime(2026, 4, 1, 10));
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
    biryaniId = await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );
  }

  setUp(() => seed());
  tearDown(() => db.close());

  Future<SavedBill> sell({
    int qty = 1,
    PaymentMode mode = PaymentMode.cash,
    OrderType orderType = OrderType.dine,
    DateTime? at,
  }) async {
    final computed = computeBill(
      cart: [
        CartLine(
          itemId: biryaniId,
          nameSnapshot: 'Chicken Dum Biryani',
          unitPrice: Paise.fromRupees(240),
          qty: qty,
          taxClass: TaxClass.gst5,
        ),
      ],
      config: const TaxConfig(
        mode: TaxMode.regular5,
        pricesIncludeTax: false,
      ),
      orderType: orderType,
    );
    return BillRepository(db).commitSale(
      computed: computed,
      payments: [PaymentIntent(mode, computed.total)],
      deviceId: deviceId,
      userId: ownerId,
      at: at ?? pinnedAt,
    );
  }

  Future<void> show(
    WidgetTester tester, {
    UserRole role = UserRole.owner,
    Size? size,
  }) async {
    await pumpScreen(
      tester,
      db: db,
      size: size ?? const Size(1280, 800),
      today: pinnedDay,
      child: const ReportsScreen(),
      before: (c) => c.read(sessionProvider.notifier).signIn(Session(
            userId: role == UserRole.owner ? ownerId : staffId,
            name: role == UserRole.owner ? 'Ravi' : 'Kiran',
            role: role,
            startedAt: DateTime(2026, 6, 1),
          )),
    );
    await tester.pumpAndSettle();
  }

  group('permissions', () {
    testWidgets('staff are refused', (tester) async {
      await show(tester, role: UserRole.staff);
      expect(find.textContaining('Only the owner'), findsOneWidget);
      expect(find.text('Total sales'), findsNothing);
    });

    testWidgets('the owner sees the report', (tester) async {
      await show(tester);
      expect(find.text('Total sales'), findsOneWidget);
    });
  });

  group('rendering', () {
    testWidgets('an empty period says so rather than showing zeroes '
        'everywhere', (tester) async {
      await show(tester);
      expect(find.textContaining('No sales in this period'), findsOneWidget);
    });

    testWidgets('phone, with sales, no overflow', (tester) async {
      await sell(qty: 3);
      await sell(mode: PaymentMode.upi);
      await show(tester, size: const Size(390, 844));
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow phone, no overflow', (tester) async {
      await sell(qty: 3);
      await show(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('large figures do not overflow the tiles', (tester) async {
      // A busy month: the KPI tiles have to cope with lakhs.
      for (var i = 0; i < 40; i++) {
        await sell(qty: 20);
      }
      await show(tester, size: const Size(390, 844));
      expect(tester.takeException(), isNull);
    });
  });

  group('the figures shown', () {
    testWidgets('total, count and average', (tester) async {
      await sell();
      await sell(qty: 3);
      await show(tester);

      // 252 + 756 = 1008
      expect(find.text('₹1,008'), findsWidgets);
      expect(find.text('2'), findsWidgets);
    });

    testWidgets('payment modes are broken out', (tester) async {
      await sell();
      await sell(mode: PaymentMode.upi);
      await show(tester);

      expect(find.text('How customers paid'), findsOneWidget);
      expect(find.text('Cash'), findsOneWidget);
      expect(find.text('UPI'), findsOneWidget);
    });

    testWidgets('top items are listed', (tester) async {
      await sell(qty: 4);
      await show(tester);

      expect(find.text('Top items'), findsOneWidget);
      expect(find.text('Chicken Dum Biryani'), findsOneWidget);
      expect(find.text('4 sold'), findsOneWidget);
    });

    testWidgets('the tax summary shows the rate', (tester) async {
      await sell();
      await show(tester);
      expect(find.text('Tax summary'), findsOneWidget);
      expect(find.textContaining('Taxable at 5%'), findsOneWidget);
    });

    testWidgets('the cutoff is explained, because it surprises people',
        (tester) async {
      await show(tester);
      expect(find.textContaining('Days run to 4 AM'), findsOneWidget);
    });
  });

  group('cancelled bills', () {
    testWidgets('are shown separately and left out of the total',
        (tester) async {
      final a = await sell();
      await sell();
      await BillRepository(db).cancelBill(
        billId: a.id,
        reason: 'Wrong item entered',
        userId: ownerId,
        deviceId: deviceId,
      );

      await show(tester);

      expect(find.text('Cancelled'), findsOneWidget);
      expect(find.textContaining('1 bill cancelled'), findsOneWidget);
      // One bill of 252 remains.
      expect(find.text('₹252'), findsWidgets);
    });
  });

  group('aggregator orders', () {
    testWidgets('their GST is kept out of what the restaurant owes',
        (tester) async {
      await sell(orderType: OrderType.aggregator);
      await show(tester);

      expect(find.text('GST you owe'), findsOneWidget);
      expect(find.text('₹0'), findsWidgets);
      expect(find.textContaining('aggregator pays the GST'), findsOneWidget);
    });
  });

  group('the period picker', () {
    testWidgets('switches between today, week and month', (tester) async {
      await sell();
      await show(tester);

      await tester.tap(find.byKey(const Key('period-week')));
      await tester.pumpAndSettle();
      expect(find.text('Sales by day this week'), findsOneWidget);

      await tester.tap(find.byKey(const Key('period-month')));
      await tester.pumpAndSettle();
      expect(find.text('Sales by day this month'), findsOneWidget);

      await tester.tap(find.byKey(const Key('period-today')));
      await tester.pumpAndSettle();
      // One day is one bar, which says nothing the Total sales tile has not.
      expect(find.text('Sales by day this week'), findsNothing);
      expect(find.text('Sales by day this month'), findsNothing);
      expect(find.text('Total sales'), findsOneWidget);
    });

    testWidgets('a week only one day old shows no chart, which is correct',
        (tester) async {
      // The owner's week starts on Monday, so on a Monday "this week" is one
      // day and there is nothing to compare. The chart is hidden by design.
      // Worth a test of its own: it is why the test above pins a Thursday,
      // and without it that pin looks arbitrary and gets "tidied" away.
      const monday = BusinessDate(2026, 6, 15);
      await sell(at: DateTime(2026, 6, 15, 12));
      await pumpScreen(
        tester,
        db: db,
        size: const Size(1280, 800),
        today: monday,
        child: const ReportsScreen(),
        before: (c) => c.read(sessionProvider.notifier).signIn(Session(
              userId: ownerId,
              name: 'Ravi',
              role: UserRole.owner,
              startedAt: DateTime(2026, 6, 1),
            )),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('period-week')));
      await tester.pumpAndSettle();

      expect(find.text('Sales by day this week'), findsNothing);
      // The sale itself is still reported, so this is a hidden chart and not
      // an empty report.
      expect(find.text('Total sales'), findsOneWidget);
    });
  });

  group('turnover warnings', () {
    testWidgets('nothing shown well below the limit', (tester) async {
      await sell();
      await show(tester);
      expect(find.byKey(const Key('turnover-warning')), findsNothing);
    });

    testWidgets('an unregistered outlet past 80% is warned, and pointed at '
        'the CA', (tester) async {
      await db.close();
      await seed(mode: TaxMode.unregistered);

      // ₹20 lakh threshold; 80% is ₹16 lakh. Each bill here is ₹2,400.
      for (var i = 0; i < 700; i++) {
        await sell(qty: 10);
      }

      await show(tester);
      expect(find.byKey(const Key('turnover-warning')), findsOneWidget);
      expect(find.textContaining('registration limit'), findsOneWidget);
      expect(find.textContaining('CA'), findsWidgets);
    });

    testWidgets('a registered outlet is never warned', (tester) async {
      for (var i = 0; i < 700; i++) {
        await sell(qty: 10);
      }
      await show(tester);
      expect(
        find.byKey(const Key('turnover-warning')),
        findsNothing,
        reason: 'already registered: there is no limit to cross',
      );
    });
  });

  group('the report follows the data', () {
    testWidgets('a sale made while the screen is open shows up',
        (tester) async {
      await sell();
      await show(tester);
      expect(find.text('₹252'), findsWidgets);

      await sell();
      await tester.pumpAndSettle();

      // 252 + 252
      expect(find.text('₹504'), findsWidgets);
    });
  });
}
