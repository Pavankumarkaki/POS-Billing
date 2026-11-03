/// Business days and financial years. Pure Dart, no clock of its own: every
/// function takes the time it should use, so tests can sit on a boundary.
///
/// A restaurant's day is not a calendar day. A bill rung up at 1 AM belongs to
/// the night before, so the day runs to a cutoff (04:00 by default) rather than
/// to midnight. Reports group by `business_date`, not by `created_at`.
library;

/// The default cutoff: a business day runs from 04:00 to 03:59 the next morning.
const Duration defaultBusinessDayCutoff = Duration(hours: 4);

/// A calendar date with no time and no zone. What `business_date` stores.
class BusinessDate implements Comparable<BusinessDate> {
  const BusinessDate(this.year, this.month, this.day);

  final int year;
  final int month;
  final int day;

  /// Which business day [at] falls in, given the outlet's [cutoff].
  ///
  /// Anything before the cutoff belongs to the previous day: with a 04:00
  /// cutoff, 3 March 01:30 is business day 2 March.
  factory BusinessDate.of(
    DateTime at, {
    Duration cutoff = defaultBusinessDayCutoff,
  }) {
    final shifted = at.subtract(cutoff);
    return BusinessDate(shifted.year, shifted.month, shifted.day);
  }

  /// Parses `"2026-03-02"`.
  static BusinessDate? tryParse(String iso) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso);
    if (m == null) return null;
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    // Reject 31 February and friends by round-tripping through DateTime.
    final probe = DateTime(y, mo, d);
    if (probe.month != mo || probe.day != d) return null;
    return BusinessDate(y, mo, d);
  }

  /// `"2026-03-02"`. Sorts correctly as text, which is why it is stored this way.
  String get iso => '${year.toString().padLeft(4, '0')}'
      '-${month.toString().padLeft(2, '0')}'
      '-${day.toString().padLeft(2, '0')}';

  /// The instant this business day starts: its own date at the cutoff.
  DateTime startsAt({Duration cutoff = defaultBusinessDayCutoff}) =>
      DateTime(year, month, day).add(cutoff);

  /// The instant the next business day starts. Half-open, so a range query is
  /// `created_at >= startsAt && created_at < endsAt` with no overlap.
  DateTime endsAt({Duration cutoff = defaultBusinessDayCutoff}) =>
      DateTime(year, month, day).add(const Duration(days: 1)).add(cutoff);

  BusinessDate addDays(int days) {
    final d = DateTime(year, month, day).add(Duration(days: days));
    return BusinessDate(d.year, d.month, d.day);
  }

  /// The financial year this day belongs to. April to March.
  FinancialYear get financialYear => FinancialYear.of(this);

  /// Monday of this day's week. The owner's week starts on Monday.
  BusinessDate get weekStart =>
      addDays(-(DateTime(year, month, day).weekday - DateTime.monday));

  BusinessDate get monthStart => BusinessDate(year, month, 1);

  @override
  int compareTo(BusinessDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  bool operator <(BusinessDate other) => compareTo(other) < 0;
  bool operator <=(BusinessDate other) => compareTo(other) <= 0;
  bool operator >(BusinessDate other) => compareTo(other) > 0;
  bool operator >=(BusinessDate other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is BusinessDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => iso;
}

/// An Indian financial year: 1 April to 31 March.
///
/// [startYear] is the calendar year it opens in, so FY 2026-27 has
/// `startYear == 2026` and its short code is `2627`.
class FinancialYear implements Comparable<FinancialYear> {
  const FinancialYear(this.startYear);

  final int startYear;

  /// The financial year a business date falls in. January to March belong to
  /// the year that opened the previous April.
  factory FinancialYear.of(BusinessDate date) =>
      FinancialYear(date.month >= 4 ? date.year : date.year - 1);

  int get endYear => startYear + 1;

  /// `"2627"` for FY 2026-27. Four characters, which is what the invoice number
  /// has room for.
  ///
  /// Uses the last two digits of each year, so it repeats every century. That
  /// is fine: invoice numbers only have to be unique *within* a financial year.
  String get code =>
      '${(startYear % 100).toString().padLeft(2, '0')}'
      '${(endYear % 100).toString().padLeft(2, '0')}';

  /// `"2026-27"`, for screens and reports.
  String get label => '$startYear-${(endYear % 100).toString().padLeft(2, '0')}';

  BusinessDate get firstDay => BusinessDate(startYear, 4, 1);
  BusinessDate get lastDay => BusinessDate(endYear, 3, 31);

  FinancialYear get next => FinancialYear(startYear + 1);

  bool contains(BusinessDate date) => date >= firstDay && date <= lastDay;

  @override
  int compareTo(FinancialYear other) => startYear.compareTo(other.startYear);

  @override
  bool operator ==(Object other) =>
      other is FinancialYear && other.startYear == startYear;

  @override
  int get hashCode => startYear.hashCode;

  @override
  String toString() => label;
}
