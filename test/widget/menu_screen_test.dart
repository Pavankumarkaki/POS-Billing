/// The menu admin screen, rendered and driven.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/features/menu/menu_screen.dart';
import 'package:restaurant_pos/providers.dart';
import 'package:restaurant_pos/theme/app_theme.dart';

import 'harness.dart';

void main() {
  late PosDatabase db;
  late String ownerId;
  late String staffId;
  late String deviceId;
  late String biryaniId;

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
      ownerPin: '1357',
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
    biryaniId = await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      nameTe: 'చికెన్ దమ్ బిర్యానీ',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );
  });

  tearDown(() => db.close());

  /// Renders the menu screen with [role] signed in.
  Future<void> show(
    WidgetTester tester, {
    Size? size,
    UserRole role = UserRole.owner,
  }) async {
    await pumpScreen(
      tester,
      db: db,
      size: size,
      child: const MenuScreen(),
      // Signed in through the real notifier, so the screen's permission check
      // runs exactly as it does in the app.
      before: (container) => container.read(sessionProvider.notifier).signIn(
            Session(
              userId: role == UserRole.owner ? ownerId : staffId,
              name: role == UserRole.owner ? 'Ravi' : 'Kiran',
              role: role,
              startedAt: DateTime(2026, 6, 1),
            ),
          ),
    );
    await tester.pumpAndSettle();
  }

  group('permissions', () {
    testWidgets('staff see a refusal, not an editable form', (tester) async {
      await show(tester, role: UserRole.staff);
      expect(find.textContaining('Only the owner'), findsOneWidget);
      expect(find.byKey(const Key('add-item')), findsNothing);
    });

    testWidgets('the owner sees the menu', (tester) async {
      await show(tester);
      expect(find.text('Chicken Dum Biryani'), findsOneWidget);
      expect(find.byKey(const Key('add-item')), findsOneWidget);
    });
  });

  group('it renders both layouts', () {
    testWidgets('phone', (tester) async {
      await show(tester, size: const Size(390, 844));
      expect(find.text('Chicken Dum Biryani'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tablet shows all three panes', (tester) async {
      await show(tester, size: const Size(1280, 800));
      expect(find.text('Biryani'), findsWidgets);
      expect(find.text('Chicken Dum Biryani'), findsOneWidget);
      expect(find.textContaining('Pick an item'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow phone does not overflow', (tester) async {
      await show(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('both names and the price are shown', (tester) async {
      await show(tester, size: const Size(1280, 800));
      expect(find.text('Chicken Dum Biryani'), findsOneWidget);
      expect(find.text('చికెన్ దమ్ బిర్యానీ'), findsOneWidget);
      expect(find.text('₹240'), findsOneWidget);
      expect(find.text('GST 5%'), findsWidgets);
    });

    testWidgets('a very long item name does not overflow', (tester) async {
      final menu = MenuRepository(db, deviceId: deviceId);
      final cats = await menu.categoryTree();
      await menu.createItem(
        categoryId: cats.first.category.id,
        nameEn: 'Special Hyderabadi Gongura Mutton Dum Biryani Family Pack '
            'With Extra Raita And Mirchi Ka Salan',
        nameTe: 'ప్రత్యేక హైదరాబాదీ గోంగూర మటన్ దమ్ బిర్యానీ ఫ్యామిలీ ప్యాక్',
        price: Paise.fromRupees(1250),
        taxClass: TaxClass.gst5,
        byUserId: ownerId,
      );

      await show(tester, size: const Size(390, 844));
      expect(tester.takeException(), isNull);
    });
  });

  group('editing an item', () {
    testWidgets('the editor loads the item it was given', (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Chicken Dum Biryani'));
      await tester.pumpAndSettle();

      final nameEn = tester.widget<TextField>(
        find.byKey(const Key('item-name-en')),
      );
      expect(nameEn.controller!.text, 'Chicken Dum Biryani');

      final price = tester.widget<TextField>(
        find.byKey(const Key('item-price')),
      );
      expect(price.controller!.text, '240.00');
    });

    testWidgets('a price change is saved in paise', (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Chicken Dum Biryani'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('item-price')), '260.50');
      await tester.tap(find.byKey(const Key('item-save')));
      await tester.pumpAndSettle();

      final row = await (db.select(db.items)
            ..where((i) => i.id.equals(biryaniId)))
          .getSingle();
      expect(row.pricePaise.value, 26050);
    });

    testWidgets('a bad price is refused with a readable message',
        (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Chicken Dum Biryani'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('item-price')), '...');
      await tester.tap(find.byKey(const Key('item-save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Enter a price'), findsOneWidget);
      final row = await (db.select(db.items)
            ..where((i) => i.id.equals(biryaniId)))
          .getSingle();
      expect(row.pricePaise.value, 24000, reason: 'unchanged');
    });

    testWidgets('an empty name is refused', (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Chicken Dum Biryani'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('item-name-en')), '   ');
      await tester.tap(find.byKey(const Key('item-save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('needs an English name'), findsOneWidget);
    });

    testWidgets('the tax class can be changed', (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Chicken Dum Biryani'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'GST 18%'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('item-save')));
      await tester.pumpAndSettle();

      final row = await (db.select(db.items)
            ..where((i) => i.id.equals(biryaniId)))
          .getSingle();
      expect(row.taxClass, TaxClass.gst18);
    });

    testWidgets('the price note is shown, because it surprises people',
        (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Chicken Dum Biryani'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('applies to new bills only'),
        findsOneWidget,
      );
    });
  });

  group('disabling an item', () {
    testWidgets('hides it from billing but keeps it on the admin list',
        (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Chicken Dum Biryani'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('item-available')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('item-save')));
      await tester.pumpAndSettle();

      final row = await (db.select(db.items)
            ..where((i) => i.id.equals(biryaniId)))
          .getSingle();
      expect(row.isActive, isFalse);

      // Still listed, so it can be brought back. The name now appears twice,
      // once in the list and once in the editor field, so assert on the
      // status label, which only the list row has.
      expect(find.text('Chicken Dum Biryani'), findsWidgets);
      expect(find.text('Hidden from billing'), findsOneWidget);
    });

    testWidgets('the row still exists in the database', (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Chicken Dum Biryani'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('item-available')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('item-save')));
      await tester.pumpAndSettle();

      expect(await db.select(db.items).get(), hasLength(1),
          reason: 'disabled, never deleted');
    });
  });

  group('adding', () {
    testWidgets('a new item appears in the list', (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.byKey(const Key('add-item')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('item-name-en')),
        'Mutton Dum Biryani',
      );
      await tester.enterText(find.byKey(const Key('item-price')), '340');
      await tester.tap(find.byKey(const Key('item-save')));
      await tester.pumpAndSettle();

      // Twice: the list row and the editor still showing what was saved.
      expect(find.text('Mutton Dum Biryani'), findsWidgets);
      expect(await db.select(db.items).get(), hasLength(2));

      final saved = await (db.select(db.items)
            ..where((i) => i.nameEn.equals('Mutton Dum Biryani')))
          .getSingle();
      expect(saved.pricePaise.value, 34000);
      expect(saved.isActive, isTrue);
    });

    testWidgets('a category can be added', (tester) async {
      await show(tester, size: const Size(1280, 800));
      await tester.tap(find.text('Add category'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('category-name')), 'Tiffins');
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(find.text('Tiffins'), findsWidgets);
      expect(await db.select(db.categories).get(), hasLength(2));
    });
  });

  group('touch targets', () {
    testWidgets('item rows are comfortably tappable', (tester) async {
      await show(tester, size: const Size(390, 844));
      final row = find.ancestor(
        of: find.text('Chicken Dum Biryani'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(row.first).height,
          greaterThanOrEqualTo(AppTouch.min));
    });
  });
}
