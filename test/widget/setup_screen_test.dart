/// The setup screen, rendered.
///
/// These actually build the widget tree and tap things, which `flutter analyze`
/// cannot do. Several bugs here would compile perfectly.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/pin.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/features/setup/setup_screen.dart';
import 'package:restaurant_pos/theme/app_theme.dart';

import 'harness.dart';

void main() {
  late PosDatabase db;

  setUp(() => db = PosDatabase.memory());
  tearDown(() => db.close());

  Future<void> show(WidgetTester tester, {Size? size}) =>
      pumpScreen(tester, db: db, child: const SetupScreen(), size: size);

  /// Fills every field with something valid.
  Future<void> fillValid(WidgetTester tester) async {
    await enterByLabel(tester, 'Restaurant name', 'Test Restaurant');
    await enterByLabel(tester, 'Address', 'Main Road, Vijayawada');
    await enterByLabel(tester, 'Phone number', '9000000000');
    await enterByLabel(tester, 'FSSAI licence number', '12345678901234');
    await enterByLabel(tester, 'Owner name', 'Owner');
    await enterByLabel(tester, '4-digit PIN', '1357');
    await enterByLabel(tester, 'Confirm PIN', '1357');
  }

  group('it renders', () {
    testWidgets('on a phone', (tester) async {
      await show(tester, size: const Size(390, 844));
      expect(find.text('Set up your restaurant'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the primary action exists once the form is scrolled through',
        (tester) async {
      await show(tester);
      expect(find.text('Finish setup'), findsOneWidget);
      expect(find.text('Works without internet'), findsOneWidget);
    });

    testWidgets('on a tablet', (tester) async {
      await show(tester, size: const Size(1280, 800));
      expect(find.text('Set up your restaurant'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('with no overflow at the narrowest phone width',
        (tester) async {
      // 320 is the narrowest Android phone still in use. An overflow here
      // would show as the yellow-and-black stripes in production.
      await show(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('every tax mode is offered', (tester) async {
      await show(tester);
      expect(find.text('Not registered for GST'), findsOneWidget);
      expect(find.text('Composition scheme'), findsOneWidget);
      expect(find.text('Regular GST, 5%'), findsOneWidget);
      expect(find.text('Regular GST, 18%'), findsOneWidget);
    });
  });

  group('validation is shown, not just enforced', () {
    testWidgets('an empty form lists every problem at once', (tester) async {
      await show(tester);
      await tester.tap(find.text('Finish setup'));
      await tester.pumpAndSettle();

      expect(find.textContaining('things to fix'), findsOneWidget);
      expect(find.textContaining('needs a name'), findsWidgets,
          reason: 'the restaurant and the owner both need names');
      expect(find.textContaining('FSSAI'), findsWidgets);
      // Nothing was written.
      expect(await db.select(db.outlets).get(), isEmpty);
    });

    testWidgets('a bad FSSAI number blocks setup and says so', (tester) async {
      await show(tester);
      await fillValid(tester);
      await enterByLabel(tester, 'FSSAI licence number', '123');
      await tester.tap(find.text('Finish setup'));
      await tester.pumpAndSettle();

      expect(find.textContaining('14 digits'), findsWidgets);
      expect(await db.select(db.outlets).get(), isEmpty);
    });

    testWidgets('mismatched PINs are caught before anything is written',
        (tester) async {
      await show(tester);
      await fillValid(tester);
      await enterByLabel(tester, 'Confirm PIN', '2468');
      await tester.tap(find.text('Finish setup'));
      await tester.pumpAndSettle();

      expect(find.textContaining('do not match'), findsOneWidget);
      expect(await db.select(db.users).get(), isEmpty);
    });

    testWidgets('a weak PIN is refused with a reason', (tester) async {
      await show(tester);
      await fillValid(tester);
      await enterByLabel(tester, '4-digit PIN', '1111');
      await enterByLabel(tester, 'Confirm PIN', '1111');
      await tester.tap(find.text('Finish setup'));
      await tester.pumpAndSettle();

      expect(find.textContaining('same digit'), findsOneWidget);
      expect(await db.select(db.users).get(), isEmpty);
    });
  });

  group('the GSTIN field appears only when it is needed', () {
    testWidgets('hidden when unregistered', (tester) async {
      await show(tester);
      expect(find.text('GSTIN'), findsNothing);
    });

    testWidgets('appears when a regular registration is chosen',
        (tester) async {
      await show(tester);
      await tester.tap(find.text('Regular GST, 5%'));
      await tester.pumpAndSettle();
      expect(find.text('GSTIN'), findsOneWidget);
    });

    testWidgets('disappears again when switching back', (tester) async {
      await show(tester);
      await tester.tap(find.text('Regular GST, 5%'));
      await tester.pumpAndSettle();
      expect(find.text('GSTIN'), findsOneWidget);

      await tester.tap(find.text('Composition scheme'));
      await tester.pumpAndSettle();
      expect(find.text('GSTIN'), findsNothing);
    });
  });

  group('a complete setup', () {
    testWidgets('writes the outlet, device and owner', (tester) async {
      await show(tester);
      await fillValid(tester);
      await tapAndPump(tester, find.text('Finish setup'));

      final outlet = await db.select(db.outlets).getSingle();
      expect(outlet.name, 'Test Restaurant');
      expect(outlet.fssaiNo, '12345678901234');
      expect(outlet.taxMode, TaxMode.unregistered);
      expect(outlet.businessDayCutoffMinutes, 240);

      final device = await db.select(db.devices).getSingle();
      expect(device.seriesPrefix, 'A');
      expect(device.nextSeq, 1);

      final owner = await db.select(db.users).getSingle();
      expect(owner.name, 'Owner');
      expect(owner.role, UserRole.owner);
      expect(verifyPin('1357', owner.pinHash), isTrue);
      expect(owner.pinHash.contains('1357'), isFalse);
    });

    testWidgets('a regular registration stores the GSTIN upper-cased',
        (tester) async {
      await show(tester);
      await fillValid(tester);
      await tester.tap(find.text('Regular GST, 5%'));
      await tester.pumpAndSettle();
      await enterByLabel(tester, 'GSTIN', '37abcde1234f1z5');
      await tapAndPump(tester, find.text('Finish setup'));

      final outlet = await db.select(db.outlets).getSingle();
      expect(outlet.gstin, '37ABCDE1234F1Z5');
      expect(outlet.taxMode, TaxMode.regular5);
    });

    testWidgets('the tax-inclusive toggle is carried through', (tester) async {
      await show(tester);
      await fillValid(tester);
      await tester.tap(find.text('Menu prices already include tax'));
      await tester.pumpAndSettle();
      await tapAndPump(tester, find.text('Finish setup'));

      final outlet = await db.select(db.outlets).getSingle();
      expect(outlet.pricesIncludeTax, isTrue);
    });
  });

  group('accessibility and touch targets', () {
    testWidgets('the primary action is big enough for a busy counter',
        (tester) async {
      await show(tester);
      final size = tester.getSize(find.byType(FilledButton).first);
      expect(size.height, greaterThanOrEqualTo(AppTouch.large));
    });

    testWidgets('tax mode tiles meet the touch minimum', (tester) async {
      await show(tester);
      final tile = find.ancestor(
        of: find.text('Composition scheme'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(tile.first).height,
          greaterThanOrEqualTo(AppTouch.min));
    });
  });
}
