/// Signing in, the lockout surviving a restart, and the audit trail.
library;

import 'dart:convert';

// drift exports isNull/isNotNull as SQL expression helpers, which collide
// with flutter_test's matchers of the same name.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/pin.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/db.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late AuthRepository auth;

  /// A PIN the fixture's users do not have, set explicitly per test.
  const ownerPin = '1357';
  const staffPin = '2468';

  setUp(() async {
    f = await Fixture.create();
    auth = AuthRepository(f.db, deviceId: kDeviceId);

    // The fixture stores a placeholder hash, so give the users real PINs.
    await (f.db.update(f.db.users)..where((u) => u.id.equals(kOwnerId)))
        .write(UsersCompanion(pinHash: Value(hashPin(ownerPin))));
    await (f.db.update(f.db.users)..where((u) => u.id.equals(kStaffId)))
        .write(UsersCompanion(pinHash: Value(hashPin(staffPin))));
  });

  tearDown(() => f.close());

  group('signing in', () {
    test('the right PIN works', () async {
      final r = await auth.signIn(userId: kOwnerId, pin: ownerPin);
      expect(r.ok, isTrue);
      expect(r.userId, kOwnerId);
      expect(r.name, 'Owner');
      expect(r.role, UserRole.owner);
    });

    test('the wrong PIN does not, and says how many tries are left', () async {
      final r = await auth.signIn(userId: kOwnerId, pin: '9999');
      expect(r.ok, isFalse);
      expect(r.failure, LoginFailure.wrongPin);
      expect(r.attemptsRemaining, 4);
    });

    test('one user cannot sign in with another user PIN', () async {
      final r = await auth.signIn(userId: kOwnerId, pin: staffPin);
      expect(r.ok, isFalse);
    });

    test('an unknown user fails without revealing anything', () async {
      final r = await auth.signIn(userId: 'nobody', pin: ownerPin);
      expect(r.ok, isFalse);
      expect(r.failure, LoginFailure.unknownUser);
      expect(r.attemptsRemaining, isNull,
          reason: 'must not hint that the user does not exist');
    });

    test('a deactivated user cannot sign in', () async {
      await (f.db.update(f.db.users)..where((u) => u.id.equals(kStaffId)))
          .write(const UsersCompanion(isActive: Value(false)));
      final r = await auth.signIn(userId: kStaffId, pin: staffPin);
      expect(r.ok, isFalse);
      expect(r.failure, LoginFailure.unknownUser,
          reason: 'same answer as a missing user, so neither is revealed');
    });

    test('a deactivated user is not offered on the login screen', () async {
      expect(await auth.activeUsers(), hasLength(2));
      await (f.db.update(f.db.users)..where((u) => u.id.equals(kStaffId)))
          .write(const UsersCompanion(isActive: Value(false)));
      final users = await auth.activeUsers();
      expect(users, hasLength(1));
      expect(users.single.id, kOwnerId);
    });

    test('the session carries the role, so permissions can be checked',
        () async {
      final r = await auth.signIn(userId: kStaffId, pin: staffPin);
      final session = Session(
        userId: r.userId!,
        name: r.name!,
        role: r.role!,
        startedAt: DateTime(2026, 6, 1),
      );
      expect(session.can(Permission.createBill), isTrue);
      expect(session.can(Permission.cancelBill), isFalse);
      expect(session.can(Permission.viewReports), isFalse);
    });
  });

  group('the lockout', () {
    final t0 = DateTime(2026, 6, 1, 13, 0);

    Future<LoginResult> wrong([DateTime? at]) =>
        auth.signIn(userId: kOwnerId, pin: '9999', at: at ?? t0);

    test('counts down and then locks on the fifth failure', () async {
      for (var i = 1; i <= 4; i++) {
        final r = await wrong();
        expect(r.failure, LoginFailure.wrongPin, reason: 'attempt $i');
        expect(r.attemptsRemaining, 5 - i);
      }
      final fifth = await wrong();
      expect(fifth.failure, LoginFailure.lockedOut);
      expect(fifth.lockedFor, kFirstLockout);
    });

    test('a correct PIN is refused while locked', () async {
      for (var i = 0; i < 5; i++) {
        await wrong();
      }
      final r = await auth.signIn(userId: kOwnerId, pin: ownerPin, at: t0);
      expect(r.ok, isFalse);
      expect(r.failure, LoginFailure.lockedOut,
          reason: 'the PIN must not even be checked while locked');
    });

    test('it expires, and the right PIN then works', () async {
      for (var i = 0; i < 5; i++) {
        await wrong();
      }
      final later = t0.add(const Duration(seconds: 61));
      final r = await auth.signIn(userId: kOwnerId, pin: ownerPin, at: later);
      expect(r.ok, isTrue);
    });

    test('a success clears the counter', () async {
      await wrong();
      await wrong();
      await auth.signIn(userId: kOwnerId, pin: ownerPin, at: t0);

      final row = await (f.db.select(f.db.users)
            ..where((u) => u.id.equals(kOwnerId)))
          .getSingle();
      expect(row.failedAttempts, 0);
      expect(row.lockedUntil, isNull);
    });

    test('the lockout survives an app restart', () async {
      // This is the whole point of storing it rather than keeping it in memory:
      // otherwise killing the app would reset the counter after every guess.
      for (var i = 0; i < 5; i++) {
        await wrong();
      }

      // A new repository, as if the app had been restarted.
      final restarted = AuthRepository(f.db, deviceId: kDeviceId);
      final r = await restarted.signIn(
        userId: kOwnerId,
        pin: ownerPin,
        at: t0.add(const Duration(seconds: 1)),
      );
      expect(r.ok, isFalse);
      expect(r.failure, LoginFailure.lockedOut);
    });

    test('trying again while locked does not extend the lockout', () async {
      for (var i = 0; i < 5; i++) {
        await wrong();
      }
      final first = await wrong();
      expect(first.lockedFor, kFirstLockout);

      // Ten more taps during the lockout.
      for (var i = 0; i < 10; i++) {
        await wrong();
      }
      final after = await wrong();
      expect(
        after.lockedFor,
        kFirstLockout,
        reason: 'otherwise a hand resting on the screen locks the till for '
            'hours, and a locked PIN is never checked anyway',
      );

      final row = await (f.db.select(f.db.users)
            ..where((u) => u.id.equals(kOwnerId)))
          .getSingle();
      expect(row.failedAttempts, 5,
          reason: 'attempts during a lockout do not count');
    });

    test('it lengthens with each failure AFTER the lock expires', () async {
      var t = t0;
      for (var i = 0; i < 5; i++) {
        await wrong(t);
      }
      expect((await wrong(t)).lockedFor, const Duration(seconds: 60));

      // Wait it out, then get it wrong again.
      t = t.add(const Duration(seconds: 61));
      expect((await wrong(t)).lockedFor, const Duration(seconds: 120));

      t = t.add(const Duration(seconds: 121));
      expect((await wrong(t)).lockedFor, const Duration(seconds: 240));

      t = t.add(const Duration(seconds: 241));
      expect((await wrong(t)).lockedFor, const Duration(seconds: 480));
    });

    test('it is capped, so the till cannot be bricked by a stray hand',
        () async {
      var t = t0;
      // Fail, wait out the lock, fail again, over and over.
      for (var i = 0; i < 5; i++) {
        await wrong(t);
      }
      var locked = (await wrong(t)).lockedFor!;
      for (var i = 0; i < 12; i++) {
        t = t.add(locked + const Duration(seconds: 1));
        locked = (await wrong(t)).lockedFor!;
        expect(locked, lessThanOrEqualTo(kMaxLockout), reason: 'round $i');
      }
      expect(locked, kMaxLockout, reason: 'it reaches the cap and stops');
    });

    test('one user locking out does not lock the other', () async {
      for (var i = 0; i < 6; i++) {
        await wrong();
      }
      final staff = await auth.signIn(
        userId: kStaffId,
        pin: staffPin,
        at: t0,
      );
      expect(staff.ok, isTrue, reason: 'the restaurant must still be able to bill');
    });

    test('the owner can clear a lockout', () async {
      for (var i = 0; i < 5; i++) {
        await auth.signIn(userId: kStaffId, pin: '9999', at: t0);
      }
      expect(
        (await auth.signIn(userId: kStaffId, pin: staffPin, at: t0)).ok,
        isFalse,
      );

      await auth.clearLockout(
        userId: kStaffId,
        byUserId: kOwnerId,
        at: t0,
      );

      final r = await auth.signIn(userId: kStaffId, pin: staffPin, at: t0);
      expect(r.ok, isTrue);
    });

    test('staff cannot clear a lockout', () async {
      await expectLater(
        auth.clearLockout(userId: kOwnerId, byUserId: kStaffId),
        throwsA(isA<PinError>()),
      );
    });
  });

  group('the audit trail', () {
    final t0 = DateTime(2026, 6, 1, 13, 0);

    test('a failed sign-in is logged', () async {
      await auth.signIn(userId: kOwnerId, pin: '9999', at: t0);

      final entries = await (f.db.select(f.db.auditLog)
            ..where((a) => a.action.equals(AuditAction.loginFailed.wireName)))
          .get();
      expect(entries, hasLength(1));
      expect(entries.single.userId, kOwnerId);
      expect(entries.single.deviceId, kDeviceId);
    });

    test('a lockout is logged separately from the failure', () async {
      for (var i = 0; i < 5; i++) {
        await auth.signIn(userId: kOwnerId, pin: '9999', at: t0);
      }

      final failures = await (f.db.select(f.db.auditLog)
            ..where((a) => a.action.equals(AuditAction.loginFailed.wireName)))
          .get();
      final lockouts = await (f.db.select(f.db.auditLog)
            ..where((a) => a.action.equals(AuditAction.lockedOut.wireName)))
          .get();

      expect(failures, hasLength(5));
      expect(lockouts, hasLength(1));
      final after = jsonDecode(lockouts.single.after!) as Map<String, Object?>;
      expect(after['after_attempts'], 5);
      expect(after['locked_until'], isNotNull);
    });

    test('a successful sign-in is not logged as a failure', () async {
      await auth.signIn(userId: kOwnerId, pin: ownerPin, at: t0);
      final entries = await (f.db.select(f.db.auditLog)
            ..where((a) => a.action.equals(AuditAction.loginFailed.wireName)))
          .get();
      expect(entries, isEmpty);
    });

    test('no PIN or hash ever reaches the audit log', () async {
      await auth.signIn(userId: kOwnerId, pin: '9999', at: t0);
      await auth.changePin(
        userId: kOwnerId,
        currentPin: ownerPin,
        newPin: '4716',
        at: t0,
      );

      final rows = await f.db.select(f.db.auditLog).get();
      final blob = rows
          .map((r) => '${r.before ?? ''}${r.after ?? ''}')
          .join('\n');

      expect(blob.contains('9999'), isFalse);
      expect(blob.contains('1357'), isFalse);
      expect(blob.contains('4716'), isFalse);
      expect(blob.contains('pbkdf2'), isFalse,
          reason: 'not even the hash belongs in the log');
    });
  });

  group('changing a PIN', () {
    test('works with the current PIN, and the new one then signs in', () async {
      await auth.changePin(
        userId: kOwnerId,
        currentPin: ownerPin,
        newPin: '4716',
      );

      expect((await auth.signIn(userId: kOwnerId, pin: '4716')).ok, isTrue);
      expect((await auth.signIn(userId: kOwnerId, pin: ownerPin)).ok, isFalse);
    });

    test('is refused without the current PIN', () async {
      await expectLater(
        auth.changePin(
          userId: kOwnerId,
          currentPin: '0000',
          newPin: '4716',
        ),
        throwsA(isA<PinError>()),
      );
      expect((await auth.signIn(userId: kOwnerId, pin: ownerPin)).ok, isTrue,
          reason: 'the old PIN still works');
    });

    test('a weak new PIN is refused', () async {
      for (final weak in ['1111', '1234', '12', 'abcd']) {
        await expectLater(
          auth.changePin(
            userId: kOwnerId,
            currentPin: ownerPin,
            newPin: weak,
          ),
          throwsA(isA<PinError>()),
          reason: weak,
        );
      }
    });

    test('it is logged', () async {
      await auth.changePin(
        userId: kOwnerId,
        currentPin: ownerPin,
        newPin: '4716',
      );
      final entries = await (f.db.select(f.db.auditLog)
            ..where((a) => a.action.equals(AuditAction.pinChanged.wireName)))
          .get();
      expect(entries, hasLength(1));
    });
  });

  group('confirming a PIN for a privileged action', () {
    test('the right PIN confirms', () async {
      expect(
        await auth.confirmPin(userId: kOwnerId, pin: ownerPin),
        isTrue,
      );
    });

    test('the wrong one does not, and counts towards the lockout', () async {
      final t0 = DateTime(2026, 6, 1, 13, 0);
      for (var i = 0; i < 5; i++) {
        await auth.confirmPin(userId: kOwnerId, pin: '9999', at: t0);
      }
      // Otherwise the cancel dialog would be a free PIN oracle.
      final r = await auth.signIn(userId: kOwnerId, pin: ownerPin, at: t0);
      expect(r.failure, LoginFailure.lockedOut);
    });
  });
}
