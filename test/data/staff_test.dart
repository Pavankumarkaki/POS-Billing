/// Managing staff: the owner's PIN reset, and bringing someone back.
///
/// Both methods are new in phase 2, and both exist because phase 1 left a
/// one-way door. `changePin` needs the PIN that has been forgotten, so a
/// forgotten PIN meant a reinstall; `deactivateUser` had no counterpart, so a
/// mistaken removal was permanent.
///
/// The rules worth protecting here are the ones that would hand out access by
/// accident: who may reset a PIN, whose PIN they may not reset, and that
/// nothing about a PIN reaches the audit log.
library;

// drift exports isNull/isNotNull as SQL expression helpers, which collide
// with flutter_test's matchers of the same name.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/pin.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/setup_repository.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late AuthRepository auth;
  late SetupRepository setup;

  const ownerPin = '1357';
  const staffPin = '2468';

  setUp(() async {
    f = await Fixture.create();
    auth = AuthRepository(f.db, deviceId: kDeviceId);
    setup = SetupRepository(f.db);

    // The fixture stores a placeholder hash, so give the users real PINs.
    await (f.db.update(f.db.users)..where((u) => u.id.equals(kOwnerId)))
        .write(UsersCompanion(pinHash: Value(hashPin(ownerPin))));
    await (f.db.update(f.db.users)..where((u) => u.id.equals(kStaffId)))
        .write(UsersCompanion(pinHash: Value(hashPin(staffPin))));
  });

  tearDown(() => f.close());

  Future<UserRow> user(String id) =>
      (f.db.select(f.db.users)..where((u) => u.id.equals(id))).getSingle();

  Future<List<AuditRow>> audit() => f.db.select(f.db.auditLog).get();

  group('resetting a PIN', () {
    test('the owner sets a new one, and it works', () async {
      await auth.resetPin(
        userId: kStaffId,
        newPin: '9753',
        byUserId: kOwnerId,
      );

      final r = await auth.signIn(userId: kStaffId, pin: '9753');
      expect(r.ok, isTrue);
    });

    test('the old PIN stops working', () async {
      await auth.resetPin(
        userId: kStaffId,
        newPin: '9753',
        byUserId: kOwnerId,
      );

      final r = await auth.signIn(userId: kStaffId, pin: staffPin);
      expect(r.ok, isFalse);
    });

    test('it clears the lockout, so the new PIN works straight away',
        () async {
      // Lock them out the way a forgotten PIN actually does it: by guessing.
      for (var i = 0; i < 5; i++) {
        await auth.signIn(userId: kStaffId, pin: '0000');
      }
      final lockedOut = await user(kStaffId);
      expect(lockedOut.lockedUntil, isNotNull,
          reason: 'the test needs them actually locked out');

      await auth.resetPin(
        userId: kStaffId,
        newPin: '9753',
        byUserId: kOwnerId,
      );

      final after = await user(kStaffId);
      expect(after.lockedUntil, isNull);
      expect(after.failedAttempts, 0);

      // The point of clearing it: without this the new PIN is refused too,
      // and the owner thinks the reset did not work.
      final r = await auth.signIn(userId: kStaffId, pin: '9753');
      expect(r.ok, isTrue);
    });

    test('staff cannot reset anyone', () async {
      await expectLater(
        auth.resetPin(
          userId: kOwnerId,
          newPin: '9753',
          byUserId: kStaffId,
        ),
        throwsA(isA<PinError>()),
      );

      // And the owner's PIN is untouched.
      final r = await auth.signIn(userId: kOwnerId, pin: ownerPin);
      expect(r.ok, isTrue);
    });

    test('the owner cannot reset their own', () async {
      // Otherwise a till left unlocked on the counter is a way to set a new
      // owner PIN and lock the owner out of their own reports.
      await expectLater(
        auth.resetPin(
          userId: kOwnerId,
          newPin: '9753',
          byUserId: kOwnerId,
        ),
        throwsA(isA<PinError>()),
      );

      final r = await auth.signIn(userId: kOwnerId, pin: ownerPin);
      expect(r.ok, isTrue);
    });

    test('a second owner can reset the first owner, which is the way back',
        () async {
      final second = await setup.addUser(
        name: 'Second Owner',
        role: UserRole.owner,
        pin: '8642',
        byUserId: kOwnerId,
      );

      await auth.resetPin(
        userId: kOwnerId,
        newPin: '9753',
        byUserId: second,
      );

      final r = await auth.signIn(userId: kOwnerId, pin: '9753');
      expect(r.ok, isTrue);
    });

    test('a weak PIN is refused, and the old one still works', () async {
      for (final weak in ['1111', '1234', '12', 'abcd']) {
        await expectLater(
          auth.resetPin(
            userId: kStaffId,
            newPin: weak,
            byUserId: kOwnerId,
          ),
          throwsA(isA<PinError>()),
          reason: '$weak should be refused',
        );
      }

      final r = await auth.signIn(userId: kStaffId, pin: staffPin);
      expect(r.ok, isTrue);
    });

    test('an unknown user is refused', () async {
      await expectLater(
        auth.resetPin(
          userId: 'nobody',
          newPin: '9753',
          byUserId: kOwnerId,
        ),
        throwsA(isA<PinError>()),
      );
    });

    test('no PIN and no hash reaches the audit log', () async {
      await auth.resetPin(
        userId: kStaffId,
        newPin: '9753',
        byUserId: kOwnerId,
      );

      final stored = await user(kStaffId);
      final rows = await audit();
      final text = rows
          .map((r) => '${r.action.wireName} ${r.before ?? ''} ${r.after ?? ''}')
          .join('\n');

      expect(text, isNot(contains('9753')));
      expect(text, isNot(contains(stored.pinHash)));
    });

    test('it is logged against the owner who did it, for the staff member',
        () async {
      await auth.resetPin(
        userId: kStaffId,
        newPin: '9753',
        byUserId: kOwnerId,
      );

      final row = (await audit())
          .firstWhere((r) => r.action == AuditAction.pinChanged);
      expect(row.userId, kOwnerId, reason: 'who did it');
      expect(row.entityId, kStaffId, reason: 'who it was done to');
    });
  });

  group('bringing someone back', () {
    setUp(() async {
      await setup.deactivateUser(userId: kStaffId, byUserId: kOwnerId);
    });

    test('they can sign in again, with the PIN they had', () async {
      final whileGone = await auth.signIn(userId: kStaffId, pin: staffPin);
      expect(whileGone.ok, isFalse,
          reason: 'a deactivated user must not get in');

      await setup.reactivateUser(userId: kStaffId, byUserId: kOwnerId);

      final r = await auth.signIn(userId: kStaffId, pin: staffPin);
      expect(r.ok, isTrue);
    });

    test('they are offered on the login screen again', () async {
      expect(
        (await auth.activeUsers()).map((u) => u.id),
        isNot(contains(kStaffId)),
      );

      await setup.reactivateUser(userId: kStaffId, byUserId: kOwnerId);

      expect(
        (await auth.activeUsers()).map((u) => u.id),
        contains(kStaffId),
      );
    });

    test('staff cannot bring anyone back', () async {
      // Reactivated by one cashier, a removed cashier would be a way around
      // the owner entirely.
      final other = await setup.addUser(
        name: 'Other Cashier',
        role: UserRole.staff,
        pin: '8642',
        byUserId: kOwnerId,
      );

      await expectLater(
        setup.reactivateUser(userId: kStaffId, byUserId: other),
        throwsA(isA<SetupError>()),
      );

      expect((await user(kStaffId)).isActive, isFalse);
    });

    test('an unknown user is refused', () async {
      await expectLater(
        setup.reactivateUser(userId: 'nobody', byUserId: kOwnerId),
        throwsA(isA<SetupError>()),
      );
    });

    test('it is logged, with the change both ways round', () async {
      await setup.reactivateUser(userId: kStaffId, byUserId: kOwnerId);

      final rows = (await audit())
          .where((r) =>
              r.action == AuditAction.userEdited && r.entityId == kStaffId)
          .toList();

      // The deactivation from setUp, then the reactivation.
      expect(rows.length, 2);
      expect(rows.last.before, contains('false'));
      expect(rows.last.after, contains('true'));
      expect(rows.last.userId, kOwnerId);
    });

    test('it does not quietly change their PIN', () async {
      final before = (await user(kStaffId)).pinHash;
      await setup.reactivateUser(userId: kStaffId, byUserId: kOwnerId);
      expect((await user(kStaffId)).pinHash, before);
    });
  });

  group('the staff list', () {
    test('includes deactivated users, active ones first', () async {
      await setup.deactivateUser(userId: kStaffId, byUserId: kOwnerId);

      final staff = await auth.watchStaff().first;

      expect(staff.map((u) => u.id), containsAll([kOwnerId, kStaffId]));
      expect(staff.first.id, kOwnerId, reason: 'active first');
      expect(staff.last.id, kStaffId, reason: 'deactivated last');
    });

    test('updates when someone is added, without being asked again',
        () async {
      // The screen that lists staff is the screen that adds them, so this
      // has to be live. A cached future is what once hid a saved bill from
      // the Bills tab until a restart.
      final seen = <int>[];
      final sub = auth.watchStaff().listen((rows) => seen.add(rows.length));
      await pumpEventQueue();

      await setup.addUser(
        name: 'New Cashier',
        role: UserRole.staff,
        pin: '8642',
        byUserId: kOwnerId,
      );
      await pumpEventQueue();
      await sub.cancel();

      expect(seen.first, 2);
      expect(seen.last, 3);
    });
  });
}
