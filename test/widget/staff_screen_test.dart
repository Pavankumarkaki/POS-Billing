/// The Staff screen, and the My PIN dialog beside it.
///
/// The rules worth protecting here are the ones a screen can quietly break:
/// that a cashier cannot reach staff management at all, that the list does not
/// go stale after an add or a removal, that the last owner cannot be removed,
/// and that resetting someone's PIN needs the owner's own PIN first.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/features/auth/change_pin_dialog.dart';
import 'package:restaurant_pos/features/settings/printer_settings_screen.dart';
import 'package:restaurant_pos/features/settings/staff_screen.dart';
import 'package:restaurant_pos/providers.dart';

import 'harness.dart';

void main() {
  late PosDatabase db;
  late String ownerId;
  late String staffId;
  late String deviceId;

  const ownerPin = '1357';
  const staffPin = '2468';

  Future<void> seed() async {
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
        ownerPin: ownerPin,
        devicePrefix: 'A',
      ),
      at: DateTime(2026, 4, 1, 10),
    );
    ownerId = r.ownerId;
    deviceId = r.deviceId;
    staffId = await setup.addUser(
      name: 'Kiran',
      role: UserRole.staff,
      pin: staffPin,
      byUserId: ownerId,
    );
  }

  setUp(() => seed());
  tearDown(() => db.close());

  AuthRepository auth() => AuthRepository(db, deviceId: deviceId);

  Future<ProviderContainer> show(
    WidgetTester tester, {
    UserRole role = UserRole.owner,
    Size? size,
  }) async {
    final container = await pumpScreen(
      tester,
      db: db,
      size: size,
      child: const StaffScreen(),
      before: (c) => c.read(sessionProvider.notifier).signIn(Session(
            userId: role == UserRole.owner ? ownerId : staffId,
            name: role == UserRole.owner ? 'Ravi' : 'Kiran',
            role: role,
            startedAt: DateTime(2026, 11, 9),
          )),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<UserRow> user(String id) =>
      (db.select(db.users)..where((u) => u.id.equals(id))).getSingle();

  group('who can see it', () {
    testWidgets('the owner sees the staff list', (tester) async {
      await show(tester);

      expect(find.text('Ravi'), findsOneWidget);
      expect(find.text('Kiran'), findsOneWidget);

      // Scoped to each row: "Owner" and "Cashier" also label the role tiles
      // in the Add someone card, so a bare find.text would match those too.
      expect(
        find.descendant(
          of: find.byKey(Key('staff-$ownerId')),
          matching: find.text('Owner'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(Key('staff-$staffId')),
          matching: find.text('Cashier'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(Key('staff-$ownerId')),
          matching: find.text('You'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a cashier is refused, even reaching it directly',
        (tester) async {
      // The tab is not offered to staff at all. This is the backstop.
      await show(tester, role: UserRole.staff);

      expect(find.text('Only the owner can manage staff.'), findsOneWidget);
      expect(find.byKey(Key('staff-$staffId')), findsNothing);
    });
  });

  group('adding someone', () {
    testWidgets('a new cashier appears without a restart', (tester) async {
      await show(tester);

      await tester.enterText(
        find.byKey(const Key('add-staff-name')),
        'Lakshmi',
      );
      await tester.enterText(find.byKey(const Key('add-staff-pin')), '9753');
      await tester.enterText(
        find.byKey(const Key('add-staff-pin-confirm')),
        '9753',
      );
      await tester.tap(find.byKey(const Key('add-staff-save')));
      await tester.pumpAndSettle();

      expect(find.text('Lakshmi'), findsOneWidget);
      expect(find.byKey(const Key('staff-message')), findsOneWidget);
      expect(find.textContaining('Lakshmi can now sign in'), findsOneWidget);
    });

    testWidgets('they can actually sign in with the PIN given',
        (tester) async {
      await show(tester);

      await tester.enterText(
        find.byKey(const Key('add-staff-name')),
        'Lakshmi',
      );
      await tester.enterText(find.byKey(const Key('add-staff-pin')), '9753');
      await tester.enterText(
        find.byKey(const Key('add-staff-pin-confirm')),
        '9753',
      );
      await tester.tap(find.byKey(const Key('add-staff-save')));
      await tester.pumpAndSettle();

      final added = await (db.select(db.users)
            ..where((u) => u.name.equals('Lakshmi')))
          .getSingle();
      final r = await auth().signIn(userId: added.id, pin: '9753');
      expect(r.ok, isTrue);
    });

    testWidgets('two PINs that differ are refused, and nobody is added',
        (tester) async {
      await show(tester);

      await tester.enterText(
        find.byKey(const Key('add-staff-name')),
        'Lakshmi',
      );
      await tester.enterText(find.byKey(const Key('add-staff-pin')), '9753');
      await tester.enterText(
        find.byKey(const Key('add-staff-pin-confirm')),
        '9754',
      );
      await tester.tap(find.byKey(const Key('add-staff-save')));
      await tester.pumpAndSettle();

      expect(find.text('The two PINs do not match.'), findsOneWidget);
      expect(await db.select(db.users).get(), hasLength(2));
    });

    testWidgets('a weak PIN is refused in the repository, and said plainly',
        (tester) async {
      await show(tester);

      await tester.enterText(
        find.byKey(const Key('add-staff-name')),
        'Lakshmi',
      );
      await tester.enterText(find.byKey(const Key('add-staff-pin')), '1234');
      await tester.enterText(
        find.byKey(const Key('add-staff-pin-confirm')),
        '1234',
      );
      await tester.tap(find.byKey(const Key('add-staff-save')));
      await tester.pumpAndSettle();

      expect(
        find.text('Pick a PIN that is not four digits in a row.'),
        findsOneWidget,
      );
      expect(await db.select(db.users).get(), hasLength(2));
    });

    testWidgets('a nameless user is refused', (tester) async {
      await show(tester);

      await tester.enterText(find.byKey(const Key('add-staff-pin')), '9753');
      await tester.enterText(
        find.byKey(const Key('add-staff-pin-confirm')),
        '9753',
      );
      await tester.tap(find.byKey(const Key('add-staff-save')));
      await tester.pumpAndSettle();

      expect(find.text('A user needs a name.'), findsOneWidget);
      expect(await db.select(db.users).get(), hasLength(2));
    });

    testWidgets('an owner can be added, for the second-owner way back',
        (tester) async {
      await show(tester);

      await tester.enterText(
        find.byKey(const Key('add-staff-name')),
        'Padma',
      );
      await tester.tap(find.byKey(const Key('add-staff-role-owner')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('add-staff-pin')), '9753');
      await tester.enterText(
        find.byKey(const Key('add-staff-pin-confirm')),
        '9753',
      );
      await tester.tap(find.byKey(const Key('add-staff-save')));
      await tester.pumpAndSettle();

      final added = await (db.select(db.users)
            ..where((u) => u.name.equals('Padma')))
          .getSingle();
      expect(added.role, UserRole.owner);
    });
  });

  group('your own row', () {
    testWidgets('has no Remove and no Reset PIN', (tester) async {
      await show(tester);

      expect(find.byKey(Key('deactivate-$ownerId')), findsNothing);
      expect(find.byKey(Key('reset-pin-$ownerId')), findsNothing);
      expect(find.byKey(Key('deactivate-$staffId')), findsOneWidget);
    });

    testWidgets('says where to change your own PIN instead', (tester) async {
      await show(tester);
      expect(find.textContaining('My PIN'), findsOneWidget);
    });
  });

  group('removing someone', () {
    testWidgets('the last owner cannot be removed', (tester) async {
      // Signed in as the cashier would hide the button, so add a second owner
      // and view it as them: the first owner is then removable, and once one
      // is gone the other is not.
      final second = await SetupRepository(db).addUser(
        name: 'Padma',
        role: UserRole.owner,
        pin: '9753',
        byUserId: ownerId,
      );
      await SetupRepository(db)
          .deactivateUser(userId: ownerId, byUserId: second);

      await pumpScreen(
        tester,
        db: db,
        child: const StaffScreen(),
        before: (c) => c.read(sessionProvider.notifier).signIn(Session(
              userId: staffId,
              name: 'Kiran',
              role: UserRole.owner,
              startedAt: DateTime(2026, 11, 9),
            )),
      );
      await tester.pumpAndSettle();

      final button = tester.widget<OutlinedButton>(
        find.byKey(Key('deactivate-$second')),
      );
      expect(button.onPressed, isNull, reason: 'the last owner is protected');
      expect(
        find.textContaining('The last owner cannot be removed'),
        findsOneWidget,
      );
    });

    testWidgets('a cashier moves to the former staff list, and comes back',
        (tester) async {
      await show(tester);

      await tester.tap(find.byKey(Key('deactivate-$staffId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();

      expect((await user(staffId)).isActive, isFalse);
      expect(find.text('No longer working here'), findsOneWidget);
      expect(find.byKey(Key('gone-$staffId')), findsOneWidget);

      await tester.tap(find.byKey(Key('reactivate-$staffId')));
      await tester.pumpAndSettle();

      expect((await user(staffId)).isActive, isTrue);
      expect(find.byKey(Key('staff-$staffId')), findsOneWidget);
      expect(find.byKey(Key('gone-$staffId')), findsNothing);
    });

    testWidgets('backing out of the confirmation changes nothing',
        (tester) async {
      await show(tester);

      await tester.tap(find.byKey(Key('deactivate-$staffId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep them'));
      await tester.pumpAndSettle();

      expect((await user(staffId)).isActive, isTrue);
    });
  });

  group('resetting a PIN', () {
    Future<void> openReset(WidgetTester tester) async {
      await tester.tap(find.byKey(Key('reset-pin-$staffId')));
      await tester.pumpAndSettle();
    }

    testWidgets('the owner PIN is required, and a wrong one changes nothing',
        (tester) async {
      await show(tester);
      await openReset(tester);

      await tester.enterText(
        find.byKey(const Key('reset-pin-field')),
        '9753',
      );
      await tester.enterText(
        find.byKey(const Key('reset-pin-confirm-field')),
        '9753',
      );
      await tester.enterText(
        find.byKey(const Key('reset-pin-owner-field')),
        '0000',
      );
      await tester.tap(find.byKey(const Key('reset-pin-save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('That is not your PIN'), findsOneWidget);

      // The old PIN still works, the new one does not.
      expect((await auth().signIn(userId: staffId, pin: staffPin)).ok, isTrue);
      expect((await auth().signIn(userId: staffId, pin: '9753')).ok, isFalse);
    });

    testWidgets('the right owner PIN sets the new one', (tester) async {
      await show(tester);
      await openReset(tester);

      await tester.enterText(
        find.byKey(const Key('reset-pin-field')),
        '9753',
      );
      await tester.enterText(
        find.byKey(const Key('reset-pin-confirm-field')),
        '9753',
      );
      await tester.enterText(
        find.byKey(const Key('reset-pin-owner-field')),
        ownerPin,
      );
      await tester.tap(find.byKey(const Key('reset-pin-save')));
      await tester.pumpAndSettle();

      expect((await auth().signIn(userId: staffId, pin: '9753')).ok, isTrue);
    });

    testWidgets('two new PINs that differ are caught before anything happens',
        (tester) async {
      await show(tester);
      await openReset(tester);

      await tester.enterText(
        find.byKey(const Key('reset-pin-field')),
        '9753',
      );
      await tester.enterText(
        find.byKey(const Key('reset-pin-confirm-field')),
        '9754',
      );
      await tester.tap(find.byKey(const Key('reset-pin-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reset-pin-problem')), findsOneWidget);
      // Still on the dialog, so the owner PIN was never even read.
      expect(find.byKey(const Key('reset-pin-owner-field')), findsOneWidget);
      expect((await auth().signIn(userId: staffId, pin: staffPin)).ok, isTrue);
    });

    testWidgets('a weak new PIN is refused by the repository',
        (tester) async {
      await show(tester);
      await openReset(tester);

      await tester.enterText(
        find.byKey(const Key('reset-pin-field')),
        '1111',
      );
      await tester.enterText(
        find.byKey(const Key('reset-pin-confirm-field')),
        '1111',
      );
      await tester.enterText(
        find.byKey(const Key('reset-pin-owner-field')),
        ownerPin,
      );
      await tester.tap(find.byKey(const Key('reset-pin-save')));
      await tester.pumpAndSettle();

      expect(
        find.text('Pick a PIN that is not the same digit four times.'),
        findsOneWidget,
      );
      expect((await auth().signIn(userId: staffId, pin: staffPin)).ok, isTrue);
    });
  });

  group('My PIN', () {
    Future<void> openMyPin(WidgetTester tester, {required UserRole as}) async {
      await pumpScreen(
        tester,
        db: db,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showChangePinDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        before: (c) => c.read(sessionProvider.notifier).signIn(Session(
              userId: as == UserRole.owner ? ownerId : staffId,
              name: as == UserRole.owner ? 'Ravi' : 'Kiran',
              role: as,
              startedAt: DateTime(2026, 11, 9),
            )),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a cashier changes their own PIN', (tester) async {
      // The reason this exists: otherwise the owner knows every cashier's PIN
      // and can ring up sales as them.
      await openMyPin(tester, as: UserRole.staff);

      await tester.enterText(
        find.byKey(const Key('current-pin-field')),
        staffPin,
      );
      await tester.enterText(find.byKey(const Key('new-pin-field')), '9753');
      await tester.enterText(
        find.byKey(const Key('new-pin-confirm-field')),
        '9753',
      );
      await tester.tap(find.byKey(const Key('change-pin-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('change-pin-done')), findsOneWidget);
      expect((await auth().signIn(userId: staffId, pin: '9753')).ok, isTrue);
      expect((await auth().signIn(userId: staffId, pin: staffPin)).ok, isFalse);
    });

    testWidgets('the wrong current PIN is refused and changes nothing',
        (tester) async {
      await openMyPin(tester, as: UserRole.staff);

      await tester.enterText(
        find.byKey(const Key('current-pin-field')),
        '0000',
      );
      await tester.enterText(find.byKey(const Key('new-pin-field')), '9753');
      await tester.enterText(
        find.byKey(const Key('new-pin-confirm-field')),
        '9753',
      );
      await tester.tap(find.byKey(const Key('change-pin-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('change-pin-problem')), findsOneWidget);
      expect((await auth().signIn(userId: staffId, pin: staffPin)).ok, isTrue);
    });

    testWidgets('two new PINs that differ are caught', (tester) async {
      await openMyPin(tester, as: UserRole.staff);

      await tester.enterText(
        find.byKey(const Key('current-pin-field')),
        staffPin,
      );
      await tester.enterText(find.byKey(const Key('new-pin-field')), '9753');
      await tester.enterText(
        find.byKey(const Key('new-pin-confirm-field')),
        '9754',
      );
      await tester.tap(find.byKey(const Key('change-pin-save')));
      await tester.pumpAndSettle();

      expect(find.text('The two new PINs do not match.'), findsOneWidget);
      expect((await auth().signIn(userId: staffId, pin: staffPin)).ok, isTrue);
    });
  });

  group('where My PIN lives', () {
    Future<void> showSettings(
      WidgetTester tester, {
      required UserRole role,
    }) async {
      await pumpScreen(
        tester,
        db: db,
        child: const PrinterSettingsScreen(),
        before: (c) => c.read(sessionProvider.notifier).signIn(Session(
              userId: role == UserRole.owner ? ownerId : staffId,
              name: role == UserRole.owner ? 'Ravi' : 'Kiran',
              role: role,
              startedAt: DateTime(2026, 11, 9),
            )),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the owner finds it in Settings', (tester) async {
      await showSettings(tester, role: UserRole.owner);

      expect(find.byKey(const Key('open-my-pin')), findsOneWidget);
      // And the rest of Settings is still there.
      expect(find.byKey(const Key('open-staff')), findsOneWidget);
      expect(find.byKey(const Key('open-backup')), findsOneWidget);
    });

    testWidgets('a cashier finds it in Settings too, and nothing else',
        (tester) async {
      // A cashier given a PIN by the owner has to be able to change it, or
      // the owner knows it and the name on each bill means nothing.
      await showSettings(tester, role: UserRole.staff);

      expect(find.byKey(const Key('open-my-pin')), findsOneWidget);
      expect(find.byKey(const Key('open-staff')), findsNothing);
      expect(find.byKey(const Key('open-backup')), findsNothing);
      expect(find.byKey(const Key('print-test')), findsNothing);
      expect(find.byKey(const Key('fssai-field')), findsNothing);
    });

    testWidgets('a cashier can actually change their PIN from there',
        (tester) async {
      await showSettings(tester, role: UserRole.staff);

      await tester.tap(find.byKey(const Key('open-my-pin')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('current-pin-field')),
        staffPin,
      );
      await tester.enterText(find.byKey(const Key('new-pin-field')), '9753');
      await tester.enterText(
        find.byKey(const Key('new-pin-confirm-field')),
        '9753',
      );
      await tester.tap(find.byKey(const Key('change-pin-save')));
      await tester.pumpAndSettle();

      expect((await auth().signIn(userId: staffId, pin: '9753')).ok, isTrue);
    });
  });

  group('layout', () {
    testWidgets('it fits a 390px phone without overflowing', (tester) async {
      await show(tester, size: const Size(390, 844));
      expect(tester.takeException(), isNull);
    });

    testWidgets('every tappable thing is at least 44px', (tester) async {
      await show(tester, size: const Size(390, 844));

      for (final element in find.byType(OutlinedButton).evaluate()) {
        final size = element.size!;
        expect(
          size.height,
          greaterThanOrEqualTo(44),
          reason: 'a button at ${size.width}x${size.height} is too short',
        );
      }
    });
  });
}
