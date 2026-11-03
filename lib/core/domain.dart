/// The remaining domain enums, and the stable strings they are stored as.
/// Pure Dart, like the rest of `core`.
///
/// Every enum here carries an explicit [wireName]. Dart's own `.name` would be
/// `regular5`, but the brief's data model says `regular_5`, and the database is
/// something the owner's CA may well open in a SQLite browser. So the stored
/// spelling is pinned here rather than left to depend on how the Dart constant
/// happens to be written. Renaming a Dart constant then cannot silently
/// invalidate every row already on disk.
library;

import 'tax.dart';

/// Thrown when a stored string is not one this build knows.
class UnknownWireValue implements Exception {
  UnknownWireValue(this.type, this.value);
  final String type;
  final String value;
  @override
  String toString() => 'UnknownWireValue: "$value" is not a valid $type';
}

extension TaxModeWire on TaxMode {
  String get wireName => switch (this) {
        TaxMode.unregistered => 'unregistered',
        TaxMode.composition => 'composition',
        TaxMode.regular5 => 'regular_5',
        TaxMode.regular18 => 'regular_18',
      };

  static TaxMode parse(String value) => switch (value) {
        'unregistered' => TaxMode.unregistered,
        'composition' => TaxMode.composition,
        'regular_5' => TaxMode.regular5,
        'regular_18' => TaxMode.regular18,
        _ => throw UnknownWireValue('tax_mode', value),
      };
}

extension TaxClassWire on TaxClass {
  String get wireName => switch (this) {
        TaxClass.gst5 => 'gst5',
        TaxClass.gst18 => 'gst18',
        TaxClass.nonGst => 'non_gst',
      };

  static TaxClass parse(String value) => switch (value) {
        'gst5' => TaxClass.gst5,
        'gst18' => TaxClass.gst18,
        'non_gst' => TaxClass.nonGst,
        _ => throw UnknownWireValue('tax_class', value),
      };
}

extension OrderTypeWire on OrderType {
  String get wireName => switch (this) {
        OrderType.dine => 'dine',
        OrderType.takeaway => 'takeaway',
        OrderType.aggregator => 'aggregator',
      };

  static OrderType parse(String value) => switch (value) {
        'dine' => OrderType.dine,
        'takeaway' => OrderType.takeaway,
        'aggregator' => OrderType.aggregator,
        _ => throw UnknownWireValue('order_type', value),
      };
}

extension DocTypeWire on DocType {
  String get wireName => switch (this) {
        DocType.invoice => 'invoice',
        DocType.billOfSupply => 'bill_of_supply',
        DocType.creditNote => 'credit_note',
      };

  static DocType parse(String value) => switch (value) {
        'invoice' => DocType.invoice,
        'bill_of_supply' => DocType.billOfSupply,
        'credit_note' => DocType.creditNote,
        _ => throw UnknownWireValue('doc_type', value),
      };
}

/// A bill is paid or cancelled. There is no third state, and no deletion:
/// a paid bill is immutable and a cancelled one keeps its number.
enum BillStatus {
  paid('paid'),
  cancelled('cancelled');

  const BillStatus(this.wireName);
  final String wireName;

  static BillStatus parse(String value) => switch (value) {
        'paid' => BillStatus.paid,
        'cancelled' => BillStatus.cancelled,
        _ => throw UnknownWireValue('status', value),
      };
}

/// How the customer paid. A bill may carry several of these at once.
enum PaymentMode {
  cash('cash'),
  upi('upi'),
  card('card'),

  /// Settled by the aggregator, not at the counter.
  aggregator('aggregator'),

  /// Put on the slate. Recorded so the total reconciles; no ledger in Phase 1.
  credit('credit');

  const PaymentMode(this.wireName);
  final String wireName;

  static PaymentMode parse(String value) => switch (value) {
        'cash' => PaymentMode.cash,
        'upi' => PaymentMode.upi,
        'card' => PaymentMode.card,
        'aggregator' => PaymentMode.aggregator,
        'credit' => PaymentMode.credit,
        _ => throw UnknownWireValue('payment mode', value),
      };

  /// Cash is the only mode that involves change, so it is the only one that
  /// shows a "received" and "give back" pair on the payment screen.
  bool get takesChange => this == cash;
}

/// Who is using the app. Only two roles, as the brief says: the two brothers.
enum UserRole {
  owner('owner'),
  staff('staff');

  const UserRole(this.wireName);
  final String wireName;

  static UserRole parse(String value) => switch (value) {
        'owner' => UserRole.owner,
        'staff' => UserRole.staff,
        _ => throw UnknownWireValue('role', value),
      };
}

/// The things a user may try to do that are checked against their role.
///
/// Listed as an enum rather than scattered `if (role == owner)` checks, so the
/// permission test can enumerate every one of them and assert both answers.
enum Permission {
  /// Ring up and save a bill. Both roles.
  createBill,

  /// Print a duplicate of an existing bill. Both roles, but always logged.
  reprintBill,

  /// Cancel a bill. Owner only, and needs the PIN re-entered.
  cancelBill,

  /// Add, edit, enable or disable menu items and categories. Owner only.
  editMenu,

  /// Change outlet details, tax mode, printer or backup settings. Owner only.
  changeSettings,

  /// See any report. Owner only.
  viewReports,

  /// Export for the accountant, or run a backup or restore. Owner only.
  exportData,

  /// Add or deactivate a user, or reset a PIN. Owner only.
  manageUsers;

  /// Whether [role] may do this.
  ///
  /// The brief: "Only the owner can cancel bills, edit the menu, change
  /// settings, or view reports." Everything else is open to staff.
  bool allows(UserRole role) {
    if (role == UserRole.owner) return true;
    return switch (this) {
      createBill || reprintBill => true,
      cancelBill ||
      editMenu ||
      changeSettings ||
      viewReports ||
      exportData ||
      manageUsers =>
        false,
    };
  }
}

/// What an audit entry records. Append-only; the brief requires every create,
/// edit, cancel, reprint and setting change with before and after values.
enum AuditAction {
  billCreated('bill_created'),
  billCancelled('bill_cancelled'),
  billReprinted('bill_reprinted'),
  itemCreated('item_created'),
  itemEdited('item_edited'),
  itemDisabled('item_disabled'),
  itemEnabled('item_enabled'),
  categoryCreated('category_created'),
  categoryEdited('category_edited'),
  settingChanged('setting_changed'),
  taxModeChanged('tax_mode_changed'),
  userCreated('user_created'),
  userEdited('user_edited'),
  pinChanged('pin_changed'),
  loginFailed('login_failed'),
  lockedOut('locked_out'),
  backupRun('backup_run'),
  restoreRun('restore_run'),
  dataExported('data_exported');

  const AuditAction(this.wireName);
  final String wireName;

  static AuditAction parse(String value) {
    for (final a in AuditAction.values) {
      if (a.wireName == value) return a;
    }
    throw UnknownWireValue('audit action', value);
  }
}

/// The kind of row an audit or outbox entry points at.
enum AuditEntity {
  bill('bill'),
  item('item'),
  category('category'),
  outlet('outlet'),
  device('device'),
  user('user'),
  backup('backup');

  const AuditEntity(this.wireName);
  final String wireName;

  static AuditEntity parse(String value) {
    for (final e in AuditEntity.values) {
      if (e.wireName == value) return e;
    }
    throw UnknownWireValue('audit entity', value);
  }
}
