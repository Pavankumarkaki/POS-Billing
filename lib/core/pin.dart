/// PIN hashing and the lockout, as plain Dart.
///
/// The brief asks for "salted PIN hashes" and "a lockout after repeated
/// failures". A bare salted SHA-256 would not be enough here: a PIN is four
/// digits, so there are only 10,000 of them and a modern phone would try every
/// one in well under a second against a stolen database file.
///
/// So this is PBKDF2-HMAC-SHA256 at 100,000 iterations, which puts each guess
/// at roughly 50 ms. With the lockout on top, guessing at the keypad is
/// hopeless, and an attacker who steals the file still needs hours per PIN
/// rather than milliseconds.
///
/// Argon2id would be better still, but every Dart implementation needs a native
/// dependency, and the brief rules out anything that is not strictly needed.
/// PBKDF2 is built from `package:crypto`, which is pure Dart.
///
/// Stored format, all base64, `$`-separated:
///
///     pbkdf2_sha256$100000$<salt>$<hash>
///
/// The iteration count travels with the hash, so it can be raised later
/// without invalidating the PINs already stored.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The algorithm label in the stored string.
const String kPinAlgorithm = 'pbkdf2_sha256';

/// Iterations for a new hash. Raising this stays backward compatible, because
/// each stored hash carries the count it was made with.
const int kPinIterations = 100000;

/// 16 bytes, the usual PBKDF2 salt size.
const int kPinSaltBytes = 16;

/// 32 bytes, matching SHA-256's own output, so there is nothing to gain from
/// asking for more.
const int kPinHashBytes = 32;

/// How many wrong PINs before the first lockout.
const int kMaxPinAttempts = 5;

/// The first lockout. It doubles with each further failed attempt.
const Duration kFirstLockout = Duration(seconds: 60);

/// The longest a lockout ever gets. Without a cap, a few stray taps during a
/// lunch rush could lock the till out for days.
const Duration kMaxLockout = Duration(minutes: 15);

class PinError implements Exception {
  PinError(this.message);
  final String message;
  @override
  String toString() => 'PinError: $message';
}

/// Whether a string is an acceptable PIN.
///
/// Four digits, as the design's keypad implies. Trivially weak PINs are
/// rejected: with only 10,000 possibilities, ruling out the few hundred that
/// anyone would try first is worth the small loss of choice.
bool isAcceptablePin(String pin) {
  if (!RegExp(r'^\d{4}$').hasMatch(pin)) return false;
  if (_isAllSameDigit(pin)) return false;
  if (_isRun(pin)) return false;
  return true;
}

/// Why a PIN was rejected, for the setup screen to show.
String? pinRejectionReason(String pin) {
  if (!RegExp(r'^\d{4}$').hasMatch(pin)) {
    return 'A PIN must be exactly four digits.';
  }
  if (_isAllSameDigit(pin)) {
    return 'Pick a PIN that is not the same digit four times.';
  }
  if (_isRun(pin)) {
    return 'Pick a PIN that is not four digits in a row.';
  }
  return null;
}

bool _isAllSameDigit(String pin) => pin.split('').toSet().length == 1;

bool _isRun(String pin) {
  final d = pin.codeUnits;
  var up = true;
  var down = true;
  for (var i = 1; i < d.length; i++) {
    if (d[i] != d[i - 1] + 1) up = false;
    if (d[i] != d[i - 1] - 1) down = false;
  }
  return up || down;
}

/// Hashes a PIN with a fresh random salt.
///
/// [random] is for tests only; production uses `Random.secure()`.
String hashPin(
  String pin, {
  int iterations = kPinIterations,
  Random? random,
}) {
  if (!RegExp(r'^\d{4,}$').hasMatch(pin)) {
    throw PinError('A PIN must be at least four digits.');
  }
  if (iterations < 1) {
    throw PinError('Iterations must be positive.');
  }

  final rng = random ?? Random.secure();
  final salt = Uint8List.fromList(
    List<int>.generate(kPinSaltBytes, (_) => rng.nextInt(256)),
  );
  final hash = _pbkdf2(
    password: utf8.encode(pin),
    salt: salt,
    iterations: iterations,
    outputBytes: kPinHashBytes,
  );

  return [
    kPinAlgorithm,
    iterations.toString(),
    base64.encode(salt),
    base64.encode(hash),
  ].join(r'$');
}

/// Checks a PIN against a stored hash.
///
/// Returns false rather than throwing on a malformed stored value, so a
/// corrupted row locks the user out instead of crashing the till. The caller
/// treats that as a failed attempt, which the audit log records.
bool verifyPin(String pin, String stored) {
  final parts = stored.split(r'$');
  if (parts.length != 4) return false;
  if (parts[0] != kPinAlgorithm) return false;

  final iterations = int.tryParse(parts[1]);
  if (iterations == null || iterations < 1) return false;

  final Uint8List salt;
  final Uint8List expected;
  try {
    salt = base64.decode(parts[2]);
    expected = base64.decode(parts[3]);
  } on FormatException {
    return false;
  }
  if (salt.isEmpty || expected.isEmpty) return false;

  final actual = _pbkdf2(
    password: utf8.encode(pin),
    salt: salt,
    iterations: iterations,
    outputBytes: expected.length,
  );

  return _constantTimeEquals(actual, expected);
}

/// Whether a stored hash was made with fewer iterations than we now use, and
/// so should be rehashed the next time the PIN is entered correctly.
bool needsRehash(String stored, {int iterations = kPinIterations}) {
  final parts = stored.split(r'$');
  if (parts.length != 4 || parts[0] != kPinAlgorithm) return true;
  final stored_ = int.tryParse(parts[1]);
  return stored_ == null || stored_ < iterations;
}

/// PBKDF2, RFC 8018 section 5.2, with HMAC-SHA256 as the pseudorandom function.
Uint8List _pbkdf2({
  required List<int> password,
  required Uint8List salt,
  required int iterations,
  required int outputBytes,
}) {
  final hmac = Hmac(sha256, password);
  const blockSize = 32; // SHA-256 output
  final blocks = (outputBytes / blockSize).ceil();
  final out = Uint8List(blocks * blockSize);

  for (var block = 1; block <= blocks; block++) {
    // U1 = PRF(password, salt || INT32BE(block))
    final first = Uint8List(salt.length + 4)
      ..setRange(0, salt.length, salt)
      ..[salt.length] = (block >> 24) & 0xff
      ..[salt.length + 1] = (block >> 16) & 0xff
      ..[salt.length + 2] = (block >> 8) & 0xff
      ..[salt.length + 3] = block & 0xff;

    var u = Uint8List.fromList(hmac.convert(first).bytes);
    final acc = Uint8List.fromList(u);

    // Uj = PRF(password, U(j-1)), accumulated by XOR.
    for (var i = 1; i < iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < blockSize; j++) {
        acc[j] ^= u[j];
      }
    }

    out.setRange((block - 1) * blockSize, block * blockSize, acc);
  }

  return Uint8List.sublistView(out, 0, outputBytes);
}

/// Compares without leaking where the first difference is.
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// The lockout, as a pure function of what is stored and what time it is.
///
/// Kept here rather than in the auth service so it can be tested without a
/// database or a clock: the state goes in, the next state comes out.
class LockoutState {
  const LockoutState({this.failedAttempts = 0, this.lockedUntil});

  final int failedAttempts;
  final DateTime? lockedUntil;

  /// Whether this user cannot try right now.
  bool isLockedAt(DateTime now) {
    final until = lockedUntil;
    if (until == null) return false;
    return now.isBefore(until);
  }

  /// How long is left on the lockout, or null if there is none.
  Duration? remainingAt(DateTime now) {
    final until = lockedUntil;
    if (until == null || !now.isBefore(until)) return null;
    return until.difference(now);
  }

  /// The state after a wrong PIN.
  ///
  /// The lockout starts after [kMaxPinAttempts] failures and doubles with each
  /// further failure, capped at [kMaxLockout].
  LockoutState afterFailure(DateTime now) {
    final attempts = failedAttempts + 1;
    if (attempts < kMaxPinAttempts) {
      return LockoutState(failedAttempts: attempts);
    }

    final over = attempts - kMaxPinAttempts;
    // 60s, 120s, 240s, ... capped.
    var seconds = kFirstLockout.inSeconds;
    for (var i = 0; i < over && seconds < kMaxLockout.inSeconds; i++) {
      seconds *= 2;
    }
    final penalty = Duration(
      seconds: seconds.clamp(0, kMaxLockout.inSeconds),
    );

    return LockoutState(
      failedAttempts: attempts,
      lockedUntil: now.add(penalty),
    );
  }

  /// The state after a correct PIN: everything forgotten.
  LockoutState get afterSuccess => const LockoutState();

  @override
  bool operator ==(Object other) =>
      other is LockoutState &&
      other.failedAttempts == failedAttempts &&
      other.lockedUntil == lockedUntil;

  @override
  int get hashCode => Object.hash(failedAttempts, lockedUntil);

  @override
  String toString() =>
      'LockoutState(attempts: $failedAttempts, until: $lockedUntil)';
}
