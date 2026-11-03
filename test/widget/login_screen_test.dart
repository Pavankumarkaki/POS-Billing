/// The login screen, rendered, including the lockout as the user sees it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/features/auth/login_screen.dart';
import 'package:restaurant_pos/features/auth/pin_keypad.dart';
import 'package:restaurant_pos/theme/app_theme.dart';

import 'harness.dart';

void main() {
  late PosDatabase db;

  setUp(() async {
    db = PosDatabase.memory();
    final setup = SetupRepository(db);
    await setup.completeSetup(const SetupDetails(
      outletName: 'Test Restaurant',
      address: 'Main Road, Vijayawada',
      phone: '9000000000',
      fssaiNo: '12345678901234',
      taxMode: TaxMode.unregistered,
      ownerName: 'Owner',
      ownerPin: '1357',
      devicePrefix: 'A',
    ));
  });

  tearDown(() => db.close());

  Future<void> show(WidgetTester tester, {Size? size}) =>
      pumpScreen(tester, db: db, child: const LoginScreen(), size: size);

  /// Taps a digit on the keypad.
  Future<void> key(WidgetTester tester, String digit) async {
    await tester.tap(find.widgetWithText(OutlinedButton, digit).last);
    await tester.pump();
  }

  Future<void> enterPin(WidgetTester tester, String pin) async {
    for (final d in pin.split('')) {
      await key(tester, d);
    }
    await tester.pump(const Duration(seconds: 1));
  }

  group('it renders both layouts', () {
    testWidgets('phone', (tester) async {
      await show(tester, size: const Size(390, 844));
      expect(find.text('Test Restaurant'), findsOneWidget);
      expect(find.textContaining('Who is billing'), findsOneWidget);
      expect(find.text('Works without internet'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tablet', (tester) async {
      await show(tester, size: const Size(1280, 800));
      expect(find.text('Test Restaurant'), findsOneWidget);
      expect(find.text('Who is billing today?'), findsOneWidget);
      expect(
        find.text('ఈ రోజు బిల్లింగ్ ఎవరు చేస్తున్నారు?'),
        findsOneWidget,
        reason: 'the Telugu line is part of the design, not decoration',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow on a narrow phone', (tester) async {
      await show(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow on a short landscape phone', (tester) async {
      await show(tester, size: const Size(740, 360));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the keypad has all twelve keys', (tester) async {
      await show(tester);
      expect(find.byType(PinKeypad), findsOneWidget);
      for (final d in ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']) {
        expect(find.widgetWithText(OutlinedButton, d), findsWidgets,
            reason: 'key $d');
      }
      expect(find.text('Clear'), findsOneWidget);
    });
  });

  group('the single user is preselected', () {
    testWidgets('so the owner can type their PIN straight away',
        (tester) async {
      await show(tester);
      // One user exists, so the prompt should already be asking for a PIN.
      expect(find.text('Enter your 4-digit PIN'), findsOneWidget);
      expect(find.text('Choose who is billing'), findsNothing);
    });
  });

  group('signing in', () {
    testWidgets('the right PIN clears the screen for the session',
        (tester) async {
      await show(tester);
      await enterPin(tester, '1357');

      // The screen itself does not navigate; the root widget swaps it. What it
      // must not do is report an error.
      expect(find.textContaining('Wrong PIN'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wrong PIN says how many tries are left', (tester) async {
      await show(tester);
      await enterPin(tester, '9999');
      expect(find.textContaining('Wrong PIN'), findsOneWidget);
      expect(find.textContaining('4 tries left'), findsOneWidget);
    });

    testWidgets('the dots clear after a wrong PIN', (tester) async {
      await show(tester);
      await enterPin(tester, '9999');
      // A fresh attempt starts empty rather than leaving four filled dots.
      final dots = tester.widget<PinDots>(find.byType(PinDots));
      expect(dots.entered, 0);
    });

    testWidgets('the message row does not move the keypad', (tester) async {
      await show(tester, size: const Size(390, 844));
      final before = tester.getTopLeft(find.byType(PinKeypad));

      await enterPin(tester, '9999');

      final after = tester.getTopLeft(find.byType(PinKeypad));
      expect(
        after,
        before,
        reason: 'a keypad that shifts under a thumb causes more wrong PINs',
      );
    });

    testWidgets('backspace removes one digit', (tester) async {
      await show(tester);
      await key(tester, '1');
      await key(tester, '3');
      expect(tester.widget<PinDots>(find.byType(PinDots)).entered, 2);

      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();
      expect(tester.widget<PinDots>(find.byType(PinDots)).entered, 1);
    });

    testWidgets('Clear empties the whole PIN', (tester) async {
      await show(tester);
      await key(tester, '1');
      await key(tester, '3');
      await key(tester, '5');
      expect(tester.widget<PinDots>(find.byType(PinDots)).entered, 3);

      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(tester.widget<PinDots>(find.byType(PinDots)).entered, 0);
    });
  });

  group('the lockout, as the user sees it', () {
    testWidgets('five wrong PINs lock the screen with a readable message',
        (tester) async {
      await show(tester);

      for (var i = 0; i < 4; i++) {
        await enterPin(tester, '9999');
        expect(find.textContaining('Wrong PIN'), findsOneWidget,
            reason: 'attempt ${i + 1}');
      }

      await enterPin(tester, '9999');
      expect(find.textContaining('Locked for'), findsOneWidget);
      expect(find.textContaining('Wrong PIN'), findsNothing);
    });

    testWidgets('the right PIN is refused while locked', (tester) async {
      await show(tester);
      for (var i = 0; i < 5; i++) {
        await enterPin(tester, '9999');
      }
      await enterPin(tester, '1357');
      expect(find.textContaining('Locked for'), findsOneWidget);
    });
  });

  group('touch targets', () {
    testWidgets('keypad keys are comfortably tappable on a phone',
        (tester) async {
      await show(tester, size: const Size(390, 844));
      final size = tester.getSize(
        find.widgetWithText(OutlinedButton, '5').last,
      );
      expect(size.height, greaterThanOrEqualTo(AppTouch.min));
      expect(size.width, greaterThanOrEqualTo(AppTouch.min));
    });

    testWidgets('and on a tablet', (tester) async {
      await show(tester, size: const Size(1280, 800));
      final size = tester.getSize(
        find.widgetWithText(OutlinedButton, '5').last,
      );
      expect(size.height, greaterThanOrEqualTo(AppTouch.large));
    });
  });
}
