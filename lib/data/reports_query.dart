/// Reports, aggregated from local data. Nothing here talks to a network.
///
/// Three rules run through every figure in this file:
///
///   1. **Cancelled bills are excluded from sales.** They are counted and
///      shown separately, because "nine cancellations today" is something the
///      owner wants to know, but they are never in a sales total.
///   2. **Everything groups by `business_date`.** A bill at 1 AM belongs to
///      the night before. Grouping by `created_at` would split a trading
///      night across two days and make every figure subtly wrong.
///   3. **Aggregator GST is not the restaurant's.** Under section 9(5) the
///      aggregator pays it, so it is kept out of "GST you owe" while the
///      turnover still counts. See CA_REVIEW.md section 3.
library;

import 'package:drift/drift.dart';

import '../core/business_date.dart';
import '../core/domain.dart';
import '../core/money.dart';
import '../core/tax.dart';
import 'db.dart';

/// Sales for one business day, for the chart.
class DayPoint {
  const DayPoint({required this.day, required this.total, required this.bills});
  final BusinessDate day;
  final Paise total;
  final int bills;
}

/// How much came in by one payment mode.
class ModeTotal {
  const ModeTotal({required this.mode, required this.total, required this.count});
  final PaymentMode mode;
  final Paise total;
  final int count;
}

/// How much one item sold.
class ItemTotal {
  const ItemTotal({
    required this.name,
    required this.qty,
    required this.total,
  });

  /// The snapshotted name, so a renamed item still reports under what it was
  /// sold as. Grouping by the live menu name would quietly rewrite history.
  final String name;
  final int qty;
  final Paise total;
}

/// Tax at one rate, for the CA.
class RateTotal {
  const RateTotal({
    required this.rateBp,
    required this.taxable,
    required this.cgst,
    required this.sgst,
  });

  final int rateBp;
  final Paise taxable;
  final Paise cgst;
  final Paise sgst;

  Paise get tax => cgst + sgst;

  String get label {
    if (rateBp % 100 == 0) return '${rateBp ~/ 100}%';
    return '${(rateBp / 100).toStringAsFixed(1)}%';
  }
}

/// Everything a report shows for one period.
class SalesReport {
  const SalesReport({
    required this.from,
    required this.to,
    required this.total,
    required this.billCount,
    required this.taxable,
    required this.cgst,
    required this.sgst,
    required this.roundOff,
    required this.discount,
    required this.cancelledCount,
    required this.cancelledTotal,
    required this.byDay,
    required this.byMode,
    required this.byItem,
    required this.byRate,
    required this.aggregatorTotal,
    required this.aggregatorTax,
    required this.compositionTurnover,
    required this.docCounts,
  });

  final BusinessDate from;
  final BusinessDate to;

  /// Sales, cancelled bills excluded.
  final Paise total;
  final int billCount;

  final Paise taxable;
  final Paise cgst;
  final Paise sgst;
  final Paise roundOff;
  final Paise discount;

  /// Shown, never added in.
  final int cancelledCount;
  final Paise cancelledTotal;

  final List<DayPoint> byDay;
  final List<ModeTotal> byMode;

  /// Best sellers first.
  final List<ItemTotal> byItem;

  final List<RateTotal> byRate;

  /// Turnover through aggregators. Counted in [total].
  final Paise aggregatorTotal;

  /// Tax on aggregator orders. Zero in this app, since aggregator bills carry
  /// no tax, but kept explicit so a report can state it rather than leave the
  /// reader to assume.
  final Paise aggregatorTax;

  /// 5% of turnover under the composition scheme, for the owner's own
  /// reporting. Never charged to a customer.
  final Paise compositionTurnover;

  /// How many of each document type, which the CA asks for.
  final Map<DocType, int> docCounts;

  /// What the restaurant owes: its own GST, with aggregator tax removed.
  Paise get gstPayable => (cgst + sgst) - aggregatorTax;

  Paise get averageBill =>
      billCount == 0 ? Paise.zero : Paise(total.value ~/ billCount);
}

class ReportsQuery {
  ReportsQuery(this._db);

  final PosDatabase _db;

  /// Builds the report for a business-date range, inclusive at both ends.
  Future<SalesReport> forRange(BusinessDate from, BusinessDate to) async {
    final bills = await (_db.select(_db.bills)
          ..where((b) =>
              b.businessDate.isBiggerOrEqualValue(from.iso) &
              b.businessDate.isSmallerOrEqualValue(to.iso)))
        .get();

    // Split first, and never let the cancelled ones back in.
    final paid = <BillRow>[];
    var cancelledCount = 0;
    var cancelledTotal = Paise.zero;
    for (final b in bills) {
      if (b.status == BillStatus.cancelled) {
        cancelledCount++;
        cancelledTotal += b.total;
        continue;
      }
      paid.add(b);
    }

    final paidIds = paid.map((b) => b.id).toList();

    var total = Paise.zero;
    var taxable = Paise.zero;
    var cgst = Paise.zero;
    var sgst = Paise.zero;
    var roundOff = Paise.zero;
    var discount = Paise.zero;
    var aggregatorTotal = Paise.zero;
    var aggregatorTax = Paise.zero;
    var compositionTurnover = Paise.zero;
    final docCounts = <DocType, int>{};
    final dayTotals = <String, ({Paise total, int bills})>{};

    for (final b in paid) {
      total += b.total;
      taxable += b.taxable;
      cgst += b.cgst;
      sgst += b.sgst;
      roundOff += b.roundOff;
      discount += b.discount;
      compositionTurnover += b.compositionTurnover;

      if (b.orderType == OrderType.aggregator) {
        aggregatorTotal += b.total;
        aggregatorTax += b.cgst + b.sgst;
      }

      docCounts[b.docType] = (docCounts[b.docType] ?? 0) + 1;

      final key = b.businessDate.iso;
      final existing = dayTotals[key];
      dayTotals[key] = (
        total: (existing?.total ?? Paise.zero) + b.total,
        bills: (existing?.bills ?? 0) + 1,
      );
    }

    return SalesReport(
      from: from,
      to: to,
      total: total,
      billCount: paid.length,
      taxable: taxable,
      cgst: cgst,
      sgst: sgst,
      roundOff: roundOff,
      discount: discount,
      cancelledCount: cancelledCount,
      cancelledTotal: cancelledTotal,
      byDay: _daySeries(from, to, dayTotals),
      byMode: await _byMode(paidIds),
      byItem: await _byItem(paidIds),
      byRate: await _byRate(paidIds),
      aggregatorTotal: aggregatorTotal,
      aggregatorTax: aggregatorTax,
      compositionTurnover: compositionTurnover,
      docCounts: docCounts,
    );
  }

  /// Turnover so far in [fy], for the threshold warnings.
  ///
  /// Cancelled bills excluded, aggregator sales included. Whether aggregator
  /// turnover should count toward the thresholds is the question CA_REVIEW.md
  /// section 3 flags as the one I am least sure of.
  Future<Paise> turnoverForYear(FinancialYear fy) async {
    final bills = await (_db.select(_db.bills)
          ..where((b) =>
              b.fy.equals(fy.code) &
              b.status.equals(BillStatus.paid.wireName)))
        .get();

    var sum = Paise.zero;
    for (final b in bills) {
      sum += b.total;
    }
    return sum;
  }

  /// Every day in the range, including days with no sales.
  ///
  /// A chart that silently drops the quiet days reads as if the restaurant
  /// never closed, and makes a bad week look like a good one.
  List<DayPoint> _daySeries(
    BusinessDate from,
    BusinessDate to,
    Map<String, ({Paise total, int bills})> totals,
  ) {
    final points = <DayPoint>[];
    var day = from;
    // A guard, so a reversed or absurd range cannot spin forever.
    for (var i = 0; i < 400 && day <= to; i++) {
      final hit = totals[day.iso];
      points.add(DayPoint(
        day: day,
        total: hit?.total ?? Paise.zero,
        bills: hit?.bills ?? 0,
      ));
      day = day.addDays(1);
    }
    return points;
  }

  Future<List<ModeTotal>> _byMode(List<String> billIds) async {
    if (billIds.isEmpty) return const [];

    final rows = await (_db.select(_db.payments)
          ..where((p) => p.billId.isIn(billIds)))
        .get();

    final totals = <PaymentMode, ({Paise total, int count})>{};
    for (final p in rows) {
      final e = totals[p.mode];
      totals[p.mode] = (
        total: (e?.total ?? Paise.zero) + p.amount,
        count: (e?.count ?? 0) + 1,
      );
    }

    final list = [
      for (final e in totals.entries)
        ModeTotal(mode: e.key, total: e.value.total, count: e.value.count),
    ]..sort((a, b) => b.total.value.compareTo(a.total.value));
    return list;
  }

  Future<List<ItemTotal>> _byItem(List<String> billIds) async {
    if (billIds.isEmpty) return const [];

    final rows = await (_db.select(_db.billLines)
          ..where((l) => l.billId.isIn(billIds)))
        .get();

    // Grouped by the snapshotted name, not by item id: if the owner renames
    // an item, last month's report should still show what it was called when
    // it sold. Grouping by id would relabel history.
    final totals = <String, ({int qty, Paise total})>{};
    for (final l in rows) {
      final e = totals[l.nameSnapshot];
      totals[l.nameSnapshot] = (
        qty: (e?.qty ?? 0) + l.qty,
        total: (e?.total ?? Paise.zero) + l.lineTotal,
      );
    }

    final list = [
      for (final e in totals.entries)
        ItemTotal(name: e.key, qty: e.value.qty, total: e.value.total),
    ]..sort((a, b) => b.qty.compareTo(a.qty));
    return list;
  }

  Future<List<RateTotal>> _byRate(List<String> billIds) async {
    if (billIds.isEmpty) return const [];

    final rows = await (_db.select(_db.billLines)
          ..where((l) => l.billId.isIn(billIds)))
        .get();

    // From the stored per-line splits, not recomputed. A report of last
    // year's sales must use last year's rates.
    final totals = <int, ({Paise taxable, Paise cgst, Paise sgst})>{};
    for (final l in rows) {
      final e = totals[l.taxRate];
      totals[l.taxRate] = (
        taxable: (e?.taxable ?? Paise.zero) + l.taxable,
        cgst: (e?.cgst ?? Paise.zero) + l.cgst,
        sgst: (e?.sgst ?? Paise.zero) + l.sgst,
      );
    }

    final list = [
      for (final e in totals.entries)
        RateTotal(
          rateBp: e.key,
          taxable: e.value.taxable,
          cgst: e.value.cgst,
          sgst: e.value.sgst,
        ),
    ]..sort((a, b) => a.rateBp.compareTo(b.rateBp));
    return list;
  }
}
