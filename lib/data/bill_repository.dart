/// Saving, cancelling and reprinting bills.
///
/// This file owns the brief's hardest rules, so they live in one place where
/// they can be read together and tested together:
///
///   - a paid bill is immutable: no amount or line is ever updated, and no bill
///     is ever deleted. There is no method here that does either.
///   - cancelling keeps the invoice number and records status, reason and user.
///   - the bill, its lines, its payments, the audit entry, the outbox entry and
///     the sequence increment all commit in ONE transaction.
///   - printing happens after the commit returns, never inside it.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/business_date.dart';
import '../core/domain.dart';
import '../core/invoice_no.dart';
import '../core/money.dart';
import '../core/tax.dart';
import 'db.dart';
import 'tables.dart';

/// Thrown when a sale cannot be saved. Always thrown *inside* the transaction,
/// so the whole thing rolls back and no number is consumed.
class SaleError implements Exception {
  SaleError(this.message);
  final String message;
  @override
  String toString() => 'SaleError: $message';
}

/// Thrown when the user's role does not permit the action.
class PermissionDenied implements Exception {
  PermissionDenied(this.permission, this.role);
  final Permission permission;
  final UserRole role;
  @override
  String toString() =>
      'PermissionDenied: a ${role.wireName} may not ${permission.name}';
}

/// One tender against a bill. Several make a split payment.
class PaymentIntent {
  const PaymentIntent(this.mode, this.amount);
  final PaymentMode mode;
  final Paise amount;
}

/// What a completed sale returns. Enough to print from, with no further reads.
class SavedBill {
  const SavedBill({
    required this.id,
    required this.invoiceNo,
    required this.deviceSeq,
    required this.businessDate,
    required this.createdAt,
    required this.computed,
    required this.payments,
  });

  final String id;
  final InvoiceNo invoiceNo;
  final int deviceSeq;
  final BusinessDate businessDate;
  final DateTime createdAt;
  final ComputedBill computed;
  final List<PaymentIntent> payments;
}

/// A hook that lets a test make the transaction fail at a chosen point.
///
/// The brief requires proving that a failed save leaves no partial bill and no
/// skipped number. Doing that needs a failure *between* the six writes, which
/// is impossible to arrange from outside. So the seam is explicit and named
/// rather than simulated by corrupting data.
enum SaleStage {
  afterSequenceClaim,
  afterBillInsert,
  afterLinesInsert,
  afterPaymentsInsert,
  afterAuditInsert,
  afterOutboxInsert,
}

typedef SaleFailureHook = void Function(SaleStage stage);

class BillRepository {
  BillRepository(this._db, {Uuid? uuid, DateTime Function()? clock})
      : _uuid = uuid ?? const Uuid(),
        _clock = clock ?? DateTime.now;

  final PosDatabase _db;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// UUIDv7: time-ordered, so bills sort by creation and a future sync has
  /// globally unique ids without coordination.
  String _newId() => _uuid.v7();

  /// Saves a sale. Everything or nothing.
  ///
  /// [failAt] is for tests only; production never passes it.
  Future<SavedBill> commitSale({
    required ComputedBill computed,
    required List<PaymentIntent> payments,
    required String deviceId,
    required String userId,
    DateTime? at,
    SaleFailureHook? failAt,
  }) async {
    final now = at ?? _clock();

    // --- checks that do not need the transaction -----------------------
    if (computed.lines.isEmpty) {
      throw SaleError('A bill must have at least one line.');
    }
    if (payments.isEmpty) {
      throw SaleError('A bill must record at least one payment.');
    }
    if (payments.any((p) => p.amount.isNegative)) {
      throw SaleError('A payment cannot be negative.');
    }
    final paid = payments.fold(Paise.zero, (Paise s, p) => s + p.amount);
    if (paid.value != computed.total.value) {
      throw SaleError(
        'Payments come to ${paid.rupees} but the bill is '
        '${computed.total.rupees}. They must match exactly.',
      );
    }

    return _db.transaction(() async {
      // The FSSAI gate. Checked inside the transaction and against the stored
      // row, not against whatever the UI thinks, because the brief says
      // billing is blocked until a valid number is saved.
      final outlet = await _db.select(_db.outlets).getSingleOrNull();
      if (outlet == null) {
        throw SaleError('Finish first-run setup before billing.');
      }
      if (!isValidFssai(outlet.fssaiNo)) {
        throw SaleError(
          'A valid 14-digit FSSAI number must be saved before billing.',
        );
      }

      final device = await (_db.select(_db.devices)
            ..where((d) => d.id.equals(deviceId)))
          .getSingleOrNull();
      if (device == null) {
        throw SaleError('Unknown device "$deviceId".');
      }

      final user = await (_db.select(_db.users)
            ..where((u) => u.id.equals(userId)))
          .getSingleOrNull();
      if (user == null) {
        throw SaleError('Unknown user "$userId".');
      }
      if (!user.isActive) {
        throw SaleError('${user.name} is no longer an active user.');
      }
      if (!Permission.createBill.allows(user.role)) {
        throw PermissionDenied(Permission.createBill, user.role);
      }

      final cutoff = Duration(minutes: outlet.businessDayCutoffMinutes);
      final businessDate = BusinessDate.of(now, cutoff: cutoff);

      // --- 1. claim the sequence --------------------------------------
      // Inside the transaction, so two concurrent sales cannot take the same
      // number: the second blocks on the write lock and then reads the
      // incremented value.
      final state = SequenceState(fy: device.seqFy, nextSeq: device.nextSeq)
          .forDate(businessDate);

      final invoiceNo = InvoiceNo.build(
        devicePrefix: device.seriesPrefix,
        fy: state.fy,
        seq: state.nextSeq,
      );

      await (_db.update(_db.devices)..where((d) => d.id.equals(deviceId)))
          .write(DevicesCompanion(
        nextSeq: Value(state.advanced.nextSeq),
        seqFy: Value(state.fy),
      ));
      failAt?.call(SaleStage.afterSequenceClaim);

      // --- 2. the bill -------------------------------------------------
      final billId = _newId();
      await _db.into(_db.bills).insert(BillsCompanion.insert(
            id: billId,
            deviceId: deviceId,
            deviceSeq: state.nextSeq,
            invoiceNo: invoiceNo.formatted,
            fy: state.fy,
            businessDate: businessDate,
            docType: computed.docType,
            createdAt: now,
            status: BillStatus.paid,
            orderType: computed.orderType,
            subtotal: computed.subtotal,
            discount: computed.discount,
            taxable: computed.taxable,
            cgst: computed.cgst,
            sgst: computed.sgst,
            roundOff: computed.roundOff,
            total: computed.total,
            createdBy: userId,
            compositionTurnover: Value(computed.compositionTurnover),
          ));
      failAt?.call(SaleStage.afterBillInsert);

      // --- 3. the lines, each a snapshot -------------------------------
      await _db.batch((b) {
        b.insertAll(
          _db.billLines,
          [
            for (final l in computed.lines)
              BillLinesCompanion.insert(
                id: _newId(),
                billId: billId,
                itemId: l.itemId,
                nameSnapshot: l.nameSnapshot,
                nameTeSnapshot: Value(l.nameTeSnapshot),
                qty: l.qty,
                unitPrice: l.unitPrice,
                taxRate: l.taxRateBp,
                lineDiscount: l.lineDiscount,
                lineTotal: l.lineTotal,
                taxable: l.taxable,
                cgst: l.cgst,
                sgst: l.sgst,
              ),
          ],
        );
      });
      failAt?.call(SaleStage.afterLinesInsert);

      // --- 4. the payments ---------------------------------------------
      await _db.batch((b) {
        b.insertAll(
          _db.payments,
          [
            for (final pay in payments)
              PaymentsCompanion.insert(
                id: _newId(),
                billId: billId,
                mode: pay.mode,
                amount: pay.amount,
              ),
          ],
        );
      });
      failAt?.call(SaleStage.afterPaymentsInsert);

      // --- 5. the audit entry ------------------------------------------
      final snapshot = _billJson(
        invoiceNo: invoiceNo.formatted,
        computed: computed,
        payments: payments,
        businessDate: businessDate,
        createdAt: now,
        userId: userId,
        status: BillStatus.paid,
      );

      await _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: _newId(),
            at: now,
            userId: Value(userId),
            deviceId: deviceId,
            action: AuditAction.billCreated,
            entity: AuditEntity.bill,
            entityId: billId,
            // A create has no before state.
            after: Value(jsonEncode(snapshot)),
          ));
      failAt?.call(SaleStage.afterAuditInsert);

      // --- 6. the outbox entry -----------------------------------------
      // Nothing reads this in Phase 1. It is written so a later sync phase
      // finds the history already there.
      await _db.into(_db.outbox).insert(OutboxCompanion.insert(
            opId: _newId(),
            entity: AuditEntity.bill,
            payload: jsonEncode({'op': 'bill_created', 'bill': snapshot}),
            createdAt: now,
          ));
      failAt?.call(SaleStage.afterOutboxInsert);

      return SavedBill(
        id: billId,
        invoiceNo: invoiceNo,
        deviceSeq: state.nextSeq,
        businessDate: businessDate,
        createdAt: now,
        computed: computed,
        payments: payments,
      );
    });
  }

  /// Cancels a bill. Owner only, and a reason is required.
  ///
  /// Keeps the invoice number, the lines and every amount exactly as they were:
  /// the only columns written are `status`, `cancel_reason` and `cancelled_by`.
  /// Reports exclude cancelled bills from sales totals, so the money is taken
  /// out of the figures without being taken out of the records.
  Future<void> cancelBill({
    required String billId,
    required String reason,
    required String userId,
    required String deviceId,
    DateTime? at,
  }) async {
    final now = at ?? _clock();
    final trimmed = reason.trim();
    if (trimmed.isEmpty) {
      throw SaleError('Cancelling a bill needs a reason.');
    }

    await _db.transaction(() async {
      final user = await (_db.select(_db.users)
            ..where((u) => u.id.equals(userId)))
          .getSingleOrNull();
      if (user == null) throw SaleError('Unknown user "$userId".');
      if (!Permission.cancelBill.allows(user.role)) {
        throw PermissionDenied(Permission.cancelBill, user.role);
      }

      final bill = await (_db.select(_db.bills)
            ..where((b) => b.id.equals(billId)))
          .getSingleOrNull();
      if (bill == null) throw SaleError('No bill with id "$billId".');
      if (bill.status == BillStatus.cancelled) {
        throw SaleError('${bill.invoiceNo} is already cancelled.');
      }

      final before = _rowJson(bill);

      await (_db.update(_db.bills)..where((b) => b.id.equals(billId)))
          .write(BillsCompanion(
        status: const Value(BillStatus.cancelled),
        cancelReason: Value(trimmed),
        cancelledBy: Value(userId),
      ));

      final after = <String, Object?>{
        ...before,
        'status': BillStatus.cancelled.wireName,
        'cancel_reason': trimmed,
        'cancelled_by': userId,
      };

      await _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: _newId(),
            at: now,
            userId: Value(userId),
            deviceId: deviceId,
            action: AuditAction.billCancelled,
            entity: AuditEntity.bill,
            entityId: billId,
            before: Value(jsonEncode(before)),
            after: Value(jsonEncode(after)),
          ));

      await _db.into(_db.outbox).insert(OutboxCompanion.insert(
            opId: _newId(),
            entity: AuditEntity.bill,
            payload: jsonEncode({
              'op': 'bill_cancelled',
              'bill_id': billId,
              'invoice_no': bill.invoiceNo,
              'reason': trimmed,
              'by': userId,
            }),
            createdAt: now,
          ));
    });
  }

  /// Records that a bill was reprinted. The receipt itself is marked DUPLICATE
  /// by the renderer; this is the log the brief requires.
  ///
  /// Writes nothing to the bill, so a reprint cannot alter it.
  Future<void> recordReprint({
    required String billId,
    required String userId,
    required String deviceId,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    await _db.transaction(() async {
      final user = await (_db.select(_db.users)
            ..where((u) => u.id.equals(userId)))
          .getSingleOrNull();
      if (user == null) throw SaleError('Unknown user "$userId".');
      if (!Permission.reprintBill.allows(user.role)) {
        throw PermissionDenied(Permission.reprintBill, user.role);
      }

      final bill = await (_db.select(_db.bills)
            ..where((b) => b.id.equals(billId)))
          .getSingleOrNull();
      if (bill == null) throw SaleError('No bill with id "$billId".');

      await _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: _newId(),
            at: now,
            userId: Value(userId),
            deviceId: deviceId,
            action: AuditAction.billReprinted,
            entity: AuditEntity.bill,
            entityId: billId,
            after: Value(jsonEncode({
              'invoice_no': bill.invoiceNo,
              'marked': 'DUPLICATE',
              'by': userId,
              'at': now.toIso8601String(),
            })),
          ));
    });
  }

  /// A bill with its lines and payments, for the detail panel and for a
  /// reprint. Read-only.
  Future<FullBill?> loadBill(String billId) async {
    final bill = await (_db.select(_db.bills)
          ..where((b) => b.id.equals(billId)))
        .getSingleOrNull();
    if (bill == null) return null;

    final lines = await (_db.select(_db.billLines)
          ..where((l) => l.billId.equals(billId)))
        .get();
    final pays = await (_db.select(_db.payments)
          ..where((p) => p.billId.equals(billId)))
        .get();

    return FullBill(bill: bill, lines: lines, payments: pays);
  }

  Map<String, Object?> _rowJson(BillRow b) => {
        'id': b.id,
        'invoice_no': b.invoiceNo,
        'device_id': b.deviceId,
        'device_seq': b.deviceSeq,
        'fy': b.fy.code,
        'business_date': b.businessDate.iso,
        'doc_type': b.docType.wireName,
        'order_type': b.orderType.wireName,
        'status': b.status.wireName,
        'created_at': b.createdAt.toIso8601String(),
        'created_by': b.createdBy,
        'subtotal': b.subtotal.value,
        'discount': b.discount.value,
        'taxable': b.taxable.value,
        'cgst': b.cgst.value,
        'sgst': b.sgst.value,
        'round_off': b.roundOff.value,
        'total': b.total.value,
        'cancel_reason': b.cancelReason,
        'cancelled_by': b.cancelledBy,
      };

  Map<String, Object?> _billJson({
    required String invoiceNo,
    required ComputedBill computed,
    required List<PaymentIntent> payments,
    required BusinessDate businessDate,
    required DateTime createdAt,
    required String userId,
    required BillStatus status,
  }) =>
      {
        'invoice_no': invoiceNo,
        'business_date': businessDate.iso,
        'created_at': createdAt.toIso8601String(),
        'created_by': userId,
        'status': status.wireName,
        'doc_type': computed.docType.wireName,
        'order_type': computed.orderType.wireName,
        'subtotal': computed.subtotal.value,
        'discount': computed.discount.value,
        'taxable': computed.taxable.value,
        'cgst': computed.cgst.value,
        'sgst': computed.sgst.value,
        'round_off': computed.roundOff.value,
        'total': computed.total.value,
        'composition_turnover': computed.compositionTurnover.value,
        'lines': [
          for (final l in computed.lines)
            {
              'item_id': l.itemId,
              'name': l.nameSnapshot,
              'name_te': l.nameTeSnapshot,
              'qty': l.qty,
              'unit_price': l.unitPrice.value,
              'tax_rate_bp': l.taxRateBp,
              'line_discount': l.lineDiscount.value,
              'taxable': l.taxable.value,
              'cgst': l.cgst.value,
              'sgst': l.sgst.value,
              'line_total': l.lineTotal.value,
            },
        ],
        'payments': [
          for (final p in payments)
            {'mode': p.mode.wireName, 'amount': p.amount.value},
        ],
      };
}

/// A bill with everything needed to print or display it.
class FullBill {
  const FullBill({
    required this.bill,
    required this.lines,
    required this.payments,
  });

  final BillRow bill;
  final List<BillLineRow> lines;
  final List<PaymentRow> payments;
}

/// An FSSAI licence number is exactly 14 digits.
///
/// The brief requires blocking billing until a valid one is saved, and showing
/// it on every bill in every tax mode. Only the shape is checked; whether the
/// licence is real is beyond the app.
bool isValidFssai(String value) =>
    RegExp(r'^\d{14}$').hasMatch(value.trim());
