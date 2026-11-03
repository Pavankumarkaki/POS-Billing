/// The database: table wiring, versioned migrations, and connection setup.
///
/// Flutter note for a Go developer: Drift generates `db.g.dart` from the table
/// classes, the way sqlc generates Go from SQL. The generated file holds the
/// row classes (`BillRow`), the companions used for inserts (`BillsCompanion`)
/// and the typed query builders. It is committed, so a fresh clone builds
/// without running the generator. Regenerate with:
///
///     dart run build_runner build --delete-conflicting-outputs
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// These look unused here, and are not: db.g.dart is a `part of` this library,
// so the generated row classes and companions resolve Paise, TaxMode,
// BusinessDate and the rest in this file's import scope, not in tables.dart's.
import '../core/business_date.dart';
import '../core/domain.dart';
import '../core/money.dart';
import '../core/tax.dart';
import 'converters.dart';
import 'tables.dart';

part 'db.g.dart';

/// Bumped for every schema change, with a migration step to match. Migration
/// tests walk every version from 1 to here, so this number and the `onUpgrade`
/// below cannot drift apart unnoticed.
const int kSchemaVersion = 1;

/// The file the database lives in, inside the app's own documents directory.
const String kDatabaseFileName = 'pos.sqlite';

@DriftDatabase(
  tables: [
    Outlets,
    TaxProfileHistory,
    Devices,
    Users,
    Categories,
    Items,
    Bills,
    BillLines,
    Payments,
    AuditLog,
    Outbox,
    Settings,
  ],
)
class PosDatabase extends _$PosDatabase {
  PosDatabase(super.e);

  /// Opens the real database file on the device.
  PosDatabase.open() : super(_openOnDevice());

  /// An in-memory database, for tests. Each call is an isolated instance.
  PosDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => kSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
        },
        onUpgrade: (m, from, to) async {
          // Phase 1 ships schema v1, so nothing can need upgrading yet and this
          // is unreachable. When v2 arrives its step goes here, keyed on `from`.
          // Throwing rather than quietly doing nothing means a schemaVersion
          // raised without a matching migration fails loudly instead of leaving
          // a database half a version behind its code.
          throw StateError(
            'No migration from schema v$from to v$to. '
            'Add one in PosDatabase.migration.',
          );
        },
        beforeOpen: (details) async {
          // Drift does not turn these on for you, and SQLite defaults them off
          // per connection. Without the first, the references declared in
          // tables.dart would be documentation rather than constraints.
          await customStatement('PRAGMA foreign_keys = ON');

          // Write-ahead logging: a reader never blocks the writer, so printing
          // or a report cannot stall the next sale.
          await customStatement('PRAGMA journal_mode = WAL');

          // Wait rather than fail if the nightly backup is mid-read.
          await customStatement('PRAGMA busy_timeout = 5000');

          if (details.wasCreated) {
            await customStatement('PRAGMA user_version = $kSchemaVersion');
          }
        },
      );

  /// Indexes for the queries the app actually runs: the bills list for a day,
  /// reports over a date range, the item grid, and the audit trail for a bill.
  Future<void> _createIndexes() async {
    const statements = [
      // Reports and the bills list, both of which filter by business day.
      'CREATE INDEX IF NOT EXISTS idx_bill_business_date '
          'ON bill (business_date, status)',
      // The financial-year sequence lookup.
      'CREATE INDEX IF NOT EXISTS idx_bill_device_fy '
          'ON bill (device_id, fy, device_seq)',
      // Looking a bill up by the number a customer quotes.
      'CREATE INDEX IF NOT EXISTS idx_bill_invoice_no ON bill (invoice_no)',
      // Pulling a bill's lines, and the item-wise report.
      'CREATE INDEX IF NOT EXISTS idx_bill_line_bill ON bill_line (bill_id)',
      'CREATE INDEX IF NOT EXISTS idx_bill_line_item ON bill_line (item_id)',
      // Payment-mode breakdown.
      'CREATE INDEX IF NOT EXISTS idx_payment_bill ON payment (bill_id)',
      // The item grid: active items in a category, in sort order.
      'CREATE INDEX IF NOT EXISTS idx_item_category '
          'ON item (category_id, is_active, sort)',
      // The audit trail for one bill, and the log in time order.
      'CREATE INDEX IF NOT EXISTS idx_audit_entity '
          'ON audit_log (entity, entity_id)',
      'CREATE INDEX IF NOT EXISTS idx_audit_at ON audit_log (at)',
      // Whatever a sync phase has not sent yet.
      'CREATE INDEX IF NOT EXISTS idx_outbox_unsent '
          'ON outbox (sent_at, created_at)',
    ];
    for (final sql in statements) {
      await customStatement(sql);
    }
  }
}

QueryExecutor _openOnDevice() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, kDatabaseFileName));
    return NativeDatabase.createInBackground(file);
  });
}
