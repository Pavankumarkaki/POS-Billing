/// The schema, as the brief specifies it. Fields were added only where noted.
///
/// Two conventions throughout:
///   - every money column is `INTEGER` paise, through [PaiseConverter]
///   - ids on anything that will later sync are UUIDv7 text, so a sync phase
///     needs no data rewrite
library;

import 'package:drift/drift.dart';

import 'converters.dart';

/// The restaurant. Exactly one row in Phase 1.
@DataClassName('OutletRow')
class Outlets extends Table {
  @override
  String get tableName => 'outlet';

  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 120)();
  TextColumn get address => text()();
  TextColumn get phone => text()();

  /// Only set on a regular registration.
  TextColumn get gstin => text().nullable()();

  /// 14 digits. Billing is blocked until a valid one is saved, which is
  /// enforced in the setup flow and re-checked before every print.
  TextColumn get fssaiNo => text().withLength(min: 14, max: 14)();

  TextColumn get taxMode => text().map(const TaxModeConverter())();

  /// Whether menu prices already include tax.
  BoolColumn get pricesIncludeTax =>
      boolean().withDefault(const Constant(false))();

  TextColumn get billFooter => text().withDefault(const Constant(''))();
  TextColumn get upiVpa => text().nullable()();

  /// When the business day rolls over, stored as minutes past midnight.
  /// 240 is 04:00, the default from the brief.
  ///
  /// Minutes rather than a time string so the arithmetic in
  /// `BusinessDate.of` stays integer-only.
  IntColumn get businessDayCutoffMinutes =>
      integer().withDefault(const Constant(240))();

  /// Added, not in the brief: the SAC printed on tax invoices. The brief asks
  /// for it to be configurable, and a settings row is the cheapest way.
  TextColumn get sacCode => text().withDefault(const Constant('9963'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Every tax mode the outlet has ever been on, with the date it took effect.
///
/// Needed because a bill from two years ago must still be explicable: the mode
/// in `outlet` is only today's.
@DataClassName('TaxProfileRow')
class TaxProfileHistory extends Table {
  @override
  String get tableName => 'tax_profile_history';

  TextColumn get id => text()();
  TextColumn get outletId => text().references(Outlets, #id)();
  TextColumn get taxMode => text().map(const TaxModeConverter())();
  TextColumn get effectiveFrom =>
      text().map(const BusinessDateConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// This installation. One row; a second device would get its own letter.
@DataClassName('DeviceRow')
class Devices extends Table {
  @override
  String get tableName => 'device';

  TextColumn get id => text()();
  TextColumn get outletId => text().references(Outlets, #id)();

  /// The device letter, `A` to `Z`. First part of every invoice number.
  TextColumn get seriesPrefix => text().withLength(min: 1, max: 1)();

  /// The sequence the next bill will take. Claimed and incremented inside the
  /// sale transaction, never outside it.
  IntColumn get nextSeq => integer().withDefault(const Constant(1))();

  /// Added, not in the brief: the financial year `nextSeq` belongs to. Without
  /// it a rollover cannot be detected, since the sequence restarts each April
  /// and there is no scheduled job to reset it.
  TextColumn get seqFy => text().map(const FinancialYearConverter())();

  /// Printer configuration as JSON: connection kind, address, bitmap width,
  /// whether to auto-cut, GS v 0 or ESC *.
  TextColumn get printerCfg => text().withDefault(const Constant('{}'))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('UserRow')
class Users extends Table {
  @override
  String get tableName => 'user';

  TextColumn get id => text()();
  TextColumn get name => text().withLength(min: 1, max: 80)();
  TextColumn get role => text().map(const UserRoleConverter())();

  /// PBKDF2-HMAC-SHA256, stored as `pbkdf2_sha256$<iterations>$<salt>$<hash>`,
  /// all base64. Never the PIN, never a bare digest.
  TextColumn get pinHash => text()();

  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  /// Added, not in the brief: lockout state after repeated PIN failures. The
  /// brief asks for a lockout; it has to survive an app restart, so it lives
  /// in the database rather than in memory.
  IntColumn get failedAttempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lockedUntil => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Categories and subcategories in one table: a null [parentId] is a category,
/// a set one is a subcategory, exactly as the brief specifies.
@DataClassName('CategoryRow')
class Categories extends Table {
  @override
  String get tableName => 'category';

  TextColumn get id => text()();
  TextColumn get parentId =>
      text().nullable().references(Categories, #id)();
  TextColumn get nameEn => text().withLength(min: 1, max: 80)();
  TextColumn get nameTe => text().withDefault(const Constant(''))();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('ItemRow')
class Items extends Table {
  @override
  String get tableName => 'item';

  TextColumn get id => text()();
  TextColumn get categoryId => text().references(Categories, #id)();
  TextColumn get nameEn => text().withLength(min: 1, max: 120)();
  TextColumn get nameTe => text().withDefault(const Constant(''))();

  IntColumn get pricePaise => integer().map(const PaiseConverter())();
  TextColumn get taxClass => text().map(const TaxClassConverter())();

  /// Items are disabled, never deleted, so old bills keep their references.
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get sort => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A bill. Immutable once written, except for the cancellation fields.
///
/// There is no update path for amounts or lines anywhere in the codebase, and
/// no delete path at all. See `BillRepository` and the schema test.
@DataClassName('BillRow')
class Bills extends Table {
  @override
  String get tableName => 'bill';

  /// UUIDv7: time-ordered, so it sorts by creation without a separate index,
  /// and collision-free across devices when sync arrives.
  TextColumn get id => text()();

  TextColumn get deviceId => text().references(Devices, #id)();

  /// This device's sequence within the financial year.
  IntColumn get deviceSeq => integer()();

  /// The rendered number, `A/2627/000123`. Stored as well as derived, because
  /// it is what is printed and what a customer will quote back.
  TextColumn get invoiceNo => text().withLength(min: 1, max: 16)();

  TextColumn get fy => text().map(const FinancialYearConverter())();

  /// The business day this counts toward, after the cutoff is applied. All
  /// reports group by this, not by [createdAt].
  TextColumn get businessDate =>
      text().map(const BusinessDateConverter())();

  TextColumn get docType => text().map(const DocTypeConverter())();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get status => text().map(const BillStatusConverter())();
  TextColumn get orderType => text().map(const OrderTypeConverter())();

  IntColumn get subtotal => integer().map(const PaiseConverter())();
  IntColumn get discount => integer().map(const PaiseConverter())();
  IntColumn get taxable => integer().map(const PaiseConverter())();
  IntColumn get cgst => integer().map(const PaiseConverter())();
  IntColumn get sgst => integer().map(const PaiseConverter())();
  IntColumn get roundOff => integer().map(const PaiseConverter())();
  IntColumn get total => integer().map(const PaiseConverter())();

  TextColumn get cancelReason => text().nullable()();
  @ReferenceName('cancelledBills')
  TextColumn get cancelledBy => text().nullable().references(Users, #id)();

  /// For a later credit note phase. Always null in Phase 1.
  TextColumn get refBillId => text().nullable()();

  /// Added, not in the brief: who rang it up, and the 5% turnover figure in
  /// composition mode.
  ///
  /// `createdBy` is needed because the audit log records the action while the
  /// bill list has to show "by Owner" without a join on every row.
  /// `compositionTurnover` is stored rather than recomputed so a turnover
  /// report cannot drift if the tax mode changes later.
  @ReferenceName('createdBills')
  TextColumn get createdBy => text().references(Users, #id)();
  IntColumn get compositionTurnover =>
      integer().map(const PaiseConverter()).withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
        // The backstop against a numbering collision if two writers ever race.
        //
        // The financial year is PART OF THIS KEY, and it has to be. The brief
        // specifies UNIQUE(device_id, device_seq), but it also requires the
        // sequence to restart at 1 each April. Those two cannot both hold:
        // the first bill of 2027-28 is device_seq 1, and so was the first
        // bill of 2026-27, on the same device.
        //
        // Without the fy column the app would refuse to write its first bill
        // of the new financial year, on 1 April, with a constraint error at
        // the counter. Found by a test that sold across a year boundary.
        'UNIQUE (device_id, fy, device_seq)',
        // And against the same rendered number appearing twice in a year.
        'UNIQUE (fy, invoice_no)',
      ];
}

/// A line on a bill, with everything about the item frozen at the moment of
/// sale. Nothing here is a reference that a later menu edit could change.
@DataClassName('BillLineRow')
class BillLines extends Table {
  @override
  String get tableName => 'bill_line';

  TextColumn get id => text()();
  TextColumn get billId => text().references(Bills, #id)();

  /// Kept so reports can group by item, but never read for display: the
  /// snapshot below is what the customer was shown.
  TextColumn get itemId => text()();

  TextColumn get nameSnapshot => text()();

  /// Added, not in the brief: the Telugu name at the time of sale, so a Telugu
  /// reprint of an old bill matches the original.
  TextColumn get nameTeSnapshot => text().nullable()();

  IntColumn get qty => integer()();
  IntColumn get unitPrice => integer().map(const PaiseConverter())();

  /// The rate actually applied, in basis points. 500 is 5%.
  IntColumn get taxRate => integer()();

  IntColumn get lineDiscount => integer().map(const PaiseConverter())();
  IntColumn get lineTotal => integer().map(const PaiseConverter())();

  /// Added, not in the brief: the line's own split, so a tax summary never has
  /// to re-derive it and risk a different rounding than the printed bill.
  IntColumn get taxable => integer().map(const PaiseConverter())();
  IntColumn get cgst => integer().map(const PaiseConverter())();
  IntColumn get sgst => integer().map(const PaiseConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One row per payment. Several on a split payment.
@DataClassName('PaymentRow')
class Payments extends Table {
  @override
  String get tableName => 'payment';

  TextColumn get id => text()();
  TextColumn get billId => text().references(Bills, #id)();
  TextColumn get mode => text().map(const PaymentModeConverter())();
  IntColumn get amount => integer().map(const PaiseConverter())();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Append-only. Nothing in the codebase updates or deletes a row here.
@DataClassName('AuditRow')
class AuditLog extends Table {
  @override
  String get tableName => 'audit_log';

  TextColumn get id => text()();
  DateTimeColumn get at => dateTime()();
  TextColumn get userId => text().nullable().references(Users, #id)();
  TextColumn get deviceId => text().references(Devices, #id)();
  TextColumn get action => text().map(const AuditActionConverter())();
  TextColumn get entity => text().map(const AuditEntityConverter())();
  TextColumn get entityId => text()();

  /// JSON, or null where there was no prior state (a create).
  TextColumn get before => text().nullable()();

  /// JSON, or null where there is no after state.
  TextColumn get after => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Filled in Phase 1, read by nobody. Exists so a later sync phase does not
/// need a data rewrite: every change that would have to be sent is already
/// recorded here in order.
@DataClassName('OutboxRow')
class Outbox extends Table {
  @override
  String get tableName => 'outbox';

  /// UUIDv7, and the idempotency key a server would deduplicate on.
  TextColumn get opId => text()();
  TextColumn get entity => text().map(const AuditEntityConverter())();
  TextColumn get payload => text()();
  DateTimeColumn get createdAt => dateTime()();

  /// Null until something sends it. Nothing does in Phase 1.
  DateTimeColumn get sentAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {opId};
}

/// Added, not in the brief: a key-value table for the handful of settings that
/// do not deserve a column, and for the backup bookkeeping.
///
/// The brief requires showing the last successful backup time and warning when
/// it is old, which means that time has to be recorded somewhere durable.
@DataClassName('SettingRow')
class Settings extends Table {
  @override
  String get tableName => 'setting';

  TextColumn get key => text()();
  TextColumn get value => text()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}
