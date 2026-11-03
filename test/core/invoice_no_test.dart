import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/invoice_no.dart';
import 'package:flutter_test/flutter_test.dart';

InvoiceNo build({String prefix = 'A', int fyStart = 2026, int seq = 123}) =>
    InvoiceNo.build(
      devicePrefix: prefix,
      fy: FinancialYear(fyStart),
      seq: seq,
    );

void main() {
  group('the format', () {
    test('matches the brief exactly', () {
      expect(build().formatted, 'A/2627/000123');
    });

    test('the sequence is zero padded to six digits', () {
      expect(build(seq: 1).formatted, 'A/2627/000001');
      expect(build(seq: 999999).formatted, 'A/2627/999999');
    });

    test('a lowercase device letter is upper-cased', () {
      expect(build(prefix: 'b').formatted, 'B/2627/000123');
    });

    test('a different device gives a different number', () {
      expect(build(prefix: 'B').formatted, 'B/2627/000123');
      expect(build(prefix: 'A').formatted, isNot(build(prefix: 'B').formatted));
    });
  });

  group('the 16-character limit', () {
    test('the normal case is 13 characters', () {
      expect(build().formatted.length, 13);
    });

    test('the longest possible number still fits', () {
      final longest = build(seq: maxInvoiceSeq).formatted;
      expect(longest, 'A/2627/999999');
      expect(longest.length, lessThanOrEqualTo(maxInvoiceNoLength));
    });

    test('every device letter, every year, every sequence length fits', () {
      for (final prefix in ['A', 'M', 'Z']) {
        for (final fy in [2000, 2026, 2099]) {
          for (final seq in [1, 9, 99, 9999, 999999]) {
            final no = InvoiceNo.build(
              devicePrefix: prefix,
              fy: FinancialYear(fy),
              seq: seq,
            );
            expect(
              no.formatted.length,
              lessThanOrEqualTo(maxInvoiceNoLength),
              reason: no.formatted,
            );
          }
        }
      }
    });

    test('a sequence past the limit is refused, not silently widened', () {
      expect(
        () => build(seq: maxInvoiceSeq + 1),
        throwsA(
          isA<InvoiceNumberError>().having(
            (e) => e.message,
            'message',
            contains('new device letter'),
          ),
        ),
      );
    });
  });

  group('rejections', () {
    test('a sequence below 1', () {
      expect(() => build(seq: 0), throwsA(isA<InvoiceNumberError>()));
      expect(() => build(seq: -1), throwsA(isA<InvoiceNumberError>()));
    });

    test('a device prefix that is not a single letter', () {
      for (final bad in ['', 'AB', '1', '/', ' ', 'A1']) {
        expect(
          () => build(prefix: bad),
          throwsA(isA<InvoiceNumberError>()),
          reason: 'prefix "$bad"',
        );
      }
    });

    test('isValidDevicePrefix agrees', () {
      expect(InvoiceNo.isValidDevicePrefix('A'), isTrue);
      expect(InvoiceNo.isValidDevicePrefix('z'), isTrue);
      expect(InvoiceNo.isValidDevicePrefix('AB'), isFalse);
      expect(InvoiceNo.isValidDevicePrefix('1'), isFalse);
      expect(InvoiceNo.isValidDevicePrefix(''), isFalse);
    });
  });

  group('parsing back', () {
    test('round trips', () {
      final original = build();
      final parsed = InvoiceNo.tryParse(original.formatted);
      expect(parsed, isNotNull);
      expect(parsed, original);
      expect(parsed!.devicePrefix, 'A');
      expect(parsed.fy.startYear, 2026);
      expect(parsed.seq, 123);
    });

    test('round trips across a range', () {
      for (final seq in [1, 42, 1000, 999999]) {
        for (final fy in [2000, 2026, 2099]) {
          final no = InvoiceNo.build(
            devicePrefix: 'C',
            fy: FinancialYear(fy),
            seq: seq,
          );
          expect(InvoiceNo.tryParse(no.formatted), no, reason: no.formatted);
        }
      }
    });

    test('rejects what is not one of ours', () {
      for (final bad in [
        '',
        'A/2627/123', // too few digits
        'A/2627/0001234', // too many
        'A/26/000123', // short year
        'a/2627/000123', // lowercase prefix
        'AB/2627/000123',
        'A-2627-000123',
        'A/2628/000123', // not consecutive years
        'A/2625/000123',
        'A/2627/000000', // sequence starts at 1
        '/2627/000123',
      ]) {
        expect(InvoiceNo.tryParse(bad), isNull, reason: '"$bad"');
      }
    });

    test('a century wrap parses as consecutive years', () {
      final no = InvoiceNo.build(
        devicePrefix: 'A',
        fy: FinancialYear(2099),
        seq: 1,
      );
      expect(no.formatted, 'A/9900/000001');
      expect(InvoiceNo.tryParse('A/9900/000001')!.fy.startYear, 2099);
    });
  });

  group('sequence state and the financial year rollover', () {
    test('a fresh device starts at 1', () {
      const s = SequenceState(fy: FinancialYear(2026), nextSeq: 1);
      expect(s.nextSeq, 1);
      expect(s.forDate(BusinessDate(2026, 4, 1)).nextSeq, 1);
    });

    test('within the same year it carries on', () {
      const s = SequenceState(fy: FinancialYear(2026), nextSeq: 124);
      final next = s.forDate(BusinessDate(2027, 3, 31));
      expect(next.nextSeq, 124);
      expect(next.fy, const FinancialYear(2026));
    });

    test('a new financial year restarts at 1', () {
      const s = SequenceState(fy: FinancialYear(2026), nextSeq: 5000);
      final next = s.forDate(BusinessDate(2027, 4, 1));
      expect(next.nextSeq, 1, reason: 'the series restarts each April');
      expect(next.fy, const FinancialYear(2027));
    });

    test('the rollover is driven by the business date, not the clock', () {
      const s = SequenceState(fy: FinancialYear(2026), nextSeq: 5000);

      // 1 April, 1:30 AM. The business date is still 31 March, so no rollover.
      final lateNight = BusinessDate.of(DateTime(2027, 4, 1, 1, 30));
      expect(s.forDate(lateNight).nextSeq, 5000);
      expect(s.forDate(lateNight).fy.code, '2627');

      // 1 April, 5 AM. Now it has rolled.
      final morning = BusinessDate.of(DateTime(2027, 4, 1, 5, 0));
      expect(s.forDate(morning).nextSeq, 1);
      expect(s.forDate(morning).fy.code, '2728');
    });

    test('a bill dated before the current year is refused', () {
      // Otherwise it would reissue numbers that are already on paper.
      const s = SequenceState(fy: FinancialYear(2027), nextSeq: 10);
      expect(
        () => s.forDate(BusinessDate(2026, 6, 1)),
        throwsA(isA<InvoiceNumberError>()),
      );
    });

    test('advanced moves to the next number', () {
      const s = SequenceState(fy: FinancialYear(2026), nextSeq: 123);
      expect(s.advanced.nextSeq, 124);
      expect(s.advanced.fy, s.fy);
    });

    test('a run of bills across the rollover produces no duplicates', () {
      var state = const SequenceState(fy: FinancialYear(2026), nextSeq: 1);
      final issued = <String>[];

      // Three bills in March, then three in April.
      final days = [
        BusinessDate(2027, 3, 30),
        BusinessDate(2027, 3, 31),
        BusinessDate(2027, 3, 31),
        BusinessDate(2027, 4, 1),
        BusinessDate(2027, 4, 1),
        BusinessDate(2027, 4, 2),
      ];

      for (final day in days) {
        state = state.forDate(day);
        issued.add(
          InvoiceNo.build(
            devicePrefix: 'A',
            fy: state.fy,
            seq: state.nextSeq,
          ).formatted,
        );
        state = state.advanced;
      }

      expect(issued, [
        'A/2627/000001',
        'A/2627/000002',
        'A/2627/000003',
        'A/2728/000001',
        'A/2728/000002',
        'A/2728/000003',
      ]);
      expect(issued.toSet(), hasLength(issued.length),
          reason: 'every number must be unique');
    });

    test('uniqueness holds within a year across many bills', () {
      var state = const SequenceState(fy: FinancialYear(2026), nextSeq: 1);
      final issued = <String>{};
      for (var i = 0; i < 2000; i++) {
        state = state.forDate(BusinessDate(2026, 6, 1));
        issued.add(InvoiceNo.build(
          devicePrefix: 'A',
          fy: state.fy,
          seq: state.nextSeq,
        ).formatted);
        state = state.advanced;
      }
      expect(issued, hasLength(2000));
    });

    test('two devices in the same year never collide', () {
      final a = InvoiceNo.build(
          devicePrefix: 'A', fy: const FinancialYear(2026), seq: 1);
      final b = InvoiceNo.build(
          devicePrefix: 'B', fy: const FinancialYear(2026), seq: 1);
      expect(a.formatted, isNot(b.formatted));
    });
  });
}
