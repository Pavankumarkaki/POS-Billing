/// Reading bills back: the list at the counter and the detail behind it.
///
/// Separate from [BillRepository], which writes. This only reads, so nothing
/// here can alter a bill, and a screen that only lists cannot accidentally be
/// given something that mutates.
///
/// Everything groups by `business_date`, never by `created_at`. A bill rung up
/// at 1 AM belongs to the night before, and a list that disagrees with the
/// reports would be worse than useless.
library;

import 'package:drift/drift.dart';

import '../core/business_date.dart';
import '../core/domain.dart';
import '../core/money.dart';
import '../core/tax.dart';
import 'db.dart';

/// One row in the bills list.
class BillListEntry {
  const BillListEntry({
    required this.bill,
    required this.paymentModes,
    required this.itemCount,
  });

  final BillRow bill;

  /// Every mode used, so a split shows as "Cash · UPI".
  final List<PaymentMode> paymentModes;

  /// Total plates, not lines.
  final int itemCount;

  bool get isCancelled => bill.status == BillStatus.cancelled;

  /// `Dine in · Cash`, or `Takeaway · Cash · UPI` for a split.
  String get summary {
    final type = switch (bill.orderType) {
      OrderType.dine => 'Dine in',
      OrderType.takeaway => 'Takeaway',
      OrderType.aggregator => 'Online',
    };
    final modes = paymentModes.map(_modeLabel).join(' · ');
    return modes.isEmpty ? type : '$type · $modes';
  }

  static String _modeLabel(PaymentMode m) => switch (m) {
        PaymentMode.cash => 'Cash',
        PaymentMode.upi => 'UPI',
        PaymentMode.card => 'Card',
        PaymentMode.aggregator => 'Aggregator',
        PaymentMode.credit => 'Credit',
      };
}

/// What the header above the list shows.
class DaySummary {
  const DaySummary({
    required this.paidCount,
    required this.cancelledCount,
    required this.total,
  });

  /// Bills that count toward sales. Cancelled ones are excluded.
  final int paidCount;

  /// Shown separately, because "4 cancelled" is information the owner wants
  /// without it polluting the sales figure.
  final int cancelledCount;

  /// Sum of paid bills only.
  final Paise total;
}

/// How the list is filtered.
enum BillFilter {
  all,
  cash,
  upi,
  card,
  cancelled;

  String get label => switch (this) {
        all => 'All',
        cash => 'Cash',
        upi => 'UPI',
        card => 'Card',
        cancelled => 'Cancelled',
      };
}

class BillsQuery {
  BillsQuery(this._db);

  final PosDatabase _db;

  /// Bills for one business day, newest first.
  ///
  /// Newest first because at a counter the bill someone is asking about is
  /// almost always the last one.
  Future<List<BillListEntry>> forDay(
    BusinessDate day, {
    BillFilter filter = BillFilter.all,
  }) async {
    final bills = await (_db.select(_db.bills)
          ..where((b) => b.businessDate.equals(day.iso))
          ..orderBy([(b) => OrderingTerm.desc(b.deviceSeq)]))
        .get();

    return _decorate(bills, filter);
  }

  /// Bills across a range of business days, newest first.
  Future<List<BillListEntry>> forRange(
    BusinessDate from,
    BusinessDate to, {
    BillFilter filter = BillFilter.all,
  }) async {
    // Business dates are stored as `YYYY-MM-DD`, which sorts and compares
    // correctly as text, so a range is a plain string comparison.
    final bills = await (_db.select(_db.bills)
          ..where((b) =>
              b.businessDate.isBiggerOrEqualValue(from.iso) &
              b.businessDate.isSmallerOrEqualValue(to.iso))
          ..orderBy([
            (b) => OrderingTerm.desc(b.businessDate),
            (b) => OrderingTerm.desc(b.deviceSeq),
          ]))
        .get();

    return _decorate(bills, filter);
  }

  /// Finds a bill by the number a customer quotes.
  Future<BillRow?> byInvoiceNo(String invoiceNo) =>
      (_db.select(_db.bills)
            ..where((b) => b.invoiceNo.equals(invoiceNo.trim().toUpperCase())))
          .getSingleOrNull();

  /// The header figures for a day.
  ///
  /// Cancelled bills are excluded from the total, as the brief requires, but
  /// counted separately so they do not simply disappear.
  Future<DaySummary> summaryFor(BusinessDate day) async {
    final bills = await (_db.select(_db.bills)
          ..where((b) => b.businessDate.equals(day.iso)))
        .get();

    var total = Paise.zero;
    var paid = 0;
    var cancelled = 0;
    for (final b in bills) {
      if (b.status == BillStatus.cancelled) {
        cancelled++;
        continue;
      }
      paid++;
      total += b.total;
    }

    return DaySummary(
      paidCount: paid,
      cancelledCount: cancelled,
      total: total,
    );
  }

  /// Every business day that has a bill, newest first. For a day picker.
  Future<List<BusinessDate>> daysWithBills({int limit = 60}) async {
    final rows = await _db
        .customSelect(
          'SELECT DISTINCT business_date FROM bill '
          'ORDER BY business_date DESC LIMIT ?',
          variables: [Variable.withInt(limit)],
        )
        .get();

    return [
      for (final r in rows)
        ?BusinessDate.tryParse(r.read<String>('business_date')),
    ];
  }

  /// The audit trail for one bill, oldest first.
  ///
  /// Shown on the detail panel so the owner can see that a reprint or a
  /// cancellation was recorded, rather than having to trust that it was.
  Future<List<AuditRow>> historyFor(String billId) => (_db.select(_db.auditLog)
        ..where((a) =>
            a.entity.equals(AuditEntity.bill.wireName) &
            a.entityId.equals(billId))
        ..orderBy([(a) => OrderingTerm.asc(a.at)]))
      .get();

  Future<List<BillListEntry>> _decorate(
    List<BillRow> bills,
    BillFilter filter,
  ) async {
    if (bills.isEmpty) return const [];

    final ids = bills.map((b) => b.id).toList();

    // Two queries for the whole page rather than two per row: a day with 200
    // bills would otherwise be 400 round trips.
    final payments = await (_db.select(_db.payments)
          ..where((p) => p.billId.isIn(ids)))
        .get();
    final lines = await (_db.select(_db.billLines)
          ..where((l) => l.billId.isIn(ids)))
        .get();

    final modesByBill = <String, List<PaymentMode>>{};
    for (final p in payments) {
      final list = modesByBill.putIfAbsent(p.billId, () => []);
      // A split across two cash tenders should read "Cash", not "Cash · Cash".
      if (!list.contains(p.mode)) list.add(p.mode);
    }

    final countByBill = <String, int>{};
    for (final l in lines) {
      countByBill[l.billId] = (countByBill[l.billId] ?? 0) + l.qty;
    }

    final entries = [
      for (final b in bills)
        BillListEntry(
          bill: b,
          paymentModes: modesByBill[b.id] ?? const [],
          itemCount: countByBill[b.id] ?? 0,
        ),
    ];

    return entries.where((e) => _matches(e, filter)).toList(growable: false);
  }

  static bool _matches(BillListEntry entry, BillFilter filter) =>
      switch (filter) {
        BillFilter.all => true,
        // A cancelled bill is excluded from the payment-mode filters: looking
        // for "today's cash" should not turn up a voided bill.
        BillFilter.cancelled => entry.isCancelled,
        BillFilter.cash =>
          !entry.isCancelled && entry.paymentModes.contains(PaymentMode.cash),
        BillFilter.upi =>
          !entry.isCancelled && entry.paymentModes.contains(PaymentMode.upi),
        BillFilter.card =>
          !entry.isCancelled && entry.paymentModes.contains(PaymentMode.card),
      };
}
