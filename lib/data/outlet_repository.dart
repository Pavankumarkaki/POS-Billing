/// Editing the details that print on every bill, after first-run setup.
///
/// Three fields, the ones the design's Settings artboard shows: the tax type,
/// the FSSAI licence number and the GSTIN. Until now they could only be set
/// during setup, which meant a typo in the FSSAI number cost a reinstall, and
/// a reinstall costs the data.
///
/// Two things here are more than they look:
///
///   1. **A tax mode change is dated, not just stored.** `outlet.tax_mode` is
///      only today's answer. A bill from two years ago has to stay explicable,
///      so every change writes `tax_profile_history` with the business date it
///      took effect, and [taxModeOn] reads it back. That table was written at
///      setup and never read before this; it exists precisely for the case
///      this file introduces, which is an outlet crossing the registration
///      threshold mid-year and switching from unregistered to regular GST.
///
///   2. **Past bills do not move.** Every bill stores its own amounts, tax
///      splits and document type at the moment it was rung up, so changing the
///      mode today cannot rewrite what a bill said last April. That is rule 3
///      in the README and it is what makes this change safe to allow at all.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/business_date.dart';
import '../core/domain.dart';
import '../core/tax.dart';
import 'bill_repository.dart' show isValidFssai;
import 'db.dart';
import 'setup_repository.dart' show isValidGstin;

/// Thrown when the details cannot be saved. Carries something the owner can
/// act on, because it is shown to them as it is.
class OutletError implements Exception {
  OutletError(this.message);
  final String message;

  @override
  String toString() => 'OutletError: $message';
}

/// What the Bill details card edits.
class BillDetails {
  const BillDetails({
    required this.fssaiNo,
    required this.taxMode,
    this.gstin,
  });

  final String fssaiNo;
  final TaxMode taxMode;

  /// Null or empty when the outlet is not registered.
  final String? gstin;

  /// A GSTIN belongs on a registered outlet, composition included: a
  /// composition dealer IS registered, and their bill of supply carries it.
  /// Only an unregistered outlet has none.
  static bool modeHasGstin(TaxMode mode) => mode != TaxMode.unregistered;

  /// Whether a GSTIN is required rather than merely allowed.
  static bool modeRequiresGstin(TaxMode mode) =>
      mode == TaxMode.regular5 || mode == TaxMode.regular18;

  BillDetails copyWith({
    String? fssaiNo,
    TaxMode? taxMode,
    String? gstin,
    bool clearGstin = false,
  }) =>
      BillDetails(
        fssaiNo: fssaiNo ?? this.fssaiNo,
        taxMode: taxMode ?? this.taxMode,
        gstin: clearGstin ? null : (gstin ?? this.gstin),
      );
}

class OutletRepository {
  OutletRepository(
    this._db, {
    this.clock = DateTime.now,
    this.uuid = const Uuid(),
  });

  final PosDatabase _db;

  /// The clock, so a test can pin the business date a tax change lands on.
  final DateTime Function() clock;
  final Uuid uuid;

  /// What is on the outlet row now.
  Future<BillDetails?> current() async {
    final outlet = await _db.select(_db.outlets).getSingleOrNull();
    if (outlet == null) return null;
    return BillDetails(
      fssaiNo: outlet.fssaiNo,
      taxMode: outlet.taxMode,
      gstin: outlet.gstin,
    );
  }

  /// A stream, so the settings screen and anything else reading the outlet
  /// agree without either having to remember to refresh.
  Stream<BillDetails?> watch() =>
      _db.select(_db.outlets).watchSingleOrNull().map((outlet) {
        if (outlet == null) return null;
        return BillDetails(
          fssaiNo: outlet.fssaiNo,
          taxMode: outlet.taxMode,
          gstin: outlet.gstin,
        );
      });

  /// Problems with [d], in the owner's words. Empty when it can be saved.
  ///
  /// Deliberately the same rules as first-run setup. A number that setup would
  /// have refused must not become saveable just because it is being edited
  /// later, and in particular billing must stay blocked without a valid FSSAI.
  List<String> validate(BillDetails d) {
    final problems = <String>[];

    if (!isValidFssai(d.fssaiNo)) {
      problems.add('The FSSAI licence number must be exactly 14 digits.');
    }

    final gstin = d.gstin?.trim() ?? '';
    if (BillDetails.modeRequiresGstin(d.taxMode) && gstin.isEmpty) {
      problems.add('A GSTIN is required when registered under regular GST.');
    }
    if (gstin.isNotEmpty && !isValidGstin(gstin)) {
      problems.add('That GSTIN is not 15 characters in the expected format.');
    }

    return problems;
  }

  /// Saves the bill details. Owner only.
  ///
  /// One transaction: the outlet row, the dated tax profile when the mode
  /// changed, and the audit entry with before and after. Returns true when
  /// something actually changed, so the screen can say "Saved" honestly rather
  /// than for a tap that did nothing.
  Future<bool> updateBillDetails(
    BillDetails d, {
    required String byUserId,
    DateTime? at,
  }) async {
    final problems = validate(d);
    if (problems.isNotEmpty) throw OutletError(problems.join(' '));

    final now = at ?? clock();

    return _db.transaction(() async {
      final by = await (_db.select(_db.users)
            ..where((u) => u.id.equals(byUserId)))
          .getSingleOrNull();
      if (by == null || !Permission.changeSettings.allows(by.role)) {
        throw OutletError('Only the owner can change the bill details.');
      }

      final outlet = await _db.select(_db.outlets).getSingleOrNull();
      if (outlet == null) {
        throw OutletError('Finish first-run setup first.');
      }

      // An unregistered outlet must not print a GSTIN, and the receipt decides
      // that purely from whether one is stored. So moving to unregistered
      // clears it rather than leaving a number that would print on a bill the
      // outlet has no registration for.
      final gstin = BillDetails.modeHasGstin(d.taxMode)
          ? (d.gstin?.trim().toUpperCase().isEmpty ?? true
              ? null
              : d.gstin!.trim().toUpperCase())
          : null;
      final fssai = d.fssaiNo.trim();

      final modeChanged = outlet.taxMode != d.taxMode;
      final changed = modeChanged ||
          outlet.fssaiNo != fssai ||
          outlet.gstin != gstin;
      if (!changed) return false;

      final before = <String, Object?>{
        'tax_mode': outlet.taxMode.wireName,
        'fssai_no': outlet.fssaiNo,
        'gstin': outlet.gstin,
      };

      await (_db.update(_db.outlets)..where((o) => o.id.equals(outlet.id)))
          .write(OutletsCompanion(
        fssaiNo: Value(fssai),
        taxMode: Value(d.taxMode),
        gstin: Value(gstin),
      ));

      if (modeChanged) {
        await _recordTaxProfile(
          outletId: outlet.id,
          mode: d.taxMode,
          day: BusinessDate.of(
            now,
            cutoff: Duration(minutes: outlet.businessDayCutoffMinutes),
          ),
        );
      }

      await _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: uuid.v7(),
            at: now,
            userId: Value(byUserId),
            deviceId: await _deviceId(),
            // A tax mode change is a different kind of event from a typo fix
            // in the licence number, and the CA may want to find one without
            // the other.
            action: modeChanged
                ? AuditAction.taxModeChanged
                : AuditAction.settingChanged,
            entity: AuditEntity.outlet,
            entityId: outlet.id,
            before: Value(jsonEncode(before)),
            after: Value(jsonEncode({
              'tax_mode': d.taxMode.wireName,
              'fssai_no': fssai,
              'gstin': gstin,
            })),
          ));

      return true;
    });
  }

  /// Writes the dated tax profile, replacing any row already dated [day].
  ///
  /// Replacing rather than appending, because this table answers "which mode
  /// applied on this date" and that has to be one value. An owner who switches
  /// mode and switches back within the same day would otherwise leave two rows
  /// for one day and no way to tell which won. Every individual change is
  /// still in the audit log, which is where the flip-flop belongs.
  Future<void> _recordTaxProfile({
    required String outletId,
    required TaxMode mode,
    required BusinessDate day,
  }) async {
    await (_db.delete(_db.taxProfileHistory)
          ..where((t) =>
              t.outletId.equals(outletId) & t.effectiveFrom.equals(day.iso)))
        .go();

    await _db.into(_db.taxProfileHistory).insert(
          TaxProfileHistoryCompanion.insert(
            id: uuid.v7(),
            outletId: outletId,
            taxMode: mode,
            effectiveFrom: day,
          ),
        );
  }

  /// Which tax mode applied on [day].
  ///
  /// The latest profile dated on or before that day. Null when the outlet was
  /// not set up yet, which is the honest answer for a date before it existed.
  Future<TaxMode?> taxModeOn(BusinessDate day) async {
    final row = await (_db.select(_db.taxProfileHistory)
          ..where((t) => t.effectiveFrom.isSmallerOrEqualValue(day.iso))
          ..orderBy([
            (t) => OrderingTerm.desc(t.effectiveFrom),
            // Same-day rows should not happen, because _recordTaxProfile
            // replaces them, but ordering by id keeps the answer stable rather
            // than arbitrary if one ever does: UUIDv7 sorts by time written.
            (t) => OrderingTerm.desc(t.id),
          ])
          ..limit(1))
        .getSingleOrNull();
    return row?.taxMode;
  }

  /// The whole history, oldest first. For the CA, and for explaining a bill.
  Future<List<({BusinessDate from, TaxMode mode})>> taxProfileHistory() async {
    final rows = await (_db.select(_db.taxProfileHistory)
          ..orderBy([(t) => OrderingTerm.asc(t.effectiveFrom)]))
        .get();
    return [
      for (final r in rows) (from: r.effectiveFrom, mode: r.taxMode),
    ];
  }

  Future<String> _deviceId() async {
    final device = await _db.select(_db.devices).getSingleOrNull();
    if (device == null) throw OutletError('This device is not set up.');
    return device.id;
  }
}
