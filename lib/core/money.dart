/// Money, as whole paise. Never a double.
///
/// `Paise` is an `extension type`: it is an `int` at runtime with no wrapper
/// object and no allocation, but the compiler treats it as a distinct type. So
/// `Paise(100) + 50` will not compile, and neither will assigning a `double` to
/// a `Paise`. That is the "no floating point for money" rule enforced by the
/// type checker rather than by review.
///
/// Rupees only ever appear at the edges: parsing what the owner typed, and
/// formatting for the screen or the receipt.
library;

extension type const Paise(int value) {
  /// Zero rupees.
  static const Paise zero = Paise(0);

  /// Builds from whole rupees. `Paise.fromRupees(240)` is 24000 paise.
  factory Paise.fromRupees(int rupees) => Paise(rupees * 100);

  /// Parses what a person typed into a price field: `"240"`, `"240.50"`,
  /// `"₹240.5"`, `"1,240.00"`. Returns null if it is not a price.
  ///
  /// Deliberately does its own digit arithmetic instead of `double.parse`,
  /// because `double.parse("240.50") * 100` is 24049.999999999996 and rounding
  /// that is how money bugs start.
  static Paise? tryParse(String input) {
    final cleaned = input.replaceAll(RegExp(r'[₹,\s]'), '');
    if (cleaned.isEmpty) return null;

    final negative = cleaned.startsWith('-');
    final body = negative ? cleaned.substring(1) : cleaned;
    if (body.isEmpty) return null;

    final parts = body.split('.');
    if (parts.length > 2) return null;
    if (parts.any((p) => p.isNotEmpty && !RegExp(r'^\d+$').hasMatch(p))) {
      return null;
    }

    final whole = parts[0].isEmpty ? 0 : int.parse(parts[0]);
    var fraction = 0;
    if (parts.length == 2) {
      final frac = parts[1];
      if (frac.length > 2) return null; // finer than a paisa is not money
      if (frac.isEmpty) {
        fraction = 0;
      } else {
        fraction = int.parse(frac.padRight(2, '0'));
      }
    }

    final total = whole * 100 + fraction;
    return Paise(negative ? -total : total);
  }

  Paise operator +(Paise other) => Paise(value + other.value);

  Paise operator -(Paise other) => Paise(value - other.value);

  Paise operator -() => Paise(-value);

  /// Multiplies by a whole count, such as a line quantity.
  Paise operator *(int count) => Paise(value * count);

  bool operator <(Paise other) => value < other.value;

  bool operator <=(Paise other) => value <= other.value;

  bool operator >(Paise other) => value > other.value;

  bool operator >=(Paise other) => value >= other.value;

  bool get isZero => value == 0;

  bool get isNegative => value < 0;

  bool get isPositive => value > 0;

  Paise get abs => Paise(value.abs());

  /// Applies a percentage given in basis points, rounding half away from zero.
  ///
  /// Basis points keep the rate itself an integer: 2.5% is 250 bp, 9% is 900 bp,
  /// 18% is 1800 bp. So a tax rate never introduces a double either.
  Paise percentBp(int basisPoints) =>
      Paise(_divRound(value * basisPoints, 10000));

  /// Rounds up to the next whole rupee. Used by the round-off line.
  Paise get ceilToRupee {
    final remainder = value % 100;
    if (remainder == 0) return this;
    return Paise(value + (value.isNegative ? -remainder.abs() : 100 - remainder));
  }

  /// Rounds to the nearest whole rupee, halves away from zero.
  Paise get roundToRupee => Paise(_divRound(value, 100) * 100);

  /// Splits into [parts] shares that sum exactly back to this amount.
  ///
  /// The remainder is handed out one paisa at a time to the earliest shares, so
  /// 100 paise over 3 ways is [34, 33, 33] and not [33, 33, 33] with a paisa
  /// lost. Used to spread a bill-level discount across lines.
  List<Paise> allocate(int parts) {
    if (parts <= 0) throw ArgumentError.value(parts, 'parts', 'must be positive');
    final base = value ~/ parts;
    var remainder = value - base * parts;
    final step = remainder.isNegative ? -1 : 1;
    return List<Paise>.generate(parts, (i) {
      if (remainder != 0) {
        remainder -= step;
        return Paise(base + step);
      }
      return Paise(base);
    });
  }

  /// Splits in proportion to [weights], summing exactly back to this amount.
  ///
  /// This is how a bill discount is spread over lines: by each line's share of
  /// the subtotal, with the rounding remainder given to the largest lines so
  /// the parts always add up.
  List<Paise> allocateByWeights(List<int> weights) {
    if (weights.isEmpty) return const [];
    final total = weights.fold<int>(0, (a, b) => a + b);
    if (total == 0) return allocate(weights.length);

    final shares = <int>[];
    var distributed = 0;
    for (final w in weights) {
      final share = (value * w) ~/ total;
      shares.add(share);
      distributed += share;
    }

    // Hand the leftover paise to the heaviest weights first.
    var leftover = value - distributed;
    final step = leftover.isNegative ? -1 : 1;
    final order = List<int>.generate(weights.length, (i) => i)
      ..sort((a, b) => weights[b].compareTo(weights[a]));
    var i = 0;
    while (leftover != 0 && weights.isNotEmpty) {
      shares[order[i % order.length]] += step;
      leftover -= step;
      i++;
    }

    return shares.map(Paise.new).toList(growable: false);
  }

  /// Orders two amounts. Not an override: `Paise` deliberately does not
  /// implement `Comparable<Paise>`, because an extension type may only
  /// implement supertypes of its representation type and `int` implements
  /// `Comparable<num>`.
  int compareTo(Paise other) => value.compareTo(other.value);

  /// `"240.00"`. Digits only, for CSV and receipt columns.
  String get plain {
    final sign = value < 0 ? '-' : '';
    final a = value.abs();
    return '$sign${a ~/ 100}.${(a % 100).toString().padLeft(2, '0')}';
  }

  /// `"₹1,24,050.00"`, grouped the Indian way (lakh and crore).
  String get rupees => '₹${_groupIndian(plain)}';

  /// `"₹1,24,050"`, no paise. For KPI tiles and list rows, where the design
  /// shows whole rupees.
  String get rupeesWhole {
    final sign = value < 0 ? '-' : '';
    return '₹$sign${_groupIndian((value.abs() ~/ 100).toString())}';
  }
}

/// Integer division rounding halves away from zero.
///
/// Dart's `~/` truncates toward zero, so `5 ~/ 2` is 2 and `-5 ~/ 2` is -2.
/// Tax at exactly half a paisa must round up in magnitude, consistently in both
/// directions, or a credit note would not mirror its invoice.
int _divRound(int numerator, int denominator) {
  assert(denominator > 0);
  if (numerator.isNegative) {
    return -((-numerator * 2 + denominator) ~/ (denominator * 2));
  }
  return (numerator * 2 + denominator) ~/ (denominator * 2);
}

/// Indian digit grouping: last three digits, then pairs.
/// 124050 -> 1,24,050
String _groupIndian(String number) {
  final dot = number.indexOf('.');
  final whole = dot == -1 ? number : number.substring(0, dot);
  final tail = dot == -1 ? '' : number.substring(dot);

  if (whole.length <= 3) return '$whole$tail';

  final lastThree = whole.substring(whole.length - 3);
  var rest = whole.substring(0, whole.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);

  return '${groups.join(',')},$lastThree$tail';
}
