/// Invoice numbering. Pure Dart.
///
/// The format is `A/2627/000123`: a device letter, the financial year, and a
/// sequence that restarts each April.
///
///   A        device letter, so two devices can never collide
///   2627     FY 2026-27
///   000123   the 123rd bill this device has written this financial year
///
/// Hard rules from the brief, each enforced here and tested:
///   - unique within a financial year
///   - at most 16 characters
///   - that exact shape
///
/// Uniqueness within the year is really the database's job
/// (`UNIQUE(device_id, device_seq)` plus the sequence claimed inside the sale
/// transaction). What this file guarantees is that a given device, year and
/// sequence always render to the same string, and that the string fits.
library;

import 'business_date.dart';

/// The longest an invoice number may be. From the brief; also what GST rule 46
/// allows for a document number.
const int maxInvoiceNoLength = 16;

/// The widest sequence that still fits: `A/2627/` is 7 characters, leaving 9.
/// We use 6 digits, which allows 999,999 bills per device per year and leaves
/// the format stable rather than growing mid-year.
const int invoiceSeqDigits = 6;

/// The largest sequence that fits in [invoiceSeqDigits].
const int maxInvoiceSeq = 999999;

class InvoiceNumberError implements Exception {
  InvoiceNumberError(this.message);
  final String message;
  @override
  String toString() => 'InvoiceNumberError: $message';
}

/// An invoice number, parsed into its parts.
class InvoiceNo {
  const InvoiceNo({
    required this.devicePrefix,
    required this.fy,
    required this.seq,
  });

  /// The device letter, `A` to `Z`. One per device, assigned at first-run setup.
  final String devicePrefix;

  final FinancialYear fy;

  /// This device's sequence within this financial year. Starts at 1.
  final int seq;

  /// Builds the number, checking every rule.
  ///
  /// Throws rather than returning something invalid: a bad invoice number must
  /// never reach a customer or a return, so this fails at the point of use
  /// inside the sale transaction, which rolls the whole sale back.
  factory InvoiceNo.build({
    required String devicePrefix,
    required FinancialYear fy,
    required int seq,
  }) {
    if (!isValidDevicePrefix(devicePrefix)) {
      throw InvoiceNumberError(
        'The device letter must be a single letter A to Z, '
        'not "$devicePrefix".',
      );
    }
    if (seq < 1) {
      throw InvoiceNumberError('An invoice sequence starts at 1, not $seq.');
    }
    if (seq > maxInvoiceSeq) {
      throw InvoiceNumberError(
        'This device has written $maxInvoiceSeq bills in ${fy.label}, which is '
        'all the invoice number format allows. Start a new device letter.',
      );
    }

    final no = InvoiceNo(
      devicePrefix: devicePrefix.toUpperCase(),
      fy: fy,
      seq: seq,
    );

    // Belt and braces: the arithmetic above should make this impossible, so if
    // it ever fires the format itself has changed and the tests should say so.
    if (no.formatted.length > maxInvoiceNoLength) {
      throw InvoiceNumberError(
        'Invoice number "${no.formatted}" is ${no.formatted.length} '
        'characters, over the $maxInvoiceNoLength limit.',
      );
    }
    return no;
  }

  /// The one true rendering. `A/2627/000123`.
  String get formatted =>
      '$devicePrefix/${fy.code}/${seq.toString().padLeft(invoiceSeqDigits, '0')}';

  /// Reads a number back, for a reprint or a report filter.
  /// Returns null if it is not one of ours.
  static InvoiceNo? tryParse(String input) {
    final m = RegExp(r'^([A-Z])/(\d{2})(\d{2})/(\d{6})$').firstMatch(input);
    if (m == null) return null;

    final startShort = int.parse(m.group(2)!);
    final endShort = int.parse(m.group(3)!);
    // The two halves must be consecutive years, with a century wrap allowed.
    if ((startShort + 1) % 100 != endShort) return null;

    final seq = int.parse(m.group(4)!);
    if (seq < 1) return null;

    // Resolve the two-digit year into a century. Anything from 70 on is 1900s,
    // which keeps this working either side of 2000 without a config knob.
    final startYear = startShort >= 70 ? 1900 + startShort : 2000 + startShort;

    return InvoiceNo(
      devicePrefix: m.group(1)!,
      fy: FinancialYear(startYear),
      seq: seq,
    );
  }

  /// A device letter is one character, A to Z. Lowercase is accepted and
  /// upper-cased, since the owner types it during setup.
  static bool isValidDevicePrefix(String prefix) =>
      RegExp(r'^[A-Za-z]$').hasMatch(prefix);

  @override
  bool operator ==(Object other) =>
      other is InvoiceNo &&
      other.devicePrefix == devicePrefix &&
      other.fy == fy &&
      other.seq == seq;

  @override
  int get hashCode => Object.hash(devicePrefix, fy, seq);

  @override
  String toString() => formatted;
}

/// Where the next sequence comes from.
///
/// The sequence restarts at 1 each financial year. The device row holds the
/// year it last wrote so a rollover is detected without a scheduled job: the
/// first bill on or after 1 April simply sees that the year has moved on.
///
/// This is pure arithmetic. Claiming the number and storing it back happen
/// inside the sale transaction, in `data/`.
class SequenceState {
  const SequenceState({required this.fy, required this.nextSeq});

  final FinancialYear fy;

  /// The sequence the next bill will take. 1 on a fresh device.
  final int nextSeq;

  /// What the sequence should be for a bill on [date].
  ///
  /// Same financial year: carry on. New financial year: back to 1.
  SequenceState forDate(BusinessDate date) {
    final target = date.financialYear;
    if (target == fy) return this;
    if (target < fy) {
      // A bill dated before the current financial year would reuse numbers that
      // are already issued. The clock has gone backwards, or someone has typed
      // the wrong date.
      throw InvoiceNumberError(
        'Cannot write a bill dated ${date.iso} (${target.label}) when this '
        'device has already billed in ${fy.label}.',
      );
    }
    return SequenceState(fy: target, nextSeq: 1);
  }

  /// The state after claiming the current number.
  SequenceState get advanced =>
      SequenceState(fy: fy, nextSeq: nextSeq + 1);

  @override
  bool operator ==(Object other) =>
      other is SequenceState && other.fy == fy && other.nextSeq == nextSeq;

  @override
  int get hashCode => Object.hash(fy, nextSeq);

  @override
  String toString() => '${fy.label}#$nextSeq';
}
