/// Drift type converters: how core's types sit in SQLite columns.
///
/// Three things are converted, each for a reason:
///   - money, as `INTEGER` paise, never a REAL
///   - enums, as the exact `TEXT` spellings pinned in `core/domain.dart`
///   - business dates, as `TEXT` in `YYYY-MM-DD`, which sorts correctly and
///     reads correctly in a SQLite browser
library;

import 'package:drift/drift.dart';

import '../core/business_date.dart';
import '../core/domain.dart';
import '../core/money.dart';
import '../core/tax.dart';

/// Money. `Paise` is an `extension type` over `int`, so this is a no-op at
/// runtime; it exists so the column type is `Paise` and not a bare `int` that
/// could be confused with a quantity.
class PaiseConverter extends TypeConverter<Paise, int> {
  const PaiseConverter();

  @override
  Paise fromSql(int fromDb) => Paise(fromDb);

  @override
  int toSql(Paise value) => value.value;
}

/// A business date as `2026-03-02`.
class BusinessDateConverter extends TypeConverter<BusinessDate, String> {
  const BusinessDateConverter();

  @override
  BusinessDate fromSql(String fromDb) {
    final parsed = BusinessDate.tryParse(fromDb);
    if (parsed == null) {
      throw UnknownWireValue('business_date', fromDb);
    }
    return parsed;
  }

  @override
  String toSql(BusinessDate value) => value.iso;
}

/// A financial year as its four-digit code, `2627`.
class FinancialYearConverter extends TypeConverter<FinancialYear, String> {
  const FinancialYearConverter();

  @override
  FinancialYear fromSql(String fromDb) {
    if (fromDb.length != 4 || int.tryParse(fromDb) == null) {
      throw UnknownWireValue('fy', fromDb);
    }
    final short = int.parse(fromDb.substring(0, 2));
    // Same century rule as InvoiceNo.tryParse: always the 2000s.
    return FinancialYear(2000 + short);
  }

  @override
  String toSql(FinancialYear value) => value.code;
}

class TaxModeConverter extends TypeConverter<TaxMode, String> {
  const TaxModeConverter();
  @override
  TaxMode fromSql(String fromDb) => TaxModeWire.parse(fromDb);
  @override
  String toSql(TaxMode value) => value.wireName;
}

class TaxClassConverter extends TypeConverter<TaxClass, String> {
  const TaxClassConverter();
  @override
  TaxClass fromSql(String fromDb) => TaxClassWire.parse(fromDb);
  @override
  String toSql(TaxClass value) => value.wireName;
}

class OrderTypeConverter extends TypeConverter<OrderType, String> {
  const OrderTypeConverter();
  @override
  OrderType fromSql(String fromDb) => OrderTypeWire.parse(fromDb);
  @override
  String toSql(OrderType value) => value.wireName;
}

class DocTypeConverter extends TypeConverter<DocType, String> {
  const DocTypeConverter();
  @override
  DocType fromSql(String fromDb) => DocTypeWire.parse(fromDb);
  @override
  String toSql(DocType value) => value.wireName;
}

class BillStatusConverter extends TypeConverter<BillStatus, String> {
  const BillStatusConverter();
  @override
  BillStatus fromSql(String fromDb) => BillStatus.parse(fromDb);
  @override
  String toSql(BillStatus value) => value.wireName;
}

class PaymentModeConverter extends TypeConverter<PaymentMode, String> {
  const PaymentModeConverter();
  @override
  PaymentMode fromSql(String fromDb) => PaymentMode.parse(fromDb);
  @override
  String toSql(PaymentMode value) => value.wireName;
}

class UserRoleConverter extends TypeConverter<UserRole, String> {
  const UserRoleConverter();
  @override
  UserRole fromSql(String fromDb) => UserRole.parse(fromDb);
  @override
  String toSql(UserRole value) => value.wireName;
}

class AuditActionConverter extends TypeConverter<AuditAction, String> {
  const AuditActionConverter();
  @override
  AuditAction fromSql(String fromDb) => AuditAction.parse(fromDb);
  @override
  String toSql(AuditAction value) => value.wireName;
}

class AuditEntityConverter extends TypeConverter<AuditEntity, String> {
  const AuditEntityConverter();
  @override
  AuditEntity fromSql(String fromDb) => AuditEntity.parse(fromDb);
  @override
  String toSql(AuditEntity value) => value.wireName;
}
