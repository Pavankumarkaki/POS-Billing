import 'package:restaurant_pos/core/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Paise basics', () {
    test('builds from rupees', () {
      expect(Paise.fromRupees(240).value, 24000);
      expect(Paise.fromRupees(0).value, 0);
    });

    test('arithmetic', () {
      expect((const Paise(24000) + const Paise(3000)).value, 27000);
      expect((const Paise(24000) - const Paise(3000)).value, 21000);
      expect((const Paise(2400) * 3).value, 7200);
      expect((-const Paise(2400)).value, -2400);
    });

    test('comparison', () {
      expect(const Paise(100) < const Paise(200), isTrue);
      expect(const Paise(200) <= const Paise(200), isTrue);
      expect(const Paise(300) > const Paise(200), isTrue);
      expect(const Paise(200) >= const Paise(201), isFalse);
      expect(const Paise(0).isZero, isTrue);
      expect(const Paise(-1).isNegative, isTrue);
    });
  });

  group('parsing what the owner typed', () {
    test('accepts the shapes a price field produces', () {
      expect(Paise.tryParse('240')!.value, 24000);
      expect(Paise.tryParse('240.50')!.value, 24050);
      expect(Paise.tryParse('240.5')!.value, 24050);
      expect(Paise.tryParse('240.05')!.value, 24005);
      expect(Paise.tryParse('₹240')!.value, 24000);
      expect(Paise.tryParse('1,240.00')!.value, 124000);
      expect(Paise.tryParse(' 240 ')!.value, 24000);
      expect(Paise.tryParse('0')!.value, 0);
      expect(Paise.tryParse('.5')!.value, 50);
      expect(Paise.tryParse('240.')!.value, 24000);
      expect(Paise.tryParse('-240.50')!.value, -24050);
    });

    test('rejects what is not a price', () {
      expect(Paise.tryParse(''), isNull);
      expect(Paise.tryParse('abc'), isNull);
      expect(Paise.tryParse('240.555'), isNull, reason: 'finer than a paisa');
      expect(Paise.tryParse('24.0.0'), isNull);
      expect(Paise.tryParse('-'), isNull);
      expect(Paise.tryParse('12a'), isNull);
    });

    test('parses exactly, where a double would not', () {
      // double.parse('240.50') * 100 is 24049.999999999996.
      expect(Paise.tryParse('240.50')!.value, 24050);
      expect(Paise.tryParse('0.07')!.value, 7);
      expect(Paise.tryParse('1.10')!.value, 110);
      expect(Paise.tryParse('8.29')!.value, 829);
    });
  });

  group('percentBp', () {
    test('known GST rates', () {
      expect(const Paise(100000).percentBp(250).value, 2500); // 2.5% of 1000
      expect(const Paise(100000).percentBp(900).value, 9000); // 9% of 1000
      expect(const Paise(100000).percentBp(500).value, 5000); // 5% of 1000
      expect(const Paise(100000).percentBp(1800).value, 18000);
    });

    test('rounds halves away from zero', () {
      // 2.5% of 70 paise is 1.75 paise -> 2
      expect(const Paise(70).percentBp(250).value, 2);
      // 2.5% of 20 paise is 0.5 paise -> 1, not 0
      expect(const Paise(20).percentBp(250).value, 1);
      expect(const Paise(-20).percentBp(250).value, -1);
    });

    test('a zero rate yields nothing', () {
      expect(const Paise(123456).percentBp(0).value, 0);
    });
  });

  group('rounding to rupees', () {
    test('roundToRupee goes to the nearest', () {
      expect(const Paise(24049).roundToRupee.value, 24000);
      expect(const Paise(24050).roundToRupee.value, 24100, reason: 'half goes up');
      expect(const Paise(24051).roundToRupee.value, 24100);
      expect(const Paise(24000).roundToRupee.value, 24000);
      expect(const Paise(-24050).roundToRupee.value, -24100);
    });

    test('ceilToRupee always goes up in magnitude', () {
      expect(const Paise(24001).ceilToRupee.value, 24100);
      expect(const Paise(24000).ceilToRupee.value, 24000);
      expect(const Paise(1).ceilToRupee.value, 100);
    });
  });

  group('allocate', () {
    test('every paisa is accounted for', () {
      final parts = const Paise(100).allocate(3);
      expect(parts.map((p) => p.value), [34, 33, 33]);
      expect(parts.fold(0, (s, p) => s + p.value), 100);
    });

    test('divides evenly when it can', () {
      expect(const Paise(900).allocate(3).map((p) => p.value), [300, 300, 300]);
    });

    test('negative amounts still sum back', () {
      final parts = const Paise(-100).allocate(3);
      expect(parts.fold(0, (s, p) => s + p.value), -100);
    });

    test('rejects a non-positive part count', () {
      expect(() => const Paise(100).allocate(0), throwsArgumentError);
    });
  });

  group('allocateByWeights', () {
    test('splits in proportion and sums back exactly', () {
      final parts = const Paise(10000).allocateByWeights([24000, 12000, 6000]);
      expect(parts.fold(0, (s, p) => s + p.value), 10000);
      // 24000:12000:6000 is 4:2:1 of 42000.
      expect(parts[0].value, greaterThan(parts[1].value));
      expect(parts[1].value, greaterThan(parts[2].value));
    });

    test('an awkward split still sums back exactly', () {
      // 100 paise over three equal lines: someone must get the extra paisa.
      final parts = const Paise(100).allocateByWeights([1, 1, 1]);
      expect(parts.fold(0, (s, p) => s + p.value), 100);
    });

    test('many lines, odd discount, nothing lost', () {
      final weights = List<int>.generate(17, (i) => (i + 1) * 137);
      final parts = const Paise(99991).allocateByWeights(weights);
      expect(parts.fold(0, (s, p) => s + p.value), 99991);
      expect(parts, hasLength(17));
    });

    test('zero weights fall back to an even split', () {
      final parts = const Paise(100).allocateByWeights([0, 0]);
      expect(parts.fold(0, (s, p) => s + p.value), 100);
    });

    test('no weights, no parts', () {
      expect(const Paise(100).allocateByWeights([]), isEmpty);
    });
  });

  group('formatting', () {
    test('plain is for CSV and receipt columns', () {
      expect(const Paise(24000).plain, '240.00');
      expect(const Paise(24050).plain, '240.50');
      expect(const Paise(7).plain, '0.07');
      expect(const Paise(-24050).plain, '-240.50');
    });

    test('rupees groups the Indian way', () {
      expect(const Paise(24000).rupees, '₹240.00');
      expect(const Paise(100000).rupees, '₹1,000.00');
      expect(const Paise(12405000).rupees, '₹1,24,050.00');
      // 10 lakh: 1e8 paise is 1e6 rupees.
      expect(const Paise(100000000).rupees, '₹10,00,000.00');
      // 1 crore: 1e9 paise is 1e7 rupees.
      expect(const Paise(1000000000).rupees, '₹1,00,00,000.00');
      // 10 crore.
      expect(const Paise(10000000000).rupees, '₹10,00,00,000.00');
    });

    test('rupeesWhole drops the paise', () {
      expect(const Paise(24050).rupeesWhole, '₹240');
      expect(const Paise(12405000).rupeesWhole, '₹1,24,050');
      expect(const Paise(-24000).rupeesWhole, '₹-240');
    });

    test('small amounts are not grouped', () {
      expect(const Paise(100).rupees, '₹1.00');
      expect(const Paise(99900).rupees, '₹999.00');
    });
  });
}
