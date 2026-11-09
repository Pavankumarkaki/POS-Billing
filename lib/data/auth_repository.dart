/// Signing in, the lockout, and the audit trail for both.
///
/// The PIN arithmetic lives in `core/pin.dart` and knows nothing about the
/// database. This file is the part that persists it: it reads the user row,
/// asks core whether the PIN and the lockout allow a sign-in, writes the new
/// lockout state back, and records what happened.
///
/// Failures are logged as carefully as successes. If someone stands at the till
/// guessing the owner's PIN, the audit log is where that shows up.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/domain.dart';
import '../core/pin.dart';
import 'db.dart';

/// Why a sign-in did not succeed.
enum LoginFailure {
  /// No such user, or they have been deactivated. Deliberately one case: the
  /// screen must not reveal which, or it leaks who exists.
  unknownUser,

  /// Wrong PIN, and attempts remain.
  wrongPin,

  /// Locked out. [LoginResult.lockedFor] says for how long.
  lockedOut,
}

/// What a sign-in attempt produced.
class LoginResult {
  const LoginResult._({
    required this.ok,
    this.userId,
    this.name,
    this.role,
    this.failure,
    this.attemptsRemaining,
    this.lockedFor,
  });

  factory LoginResult.success({
    required String userId,
    required String name,
    required UserRole role,
  }) =>
      LoginResult._(ok: true, userId: userId, name: name, role: role);

  factory LoginResult.wrongPin({required int attemptsRemaining}) =>
      LoginResult._(
        ok: false,
        failure: LoginFailure.wrongPin,
        attemptsRemaining: attemptsRemaining,
      );

  factory LoginResult.lockedOut(Duration lockedFor) => LoginResult._(
        ok: false,
        failure: LoginFailure.lockedOut,
        lockedFor: lockedFor,
      );

  factory LoginResult.unknownUser() =>
      const LoginResult._(ok: false, failure: LoginFailure.unknownUser);

  final bool ok;
  final String? userId;
  final String? name;
  final UserRole? role;
  final LoginFailure? failure;

  /// How many tries are left before a lockout. Null unless [failure] is
  /// [LoginFailure.wrongPin].
  final int? attemptsRemaining;

  /// How long the lockout has left to run.
  final Duration? lockedFor;
}

/// Someone signed in. Held in memory only: closing the app signs you out,
/// which is what you want on a till left on a counter.
class Session {
  const Session({
    required this.userId,
    required this.name,
    required this.role,
    required this.startedAt,
  });

  final String userId;
  final String name;
  final UserRole role;
  final DateTime startedAt;

  bool can(Permission permission) => permission.allows(role);
}

class AuthRepository {
  AuthRepository(
    this._db, {
    required this.deviceId,
    Uuid? uuid,
    DateTime Function()? clock,
  })  : _uuid = uuid ?? const Uuid(),
        _clock = clock ?? DateTime.now;

  final PosDatabase _db;
  /// The device these sign-ins happen on, recorded in the audit log.
  final String deviceId;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// Everyone who may be shown on the login screen.
  Future<List<UserRow>> activeUsers() => (_db.select(_db.users)
        ..where((u) => u.isActive.equals(true))
        ..orderBy([(u) => OrderingTerm.asc(u.name)]))
      .get();

  /// Everyone for the staff screen, deactivated users included, active first.
  ///
  /// A stream rather than a future because the screen that lists staff is the
  /// screen that adds and deactivates them. A cached future left a saved bill
  /// invisible in the Bills tab until a restart once already, and this is the
  /// same shape of mistake.
  Stream<List<UserRow>> watchStaff() => (_db.select(_db.users)
        ..orderBy([
          (u) => OrderingTerm.desc(u.isActive),
          (u) => OrderingTerm.asc(u.name),
        ]))
      .watch();

  /// Attempts a sign-in.
  ///
  /// The whole thing is one transaction, so the lockout counter cannot be lost
  /// by a crash between checking the PIN and writing the new count. Without
  /// that, killing the app after each wrong guess would reset the counter and
  /// the lockout would be worthless.
  Future<LoginResult> signIn({
    required String userId,
    required String pin,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    return _db.transaction(() async {
      final user = await (_db.select(_db.users)
            ..where((u) => u.id.equals(userId)))
          .getSingleOrNull();

      if (user == null || !user.isActive) {
        return LoginResult.unknownUser();
      }

      final lockout = LockoutState(
        failedAttempts: user.failedAttempts,
        lockedUntil: user.lockedUntil,
      );

      // Still locked: do not even check the PIN. Checking it would let someone
      // learn a correct PIN by timing, and would reward guessing during the
      // lockout.
      final remaining = lockout.remainingAt(now);
      if (remaining != null) {
        return LoginResult.lockedOut(remaining);
      }

      if (verifyPin(pin, user.pinHash)) {
        await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
            .write(const UsersCompanion(
          failedAttempts: Value(0),
          lockedUntil: Value(null),
        ));

        // Raise the cost of an old hash while we have the plaintext. Nothing
        // else ever gets the chance.
        if (needsRehash(user.pinHash)) {
          await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
              .write(UsersCompanion(pinHash: Value(hashPin(pin))));
        }

        return LoginResult.success(
          userId: user.id,
          name: user.name,
          role: user.role,
        );
      }

      // Wrong PIN.
      final next = lockout.afterFailure(now);
      await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
          .write(UsersCompanion(
        failedAttempts: Value(next.failedAttempts),
        lockedUntil: Value(next.lockedUntil),
      ));

      await _audit(
        action: AuditAction.loginFailed,
        userId: userId,
        at: now,
        after: {
          'failed_attempts': next.failedAttempts,
          'locked_until': next.lockedUntil?.toIso8601String(),
        },
      );

      final nowLocked = next.remainingAt(now);
      if (nowLocked != null) {
        await _audit(
          action: AuditAction.lockedOut,
          userId: userId,
          at: now,
          after: {
            'locked_until': next.lockedUntil!.toIso8601String(),
            'after_attempts': next.failedAttempts,
          },
        );
        return LoginResult.lockedOut(nowLocked);
      }

      return LoginResult.wrongPin(
        attemptsRemaining: kMaxPinAttempts - next.failedAttempts,
      );
    });
  }

  /// Re-checks a PIN without starting a session.
  ///
  /// Used where the brief requires the owner to confirm an action they are
  /// already signed in for, such as cancelling a bill. Counts towards the
  /// lockout exactly like a sign-in, because otherwise it would be a way to
  /// guess a PIN with no penalty.
  Future<bool> confirmPin({
    required String userId,
    required String pin,
    DateTime? at,
  }) async {
    final result = await signIn(userId: userId, pin: pin, at: at);
    return result.ok;
  }

  /// Changes a PIN. The old one must be given, so a till left unlocked cannot
  /// be used to lock out its owner.
  Future<void> changePin({
    required String userId,
    required String currentPin,
    required String newPin,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    final reason = pinRejectionReason(newPin);
    if (reason != null) throw PinError(reason);

    final verified = await signIn(userId: userId, pin: currentPin, at: now);
    if (!verified.ok) {
      throw PinError('The current PIN is not correct.');
    }

    await _db.transaction(() async {
      await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
          .write(UsersCompanion(pinHash: Value(hashPin(newPin))));

      // The hash itself is never logged, before or after. The audit log records
      // that a PIN changed and who did it, which is all anyone needs and all
      // that is safe to keep.
      await _audit(
        action: AuditAction.pinChanged,
        userId: userId,
        at: now,
        after: {'changed_for': userId},
      );
    });
  }

  /// Resets a PIN without knowing the old one. Owner only.
  ///
  /// The recovery path [changePin] cannot be: it requires the PIN that has
  /// been forgotten, and [clearLockout] only clears the lockout, leaving the
  /// staff member still guessing. Without this the only way back was a
  /// reinstall, which costs every bill on the device.
  ///
  /// Resetting someone else's PIN is deliberately not the same as changing
  /// your own, and this method refuses to touch the caller's own PIN. Allowing
  /// that would undo the guarantee [changePin] exists for: a till left
  /// unlocked on the counter could be used to set a new owner PIN and lock the
  /// owner out of their own reports. An owner changes their own PIN by knowing
  /// it, or another owner resets it for them, which is one of the reasons
  /// there must always be an active owner.
  ///
  /// A sole owner who forgets their own PIN still has no way in. That is the
  /// deliberate consequence of having no backdoor PIN, not an oversight.
  Future<void> resetPin({
    required String userId,
    required String newPin,
    required String byUserId,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    final reason = pinRejectionReason(newPin);
    if (reason != null) throw PinError(reason);

    await _db.transaction(() async {
      final by = await (_db.select(_db.users)
            ..where((u) => u.id.equals(byUserId)))
          .getSingleOrNull();
      if (by == null || !Permission.manageUsers.allows(by.role)) {
        throw PinError('Only the owner can reset a PIN.');
      }
      if (userId == byUserId) {
        throw PinError(
          'Change your own PIN with your current one, rather than '
          'resetting it.',
        );
      }

      final target = await (_db.select(_db.users)
            ..where((u) => u.id.equals(userId)))
          .getSingleOrNull();
      if (target == null) throw PinError('No such user.');

      // The lockout goes with it. Someone who has forgotten a PIN has usually
      // locked themselves out trying to remember it, and leaving the lockout
      // in place would mean the new PIN did not work either.
      await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
          .write(UsersCompanion(
        pinHash: Value(hashPin(newPin)),
        failedAttempts: const Value(0),
        lockedUntil: const Value(null),
      ));

      // Who did it, and for whom. Never the PIN and never the hash.
      await _audit(
        action: AuditAction.pinChanged,
        userId: byUserId,
        at: now,
        entityId: userId,
        after: {'reset_for': userId},
      );
    });
  }

  /// Clears a lockout. Owner only, for when a staff member locks themselves out
  /// mid-service and the alternative is nobody being able to bill.
  Future<void> clearLockout({
    required String userId,
    required String byUserId,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    await _db.transaction(() async {
      final by = await (_db.select(_db.users)
            ..where((u) => u.id.equals(byUserId)))
          .getSingleOrNull();
      if (by == null || !Permission.manageUsers.allows(by.role)) {
        throw PinError('Only the owner can clear a lockout.');
      }

      await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
          .write(const UsersCompanion(
        failedAttempts: Value(0),
        lockedUntil: Value(null),
      ));

      await _audit(
        action: AuditAction.userEdited,
        userId: byUserId,
        at: now,
        entityId: userId,
        after: {'lockout_cleared_for': userId},
      );
    });
  }

  Future<void> _audit({
    required AuditAction action,
    required String userId,
    required DateTime at,
    String? entityId,
    Map<String, Object?>? after,
  }) =>
      _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: _uuid.v7(),
            at: at,
            userId: Value(userId),
            deviceId: deviceId,
            action: action,
            entity: AuditEntity.user,
            entityId: entityId ?? userId,
            after: Value(after == null ? null : jsonEncode(after)),
          ));
}
