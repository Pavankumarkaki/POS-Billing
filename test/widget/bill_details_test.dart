/// The Bill details card in Settings.
///
/// The rules worth protecting here are the ones a screen can quietly break:
/// that a bad FSSAI number cannot be saved, that a tax mode change is
/// deliberate rather than a stray tap, and that the billing screen notices
/// the change without the app being restarted.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/outlet_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/features/settings/bill_details_section.dart';
import 'package:restaurant_pos/providers.dart';

import 'harness.dart';

void main() {
  late PosDatabase db;
  late String ownerId;
  late String staffId;

  Future<void> seed({TaxMode mode = TaxMode.regular5}) async {
    db = PosDatabase.memory();
    final setup = SetupRepository(db);
    final r = await setup.completeSetup(
      SetupDetails(
        outletName: 'Annapurna Mess',
        address: 'Main Road',
        phone: '9000000000',
        fssaiNo: '12345678901234',
        taxMode: mode,
        gstin: mode == TaxMode.unregistered ? null : '37ABCDE1234F1Z5',
        ownerName: 'Ravi',
        ownerPin: '1357',
        devicePrefix: 'A',
      ),
      at: DateTime(2026, 4, 1, 10),
    );
    ownerId = r.ownerId;
    staffId = await setup.addUser(
      name: 'Kiran',
      role: UserRole.staff,
      pin: '2468',
      byUserId: ownerId,
    );

    final menu = MenuRepository(db, deviceId: r.deviceId);
    final cat = await menu.createCategory(nameEn: 'Biryani', byUserId: ownerId);
    await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );
  }

  setUp(() => seed());
  tearDown(() => db.close());

  Future<ProviderContainer> show(
    WidgetTester tester, {
    UserRole role = UserRole.owner,
    Size? size,
  }) async {
    final container = await pumpScreen(
      tester,
      db: db,
      size: size,
      child: const Scaffold(
        body: SingleChildScrollView(child: BillDetailsSection()),
      ),
      before: (c) => c.read(sessionProvider.notifier).signIn(Session(
            userId: role == UserRole.owner ? ownerId : staffId,
            name: role == UserRole.owner ? 'Ravi' : 'Kiran',
            role: role,
            startedAt: DateTime(2026, 11, 8),
          )),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<OutletRow> outlet() => db.select(db.outlets).getSingle();

  group('what it shows', () {
    testWidgets('the stored values', (tester) async {
      await show(tester);

      expect(
        tester.widget<TextField>(find.byKey(const Key('fssai-field')))
            .controller!
            .text,
        '12345678901234',
      );
      expect(
        tester.widget<TextField>(find.byKey(const Key('gstin-field')))
            .controller!
            .text,
        '37ABCDE1234F1Z5',
      );
      expect(find.text('Regular GST, 5%'), findsOneWidget);
    });

    testWidgets('every tax type, so the outlet can move between them',
        (tester) async {
      await show(tester);
      for (final mode in TaxMode.values) {
        expect(find.byKey(Key('tax-${mode.wireName}')), findsOneWidget);
      }
    });

    testWidgets('no GSTIN field for an unregistered outlet, and it says why',
        (tester) async {
      await seed(mode: TaxMode.unregistered);
      await show(tester);

      expect(find.byKey(const Key('gstin-field')), findsNothing);
      expect(find.byKey(const Key('gstin-cleared-note')), findsOneWidget);
    });

    testWidgets('Save is off until something is edited', (tester) async {
      await show(tester);
      final button = tester.widget<FilledButton>(
        find.byKey(const Key('save-bill-details')),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('correcting the licence number', () {
    testWidgets('saves, and says so', (tester) async {
      await show(tester);

      await tester.enterText(
        find.byKey(const Key('fssai-field')),
        '99999999999999',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();

      expect((await outlet()).fssaiNo, '99999999999999');
      expect(find.text('Saved.'), findsOneWidget);
    });

    testWidgets('does not ask about tax invoices', (tester) async {
      // A typo fix should not make the owner read a dialog about tax modes.
      await show(tester);
      await tester.enterText(
        find.byKey(const Key('fssai-field')),
        '99999999999999',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('confirm-tax-mode')), findsNothing);
    });

    testWidgets('a short number is refused, and the stored one survives',
        (tester) async {
      // The brief blocks billing without a valid FSSAI number. This screen
      // must not become a way around that.
      await show(tester);

      await tester.enterText(find.byKey(const Key('fssai-field')), '123');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();

      expect(find.textContaining('exactly 14 digits'), findsOneWidget);
      expect((await outlet()).fssaiNo, '12345678901234');
    });

    testWidgets('the field takes digits only', (tester) async {
      await show(tester);
      await tester.enterText(
        find.byKey(const Key('fssai-field')),
        '12ab34cd5678901234',
      );
      await tester.pumpAndSettle();

      final text = tester
          .widget<TextField>(find.byKey(const Key('fssai-field')))
          .controller!
          .text;
      expect(text, '12345678901234');
      expect(text.length, 14, reason: 'and no more than 14 of them');
    });
  });

  group('changing the tax type', () {
    testWidgets('asks first, and says what it does and does not do',
        (tester) async {
      await show(tester);

      await tester.tap(find.byKey(const Key('tax-unregistered')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('tax-mode-effect')), findsOneWidget);
      expect(find.textContaining('plain bills with no tax'), findsOneWidget);
      expect(
        find.textContaining('Bills already issued do not change'),
        findsOneWidget,
      );
      expect((await outlet()).taxMode, TaxMode.regular5,
          reason: 'nothing saved until it is confirmed');
    });

    testWidgets('confirming saves it', (tester) async {
      await show(tester);

      await tester.tap(find.byKey(const Key('tax-unregistered')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-tax-mode')));
      await tester.pumpAndSettle();

      final o = await outlet();
      expect(o.taxMode, TaxMode.unregistered);
      expect(o.gstin, isNull, reason: 'an unregistered outlet has no GSTIN');
    });

    testWidgets('declining leaves everything alone', (tester) async {
      await show(tester);

      await tester.tap(find.byKey(const Key('tax-unregistered')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep it as it is'));
      await tester.pumpAndSettle();

      expect((await outlet()).taxMode, TaxMode.regular5);
      expect((await outlet()).gstin, '37ABCDE1234F1Z5');
    });

    testWidgets('picking a registered type reveals the GSTIN field',
        (tester) async {
      await seed(mode: TaxMode.unregistered);
      await show(tester);
      expect(find.byKey(const Key('gstin-field')), findsNothing);

      await tester.tap(find.byKey(const Key('tax-regular_5')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('gstin-field')), findsOneWidget);
    });

    testWidgets('registering without a GSTIN is refused', (tester) async {
      await seed(mode: TaxMode.unregistered);
      await show(tester);

      await tester.tap(find.byKey(const Key('tax-regular_5')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();

      expect(find.textContaining('GSTIN is required'), findsOneWidget);
      expect((await outlet()).taxMode, TaxMode.unregistered);
    });

    testWidgets('crossing the threshold: unregistered to regular, with a '
        'GSTIN typed in', (tester) async {
      // The realistic reason this screen exists at all.
      await seed(mode: TaxMode.unregistered);
      await show(tester);

      await tester.tap(find.byKey(const Key('tax-regular_5')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('gstin-field')),
        '37ABCDE1234F1Z5',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-tax-mode')));
      await tester.pumpAndSettle();

      final o = await outlet();
      expect(o.taxMode, TaxMode.regular5);
      expect(o.gstin, '37ABCDE1234F1Z5');

      // And the change is dated, so the accountant can tell which bills were
      // on which type.
      final history = await OutletRepository(db).taxProfileHistory();
      expect(history, hasLength(2));
      expect(history.last.mode, TaxMode.regular5);
    });

    testWidgets('a bad GSTIN is refused', (tester) async {
      await show(tester);
      await tester.enterText(find.byKey(const Key('gstin-field')), 'NOPE');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();

      expect(find.textContaining('15 characters'), findsWidgets);
      expect((await outlet()).gstin, '37ABCDE1234F1Z5');
    });
  });

  group('permissions', () {
    testWidgets('staff cannot save, even reaching the button somehow',
        (tester) async {
      // The Settings tab is owner-only, so staff should never get here. The
      // repository refuses anyway, and this proves the screen surfaces that
      // rather than appearing to succeed.
      await show(tester, role: UserRole.staff);

      await tester.enterText(
        find.byKey(const Key('fssai-field')),
        '99999999999999',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Only the owner'), findsOneWidget);
      expect((await outlet()).fssaiNo, '12345678901234');
    });
  });

  group('the rest of the app notices', () {
    testWidgets('the outlet stream carries the new tax mode', (tester) async {
      // The billing screen builds its tax configuration from this. A cached
      // future would leave it computing bills on the old mode until restart,
      // which is the bug that once hid a saved bill from the Bills tab.
      //
      // Read as an AsyncValue, not through `.future`: a StreamProvider's
      // future completes on the first value and does not resolve again, so
      // awaiting it a second time waits for ever. A listener keeps the stream
      // subscribed so later values arrive.
      final container = await show(tester);
      container.listen(outletProvider, (_, _) {}, fireImmediately: true);
      await tester.pumpAndSettle();

      expect(
        container.read(outletProvider).value!.taxMode,
        TaxMode.regular5,
      );

      await tester.tap(find.byKey(const Key('tax-unregistered')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-bill-details')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-tax-mode')));
      await tester.pumpAndSettle();

      expect(
        container.read(outletProvider).value!.taxMode,
        TaxMode.unregistered,
        reason: 'without a restart',
      );
      expect(container.read(outletProvider).value!.gstin, isNull);
    });
  });

  group('layout', () {
    testWidgets('a phone does not overflow', (tester) async {
      await show(tester, size: const Size(390, 3000));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow phone does not overflow', (tester) async {
      await show(tester, size: const Size(320, 3000));
      expect(tester.takeException(), isNull);
    });

    testWidgets('every tax tile is big enough to hit', (tester) async {
      await show(tester, size: const Size(390, 3000));
      for (final mode in TaxMode.values) {
        expect(
          tester.getSize(find.byKey(Key('tax-${mode.wireName}'))).height,
          greaterThanOrEqualTo(44),
          reason: mode.wireName,
        );
      }
    });
  });
}
