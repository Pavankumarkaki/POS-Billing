import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/pin.dart';

/// A fixed-sequence "random" so salts are predictable in tests. Never used
/// outside tests; production uses Random.secure().
class _FixedRandom implements Random {
  _FixedRandom(this.seedByte);
  final int seedByte;
  @override
  int nextInt(int max) => seedByte % max;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0;
}

void main() {
  // Hashing at 100k iterations is deliberately slow, so these tests use a low
  // count except where the real default is the thing being checked.
  const fast = 100;

  group('hashing', () {
    test('produces the documented format', () {
      final h = hashPin('1357', iterations: fast);
      final parts = h.split(r'$');
      expect(parts, hasLength(4));
      expect(parts[0], 'pbkdf2_sha256');
      expect(parts[1], '$fast');
      expect(base64.decode(parts[2]), hasLength(kPinSaltBytes));
      expect(base64.decode(parts[3]), hasLength(kPinHashBytes));
    });

    test('the PIN itself never appears in the stored string', () {
      final h = hashPin('1357', iterations: fast);
      expect(h.contains('1357'), isFalse);
      // Nor as base64 of itself.
      expect(h.contains(base64.encode(utf8.encode('1357'))), isFalse);
    });

    test('the same PIN hashed twice gives different stored values', () {
      final a = hashPin('1357', iterations: fast);
      final b = hashPin('1357', iterations: fast);
      expect(a, isNot(b), reason: 'the salt is fresh each time');
      expect(verifyPin('1357', a), isTrue);
      expect(verifyPin('1357', b), isTrue);
    });

    test('two users with the same PIN get different hashes', () {
      final owner = hashPin('1357', iterations: fast);
      final staff = hashPin('1357', iterations: fast);
      final ownerHash = owner.split(r'$')[3];
      final staffHash = staff.split(r'$')[3];
      expect(ownerHash, isNot(staffHash),
          reason: 'so one cracked PIN does not reveal the other');
    });

    test('the same salt and PIN are deterministic', () {
      final a = hashPin('1357', iterations: fast, random: _FixedRandom(7));
      final b = hashPin('1357', iterations: fast, random: _FixedRandom(7));
      expect(a, b);
    });

    test('a short PIN is refused', () {
      expect(() => hashPin('123', iterations: fast), throwsA(isA<PinError>()));
      expect(() => hashPin('', iterations: fast), throwsA(isA<PinError>()));
      expect(() => hashPin('abcd', iterations: fast), throwsA(isA<PinError>()));
    });

    test('zero iterations is refused', () {
      expect(() => hashPin('1357', iterations: 0), throwsA(isA<PinError>()));
    });
  });

  group('verifying', () {
    test('the right PIN passes', () {
      final h = hashPin('1357', iterations: fast);
      expect(verifyPin('1357', h), isTrue);
    });

    test('a wrong PIN fails', () {
      final h = hashPin('1357', iterations: fast);
      for (final wrong in ['1358', '7531', '0000', '135', '13570', '']) {
        expect(verifyPin(wrong, h), isFalse, reason: '"$wrong"');
      }
    });

    test('every other four-digit PIN fails', () {
      final h = hashPin('1357', iterations: 1);
      var passes = 0;
      for (var i = 0; i < 10000; i++) {
        final candidate = i.toString().padLeft(4, '0');
        if (verifyPin(candidate, h)) passes++;
      }
      expect(passes, 1, reason: 'exactly one PIN may open it');
    });

    test('a malformed stored value fails rather than throwing', () {
      for (final bad in [
        '',
        'nonsense',
        r'pbkdf2_sha256$100$salt',
        r'pbkdf2_sha256$100$!!!notbase64!!!$abc',
        r'md5$100$c2FsdA==$aGFzaA==',
        r'pbkdf2_sha256$0$c2FsdA==$aGFzaA==',
        r'pbkdf2_sha256$abc$c2FsdA==$aGFzaA==',
        r'pbkdf2_sha256$100$$',
      ]) {
        expect(
          () => verifyPin('1357', bad),
          returnsNormally,
          reason: '"$bad" must not throw',
        );
        expect(verifyPin('1357', bad), isFalse, reason: '"$bad"');
      }
    });

    test('a hash made at one iteration count verifies at that count', () {
      // The count travels with the hash, so raising the default must not
      // invalidate PINs already stored.
      final old = hashPin('1357', iterations: 50);
      expect(verifyPin('1357', old), isTrue);
    });

    test('a tampered hash fails', () {
      final h = hashPin('1357', iterations: fast);
      final parts = h.split(r'$');
      final bytes = base64.decode(parts[3]);
      bytes[0] ^= 0xff;
      final tampered =
          [parts[0], parts[1], parts[2], base64.encode(bytes)].join(r'$');
      expect(verifyPin('1357', tampered), isFalse);
    });

    test('a tampered salt fails', () {
      final h = hashPin('1357', iterations: fast);
      final parts = h.split(r'$');
      final salt = base64.decode(parts[2]);
      salt[0] ^= 0xff;
      final tampered =
          [parts[0], parts[1], base64.encode(salt), parts[3]].join(r'$');
      expect(verifyPin('1357', tampered), isFalse);
    });
  });

  group('needsRehash', () {
    test('an older iteration count asks for a rehash', () {
      final old = hashPin('1357', iterations: 50);
      expect(needsRehash(old, iterations: 100), isTrue);
    });

    test('the current count does not', () {
      final current = hashPin('1357', iterations: 100);
      expect(needsRehash(current, iterations: 100), isFalse);
    });

    test('a higher count than ours does not', () {
      final newer = hashPin('1357', iterations: 200);
      expect(needsRehash(newer, iterations: 100), isFalse);
    });

    test('anything unparseable asks for a rehash', () {
      expect(needsRehash('rubbish'), isTrue);
      expect(needsRehash(r'md5$100$a$b'), isTrue);
    });
  });

  group('the default is strong enough to be slow', () {
    test('the default iteration count is at least 100k', () {
      expect(kPinIterations, greaterThanOrEqualTo(100000));
    });

    test('a real hash and verify round trips', () {
      // Not timed, because a slow CI box would make that flaky. The point is
      // that the real default works end to end.
      final h = hashPin('1357');
      expect(verifyPin('1357', h), isTrue);
      expect(verifyPin('1358', h), isFalse);
      expect(needsRehash(h), isFalse);
    });
  });

  group('acceptable PINs', () {
    test('an ordinary PIN is fine', () {
      for (final good in ['1357', '2468', '9042', '1739']) {
        expect(isAcceptablePin(good), isTrue, reason: good);
        expect(pinRejectionReason(good), isNull);
      }
    });

    test('not four digits', () {
      for (final bad in ['', '1', '123', '12345', 'abcd', '12a4', '12 4']) {
        expect(isAcceptablePin(bad), isFalse, reason: '"$bad"');
        expect(pinRejectionReason(bad), contains('four digits'));
      }
    });

    test('all the same digit', () {
      for (final bad in ['0000', '1111', '9999']) {
        expect(isAcceptablePin(bad), isFalse, reason: bad);
        expect(pinRejectionReason(bad), contains('same digit'));
      }
    });

    test('four in a row, either direction', () {
      for (final bad in ['1234', '2345', '6789', '4321', '9876']) {
        expect(isAcceptablePin(bad), isFalse, reason: bad);
        expect(pinRejectionReason(bad), contains('in a row'));
      }
    });

    test('a near-run is still allowed', () {
      for (final good in ['1235', '1243', '1334']) {
        expect(isAcceptablePin(good), isTrue, reason: good);
      }
    });
  });

  group('lockout', () {
    final t0 = DateTime(2026, 6, 1, 13, 0, 0);

    test('a fresh user is not locked', () {
      const s = LockoutState();
      expect(s.isLockedAt(t0), isFalse);
      expect(s.remainingAt(t0), isNull);
      expect(s.failedAttempts, 0);
    });

    test('the first four failures do not lock', () {
      var s = const LockoutState();
      for (var i = 1; i <= 4; i++) {
        s = s.afterFailure(t0);
        expect(s.failedAttempts, i);
        expect(s.isLockedAt(t0), isFalse, reason: 'after $i failures');
      }
    });

    test('the fifth failure locks for a minute', () {
      var s = const LockoutState();
      for (var i = 0; i < 5; i++) {
        s = s.afterFailure(t0);
      }
      expect(s.failedAttempts, 5);
      expect(s.isLockedAt(t0), isTrue);
      expect(s.remainingAt(t0), kFirstLockout);
      expect(s.lockedUntil, t0.add(kFirstLockout));
    });

    test('the lockout expires', () {
      var s = const LockoutState();
      for (var i = 0; i < 5; i++) {
        s = s.afterFailure(t0);
      }
      expect(s.isLockedAt(t0.add(const Duration(seconds: 59))), isTrue);
      expect(s.isLockedAt(t0.add(const Duration(seconds: 60))), isFalse);
      expect(s.isLockedAt(t0.add(const Duration(seconds: 61))), isFalse);
      expect(s.remainingAt(t0.add(const Duration(seconds: 60))), isNull);
    });

    test('each further failure doubles the lockout', () {
      var s = const LockoutState();
      for (var i = 0; i < 5; i++) {
        s = s.afterFailure(t0);
      }
      expect(s.remainingAt(t0), const Duration(seconds: 60));

      s = s.afterFailure(t0);
      expect(s.remainingAt(t0), const Duration(seconds: 120));

      s = s.afterFailure(t0);
      expect(s.remainingAt(t0), const Duration(seconds: 240));

      s = s.afterFailure(t0);
      expect(s.remainingAt(t0), const Duration(seconds: 480));
    });

    test('the lockout is capped, so a stray hand cannot lock the till out',
        () {
      var s = const LockoutState();
      for (var i = 0; i < 40; i++) {
        s = s.afterFailure(t0);
      }
      expect(s.remainingAt(t0), kMaxLockout);
      expect(s.remainingAt(t0)!.inMinutes, 15);
    });

    test('the cap is never exceeded at any attempt count', () {
      var s = const LockoutState();
      for (var i = 0; i < 100; i++) {
        s = s.afterFailure(t0);
        final r = s.remainingAt(t0);
        if (r != null) {
          expect(r, lessThanOrEqualTo(kMaxLockout), reason: 'attempt ${i + 1}');
        }
      }
    });

    test('a correct PIN clears everything', () {
      var s = const LockoutState();
      for (var i = 0; i < 7; i++) {
        s = s.afterFailure(t0);
      }
      expect(s.isLockedAt(t0), isTrue);

      s = s.afterSuccess;
      expect(s.failedAttempts, 0);
      expect(s.lockedUntil, isNull);
      expect(s.isLockedAt(t0), isFalse);
    });

    test('the state survives being stored and read back', () {
      var s = const LockoutState();
      for (var i = 0; i < 5; i++) {
        s = s.afterFailure(t0);
      }
      // What the user row would hold.
      final storedAttempts = s.failedAttempts;
      final storedUntil = s.lockedUntil;

      final restored = LockoutState(
        failedAttempts: storedAttempts,
        lockedUntil: storedUntil,
      );
      expect(restored, s, reason: 'a restart must not clear the lockout');
      expect(restored.isLockedAt(t0), isTrue);
    });
  });
}
