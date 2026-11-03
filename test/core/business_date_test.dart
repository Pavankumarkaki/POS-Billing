import 'package:restaurant_pos/core/business_date.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the 04:00 cutoff', () {
    test('a bill at 1 AM belongs to the night before', () {
      final at = DateTime(2026, 3, 3, 1, 30);
      expect(BusinessDate.of(at).iso, '2026-03-02');
    });

    test('a bill at 11 PM belongs to its own day', () {
      final at = DateTime(2026, 3, 2, 23, 0);
      expect(BusinessDate.of(at).iso, '2026-03-02');
    });

    test('exactly 04:00 starts the new business day', () {
      expect(BusinessDate.of(DateTime(2026, 3, 3, 4, 0, 0)).iso, '2026-03-03');
    });

    test('one second before 04:00 is still the previous day', () {
      expect(BusinessDate.of(DateTime(2026, 3, 3, 3, 59, 59)).iso,
          '2026-03-02');
    });

    test('one millisecond either side of the boundary', () {
      expect(
        BusinessDate.of(DateTime(2026, 3, 3, 3, 59, 59, 999)).iso,
        '2026-03-02',
      );
      expect(
        BusinessDate.of(DateTime(2026, 3, 3, 4, 0, 0, 1)).iso,
        '2026-03-03',
      );
    });

    test('midnight belongs to the previous business day', () {
      expect(BusinessDate.of(DateTime(2026, 3, 3, 0, 0)).iso, '2026-03-02');
    });

    test('a different cutoff moves the boundary', () {
      final at = DateTime(2026, 3, 3, 4, 30);
      expect(
        BusinessDate.of(at, cutoff: const Duration(hours: 6)).iso,
        '2026-03-02',
      );
      expect(
        BusinessDate.of(at, cutoff: const Duration(hours: 4)).iso,
        '2026-03-03',
      );
    });

    test('a midnight cutoff is just the calendar date', () {
      final at = DateTime(2026, 3, 3, 1, 30);
      expect(
        BusinessDate.of(at, cutoff: Duration.zero).iso,
        '2026-03-03',
      );
    });

    test('a 1 AM bill on the first of a month lands in the previous month', () {
      expect(BusinessDate.of(DateTime(2026, 4, 1, 1, 0)).iso, '2026-03-31');
    });

    test('a 1 AM bill on 1 January lands in the previous year', () {
      expect(BusinessDate.of(DateTime(2027, 1, 1, 2, 0)).iso, '2026-12-31');
    });

    test('a 1 AM bill on 1 March in a leap year lands on 29 February', () {
      expect(BusinessDate.of(DateTime(2028, 3, 1, 1, 0)).iso, '2028-02-29');
    });
  });

  group('the range a day covers', () {
    test('starts at the cutoff and ends at the next one', () {
      final d = const BusinessDate(2026, 3, 2);
      expect(d.startsAt(), DateTime(2026, 3, 2, 4, 0));
      expect(d.endsAt(), DateTime(2026, 3, 3, 4, 0));
    });

    test('the range is half open, so days never overlap', () {
      final d = const BusinessDate(2026, 3, 2);
      final next = const BusinessDate(2026, 3, 3);
      expect(d.endsAt(), next.startsAt());
    });

    test('every instant in the range maps back to the same day', () {
      final d = const BusinessDate(2026, 3, 2);
      final probes = [
        d.startsAt(),
        DateTime(2026, 3, 2, 12, 0),
        DateTime(2026, 3, 2, 23, 59),
        DateTime(2026, 3, 3, 0, 1),
        d.endsAt().subtract(const Duration(milliseconds: 1)),
      ];
      for (final p in probes) {
        expect(BusinessDate.of(p), d, reason: '$p');
      }
      expect(BusinessDate.of(d.endsAt()), const BusinessDate(2026, 3, 3));
    });
  });

  group('parsing and formatting', () {
    test('round trips', () {
      expect(BusinessDate.tryParse('2026-03-02')!.iso, '2026-03-02');
      expect(BusinessDate.tryParse('2026-12-31')!.iso, '2026-12-31');
    });

    test('rejects nonsense', () {
      expect(BusinessDate.tryParse(''), isNull);
      expect(BusinessDate.tryParse('2026-3-2'), isNull);
      expect(BusinessDate.tryParse('02-03-2026'), isNull);
      expect(BusinessDate.tryParse('2026-13-01'), isNull);
      expect(BusinessDate.tryParse('2026-02-31'), isNull);
      expect(BusinessDate.tryParse('2026-00-10'), isNull);
    });

    test('accepts 29 February in a leap year only', () {
      expect(BusinessDate.tryParse('2028-02-29'), isNotNull);
      expect(BusinessDate.tryParse('2026-02-29'), isNull);
    });

    test('sorts correctly as text, which is how it is stored', () {
      final dates = ['2026-12-31', '2026-01-05', '2026-03-02']..sort();
      expect(dates, ['2026-01-05', '2026-03-02', '2026-12-31']);
    });
  });

  group('comparison and arithmetic', () {
    test('compares', () {
      expect(const BusinessDate(2026, 3, 2) < const BusinessDate(2026, 3, 3), isTrue);
      expect(const BusinessDate(2026, 3, 2) == const BusinessDate(2026, 3, 2), isTrue);
      expect(const BusinessDate(2027, 1, 1) > const BusinessDate(2026, 12, 31), isTrue);
      expect(const BusinessDate(2026, 4, 1) >= const BusinessDate(2026, 4, 1), isTrue);
    });

    test('addDays crosses months and years', () {
      expect(const BusinessDate(2026, 3, 31).addDays(1).iso, '2026-04-01');
      expect(const BusinessDate(2026, 12, 31).addDays(1).iso, '2027-01-01');
      expect(const BusinessDate(2026, 4, 1).addDays(-1).iso, '2026-03-31');
    });

    test('weekStart is the Monday', () {
      // 2026-03-04 is a Wednesday.
      expect(const BusinessDate(2026, 3, 4).weekStart.iso, '2026-03-02');
      // A Monday is its own week start.
      expect(const BusinessDate(2026, 3, 2).weekStart.iso, '2026-03-02');
      // A Sunday belongs to the week that started six days earlier.
      expect(const BusinessDate(2026, 3, 8).weekStart.iso, '2026-03-02');
    });

    test('monthStart', () {
      expect(const BusinessDate(2026, 3, 17).monthStart.iso, '2026-03-01');
    });
  });

  group('financial years, April to March', () {
    test('April opens a new financial year', () {
      expect(FinancialYear.of(const BusinessDate(2026, 4, 1)).startYear, 2026);
      expect(FinancialYear.of(const BusinessDate(2026, 4, 1)).code, '2627');
    });

    test('March still belongs to the year that opened the previous April', () {
      expect(FinancialYear.of(const BusinessDate(2027, 3, 31)).startYear, 2026);
      expect(FinancialYear.of(const BusinessDate(2027, 3, 31)).code, '2627');
    });

    test('January to March belong to the previous April', () {
      for (final month in [1, 2, 3]) {
        expect(FinancialYear.of(BusinessDate(2027, month, 15)).code, '2627',
            reason: 'month $month');
      }
    });

    test('April to December belong to their own year', () {
      for (final month in [4, 7, 12]) {
        expect(FinancialYear.of(BusinessDate(2026, month, 15)).code, '2627',
            reason: 'month $month');
      }
    });

    test('the rollover lands exactly between 31 March and 1 April', () {
      expect(FinancialYear.of(const BusinessDate(2027, 3, 31)).code, '2627');
      expect(FinancialYear.of(const BusinessDate(2027, 4, 1)).code, '2728');
    });

    test('a 1 AM bill on 1 April is still the old financial year', () {
      // The business date is 31 March, so the invoice series has not rolled.
      final at = DateTime(2027, 4, 1, 1, 30);
      final day = BusinessDate.of(at);
      expect(day.iso, '2027-03-31');
      expect(day.financialYear.code, '2627');
    });

    test('a 5 AM bill on 1 April has rolled over', () {
      final at = DateTime(2027, 4, 1, 5, 0);
      final day = BusinessDate.of(at);
      expect(day.iso, '2027-04-01');
      expect(day.financialYear.code, '2728');
    });

    test('the code is always four digits', () {
      for (var y = 2020; y <= 2040; y++) {
        expect(FinancialYear(y).code, hasLength(4), reason: '$y');
      }
    });

    test('a century wrap still gives four digits', () {
      expect(const FinancialYear(2099).code, '9900');
      expect(const FinancialYear(2000).code, '0001');
    });

    test('the label reads the way an owner expects', () {
      expect(const FinancialYear(2026).label, '2026-27');
      expect(const FinancialYear(2099).label, '2099-00');
    });

    test('first and last day', () {
      final fy = const FinancialYear(2026);
      expect(fy.firstDay.iso, '2026-04-01');
      expect(fy.lastDay.iso, '2027-03-31');
    });

    test('contains', () {
      final fy = const FinancialYear(2026);
      expect(fy.contains(const BusinessDate(2026, 4, 1)), isTrue);
      expect(fy.contains(const BusinessDate(2027, 3, 31)), isTrue);
      expect(fy.contains(const BusinessDate(2026, 3, 31)), isFalse);
      expect(fy.contains(const BusinessDate(2027, 4, 1)), isFalse);
    });

    test('next', () {
      expect(const FinancialYear(2026).next, const FinancialYear(2027));
    });

    test('every day of a financial year maps back to it', () {
      final fy = const FinancialYear(2026);
      var day = fy.firstDay;
      var count = 0;
      while (day <= fy.lastDay) {
        expect(day.financialYear, fy, reason: day.iso);
        day = day.addDays(1);
        count++;
      }
      expect(count, 365, reason: 'FY 2026-27 is not a leap year span');
    });
  });
}
