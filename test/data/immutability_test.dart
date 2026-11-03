/// A paid bill is immutable, and no bill is ever deleted.
///
/// Cancelling keeps the invoice number and records status, reason and user.
/// A later menu edit must not change a past bill or a past report.
library;

import 'dart:convert';
import 'dart:io';

// drift exports isNull/isNotNull as SQL expression helpers, which collide
// with flutter_test's matchers of the same name.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late BillRepository repo;

  setUp(() async {
    f = await Fixture.create();
    repo = BillRepository(f.db);
  });

  tearDown(() => f.close());

  Future<SavedBill> sell({
    List<CartLine>? lines,
    String userId = kOwnerId,
  }) async {
    final computed = await f.compute(lines: lines);
    return repo.commitSale(
      computed: computed,
      payments: [PaymentIntent(PaymentMode.cash, computed.total)],
      deviceId: kDeviceId,
      userId: userId,
      at: DateTime(2026, 6, 1, 13, 30),
    );
  }

  group('cancelling keeps everything but the status', () {
    test('the number, the lines and every amount survive', () async {
      final saved = await sell(lines: f.cart(biryaniQty: 2));
      final before = await f.db.select(f.db.bills).getSingle();
      final linesBefore = await f.db.select(f.db.billLines).get();

      await repo.cancelBill(
        billId: saved.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final after = await f.db.select(f.db.bills).getSingle();
      final linesAfter = await f.db.select(f.db.billLines).get();

      expect(after.invoiceNo, before.invoiceNo,
          reason: 'the invoice number stays');
      expect(after.deviceSeq, before.deviceSeq);
      expect(after.subtotal.value, before.subtotal.value);
      expect(after.taxable.value, before.taxable.value);
      expect(after.cgst.value, before.cgst.value);
      expect(after.sgst.value, before.sgst.value);
      expect(after.roundOff.value, before.roundOff.value);
      expect(after.total.value, before.total.value);
      expect(after.createdAt, before.createdAt);
      expect(after.businessDate, before.businessDate);

      expect(after.status, BillStatus.cancelled);
      expect(after.cancelReason, 'Wrong item entered');
      expect(after.cancelledBy, kOwnerId);

      expect(linesAfter.length, linesBefore.length);
      for (var i = 0; i < linesAfter.length; i++) {
        expect(linesAfter[i].lineTotal.value, linesBefore[i].lineTotal.value);
        expect(linesAfter[i].nameSnapshot, linesBefore[i].nameSnapshot);
      }
    });

    test('the number is not reused by the next sale', () async {
      final first = await sell();
      await repo.cancelBill(
        billId: first.id,
        reason: 'Customer left',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );
      final second = await sell();

      expect(first.invoiceNo.formatted, 'A/2627/000001');
      expect(second.invoiceNo.formatted, 'A/2627/000002',
          reason: 'a cancelled number is spent, not freed');
      expect(await f.billCount(), 2, reason: 'nothing was deleted');
    });

    test('a reason is required', () async {
      final saved = await sell();
      for (final bad in ['', '   ', '\n']) {
        await expectLater(
          repo.cancelBill(
            billId: saved.id,
            reason: bad,
            userId: kOwnerId,
            deviceId: kDeviceId,
          ),
          throwsA(isA<SaleError>()),
        );
      }
      final row = await f.db.select(f.db.bills).getSingle();
      expect(row.status, BillStatus.paid, reason: 'still not cancelled');
    });

    test('staff may not cancel', () async {
      final saved = await sell();
      await expectLater(
        repo.cancelBill(
          billId: saved.id,
          reason: 'Wrong item entered',
          userId: kStaffId,
          deviceId: kDeviceId,
        ),
        throwsA(isA<PermissionDenied>()),
      );

      final row = await f.db.select(f.db.bills).getSingle();
      expect(row.status, BillStatus.paid);
      expect(row.cancelReason, isNull);
    });

    test('cancelling twice is refused', () async {
      final saved = await sell();
      await repo.cancelBill(
        billId: saved.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );
      await expectLater(
        repo.cancelBill(
          billId: saved.id,
          reason: 'again',
          userId: kOwnerId,
          deviceId: kDeviceId,
        ),
        throwsA(isA<SaleError>()),
      );

      final row = await f.db.select(f.db.bills).getSingle();
      expect(row.cancelReason, 'Wrong item entered',
          reason: 'the first reason is not overwritten');
    });

    test('cancelling an unknown bill is refused', () async {
      await expectLater(
        repo.cancelBill(
          billId: 'no-such-bill',
          reason: 'x',
          userId: kOwnerId,
          deviceId: kDeviceId,
        ),
        throwsA(isA<SaleError>()),
      );
    });

    test('the audit entry carries both before and after', () async {
      final saved = await sell();
      await repo.cancelBill(
        billId: saved.id,
        reason: 'Wrong payment mode',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final entries = await (f.db.select(f.db.auditLog)
            ..where((a) => a.action.equals(AuditAction.billCancelled.wireName)))
          .get();
      expect(entries, hasLength(1));
      final e = entries.single;

      expect(e.before, isNotNull);
      expect(e.after, isNotNull);

      final before = jsonDecode(e.before!) as Map<String, Object?>;
      final after = jsonDecode(e.after!) as Map<String, Object?>;

      expect(before['status'], 'paid');
      expect(after['status'], 'cancelled');
      expect(after['cancel_reason'], 'Wrong payment mode');
      expect(after['cancelled_by'], kOwnerId);
      expect(after['total'], before['total'],
          reason: 'the amount did not change');
      expect(after['invoice_no'], before['invoice_no']);
    });
  });

  group('a reprint changes nothing', () {
    test('it only writes an audit entry', () async {
      final saved = await sell();
      final before = await f.db.select(f.db.bills).getSingle();
      final auditBefore = await f.auditCount();

      await repo.recordReprint(
        billId: saved.id,
        userId: kOwnerId,
        deviceId: kDeviceId,
      );

      final after = await f.db.select(f.db.bills).getSingle();
      expect(after.total.value, before.total.value);
      expect(after.invoiceNo, before.invoiceNo);
      expect(after.status, before.status);
      expect(await f.auditCount(), auditBefore + 1);
    });

    test('it is logged as a duplicate', () async {
      final saved = await sell();
      await repo.recordReprint(
        billId: saved.id,
        userId: kStaffId,
        deviceId: kDeviceId,
      );

      final e = await (f.db.select(f.db.auditLog)
            ..where((a) => a.action.equals(AuditAction.billReprinted.wireName)))
          .getSingle();
      final after = jsonDecode(e.after!) as Map<String, Object?>;
      expect(after['marked'], 'DUPLICATE');
      expect(after['invoice_no'], 'A/2627/000001');
      expect(e.userId, kStaffId);
    });

    test('staff may reprint', () async {
      final saved = await sell();
      await repo.recordReprint(
        billId: saved.id,
        userId: kStaffId,
        deviceId: kDeviceId,
      );
      expect(await f.auditCount(), 2);
    });

    test('every reprint is logged separately', () async {
      final saved = await sell();
      for (var i = 0; i < 3; i++) {
        await repo.recordReprint(
          billId: saved.id,
          userId: kOwnerId,
          deviceId: kDeviceId,
        );
      }
      final entries = await (f.db.select(f.db.auditLog)
            ..where((a) => a.action.equals(AuditAction.billReprinted.wireName)))
          .get();
      expect(entries, hasLength(3));
    });
  });

  group('snapshots survive menu edits', () {
    test('renaming an item does not change a past bill', () async {
      final saved = await sell();

      await (f.db.update(f.db.items)..where((i) => i.id.equals(kItemBiryani)))
          .write(ItemsCompanion(
        nameEn: const Value('Special Chicken Dum Biryani'),
        nameTe: const Value('స్పెషల్ చికెన్ దమ్ బిర్యానీ'),
        updatedAt: Value(DateTime(2026, 7, 1)),
      ));

      final line = await f.db.select(f.db.billLines).getSingle();
      expect(line.nameSnapshot, 'Chicken Dum Biryani');
      expect(line.nameTeSnapshot, 'చికెన్ దమ్ బిర్యానీ');

      final reloaded = await repo.loadBill(saved.id);
      expect(reloaded!.lines.single.nameSnapshot, 'Chicken Dum Biryani');
    });

    test('a price change does not change a past bill', () async {
      final saved = await sell();

      await (f.db.update(f.db.items)..where((i) => i.id.equals(kItemBiryani)))
          .write(ItemsCompanion(
        pricePaise: Value(Paise.fromRupees(300)),
        updatedAt: Value(DateTime(2026, 7, 1)),
      ));

      final line = await f.db.select(f.db.billLines).getSingle();
      expect(line.unitPrice.value, 24000, reason: 'sold at 240');
      expect(line.lineTotal.value, 25200);

      final bill = await f.db.select(f.db.bills).getSingle();
      expect(bill.total.value, 25200);
      expect(bill.id, saved.id);
    });

    test('a tax class change does not change a past bill', () async {
      await sell();

      await (f.db.update(f.db.items)..where((i) => i.id.equals(kItemBiryani)))
          .write(ItemsCompanion(
        taxClass: const Value(TaxClass.gst18),
        updatedAt: Value(DateTime(2026, 7, 1)),
      ));

      final line = await f.db.select(f.db.billLines).getSingle();
      expect(line.taxRate, 500, reason: 'taxed at 5% when sold');
      expect(line.cgst.value, 600);

      final bill = await f.db.select(f.db.bills).getSingle();
      expect(bill.cgst.value, 600);
      expect(bill.total.value, 25200);
    });

    test('disabling an item does not hide it from a past bill', () async {
      final saved = await sell();

      await (f.db.update(f.db.items)..where((i) => i.id.equals(kItemBiryani)))
          .write(ItemsCompanion(
        isActive: const Value(false),
        updatedAt: Value(DateTime(2026, 7, 1)),
      ));

      final reloaded = await repo.loadBill(saved.id);
      expect(reloaded!.lines, hasLength(1));
      expect(reloaded.lines.single.nameSnapshot, 'Chicken Dum Biryani');
    });

    test('changing the outlet tax mode does not change a past bill', () async {
      await sell();

      await (f.db.update(f.db.outlets)..where((o) => o.id.equals(kOutletId)))
          .write(const OutletsCompanion(
        taxMode: Value(TaxMode.composition),
      ));

      final bill = await f.db.select(f.db.bills).getSingle();
      expect(bill.docType, DocType.invoice, reason: 'it was an invoice then');
      expect(bill.cgst.value, 600);
      expect(bill.total.value, 25200);
    });

    test('every edit at once, and the bill is untouched', () async {
      final saved = await sell(lines: f.cart(biryaniQty: 2, withColdDrink: true));
      final billBefore = await f.db.select(f.db.bills).getSingle();
      final linesBefore = await f.db.select(f.db.billLines).get()
        ..sort((a, b) => a.itemId.compareTo(b.itemId));

      await f.db.customStatement(
        'UPDATE item SET name_en = name_en || \' CHANGED\', '
        'price_paise = price_paise * 2, tax_class = \'gst18\', '
        'is_active = 0',
      );
      await f.db.customStatement(
        "UPDATE category SET name_en = 'Renamed'",
      );

      final billAfter = await f.db.select(f.db.bills).getSingle();
      final linesAfter = await f.db.select(f.db.billLines).get()
        ..sort((a, b) => a.itemId.compareTo(b.itemId));

      expect(billAfter.total.value, billBefore.total.value);
      expect(billAfter.taxable.value, billBefore.taxable.value);
      expect(billAfter.cgst.value, billBefore.cgst.value);
      expect(billAfter.invoiceNo, billBefore.invoiceNo);

      for (var i = 0; i < linesAfter.length; i++) {
        expect(linesAfter[i].nameSnapshot, linesBefore[i].nameSnapshot);
        expect(linesAfter[i].unitPrice.value, linesBefore[i].unitPrice.value);
        expect(linesAfter[i].taxRate, linesBefore[i].taxRate);
        expect(linesAfter[i].lineTotal.value, linesBefore[i].lineTotal.value);
      }

      final reloaded = await repo.loadBill(saved.id);
      expect(reloaded!.lines, hasLength(2));
    });
  });

  group('the repository offers no way to mutate or delete a bill', () {
    test('BillRepository has no update or delete method for amounts', () {
      // A structural check: if someone adds `updateBill` or `deleteBill` the
      // brief's first rule is broken, and this test says so by name.
      final source = File('lib/data/bill_repository.dart').readAsStringSync();

      for (final forbidden in [
        'Future<void> updateBill',
        'Future<void> deleteBill',
        'delete(_db.bills)',
        'delete(_db.billLines)',
        'delete(_db.payments)',
        'delete(_db.auditLog)',
      ]) {
        expect(
          source.contains(forbidden),
          isFalse,
          reason: 'found "$forbidden": a paid bill must never be '
              'changed or deleted',
        );
      }
    });

    test('the only columns cancelBill writes are the cancellation ones', () {
      final source = File('lib/data/bill_repository.dart').readAsStringSync();
      final start = source.indexOf('Future<void> cancelBill');
      expect(start, greaterThan(-1));
      final end = source.indexOf('Future<void> recordReprint');
      final body = source.substring(start, end);

      // The write in cancelBill must touch status, cancel_reason and
      // cancelled_by, and nothing else.
      for (final allowed in ['status:', 'cancelReason:', 'cancelledBy:']) {
        expect(body.contains(allowed), isTrue, reason: 'expected $allowed');
      }
      for (final forbidden in [
        'total:',
        'taxable:',
        'cgst:',
        'sgst:',
        'subtotal:',
        'roundOff:',
        'invoiceNo:',
        'deviceSeq:',
      ]) {
        expect(
          body.contains(forbidden),
          isFalse,
          reason: 'cancelBill must not write $forbidden',
        );
      }
    });

    test('no bill row can be removed through the repository API', () async {
      final saved = await sell();
      await repo.cancelBill(
        billId: saved.id,
        reason: 'Test bill',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );
      expect(await f.billCount(), 1, reason: 'cancelling is not deleting');
      expect(await f.lineCount(), 1);
      expect(await f.paymentCount(), 1);
    });
  });

  group('the audit log is append-only', () {
    test('entries accumulate and none is replaced', () async {
      final saved = await sell();
      expect(await f.auditCount(), 1);

      await repo.recordReprint(
        billId: saved.id,
        userId: kOwnerId,
        deviceId: kDeviceId,
      );
      expect(await f.auditCount(), 2);

      await repo.cancelBill(
        billId: saved.id,
        reason: 'Wrong item entered',
        userId: kOwnerId,
        deviceId: kDeviceId,
      );
      expect(await f.auditCount(), 3);

      final actions = (await f.db.select(f.db.auditLog).get())
          .map((e) => e.action)
          .toSet();
      expect(actions, {
        AuditAction.billCreated,
        AuditAction.billReprinted,
        AuditAction.billCancelled,
      });
    });

    test('ids are unique', () async {
      final saved = await sell();
      for (var i = 0; i < 3; i++) {
        await repo.recordReprint(
          billId: saved.id,
          userId: kOwnerId,
          deviceId: kDeviceId,
        );
      }
      final ids = (await f.db.select(f.db.auditLog).get())
          .map((e) => e.id)
          .toList();
      expect(ids, hasLength(4));
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('ordering by `at` is insertion order', () async {
      // This, not id order, is what the app relies on and what idx_audit_at
      // indexes. UUIDv7 is only time-ordered to the millisecond, so several
      // entries written inside one millisecond have no guaranteed id order:
      // the random bits decide. Asserting id order here was flaky for exactly
      // that reason.
      final saved = await sell();
      for (var i = 0; i < 3; i++) {
        await repo.recordReprint(
          billId: saved.id,
          userId: kOwnerId,
          deviceId: kDeviceId,
          at: DateTime(2026, 6, 1, 14, i * 5),
        );
      }

      final rows = await (f.db.select(f.db.auditLog)
            ..orderBy([(a) => OrderingTerm.asc(a.at)]))
          .get();
      expect(rows, hasLength(4));
      expect(rows.first.action, AuditAction.billCreated);
      for (var i = 1; i < rows.length; i++) {
        expect(
          rows[i].at.isAfter(rows[i - 1].at),
          isTrue,
          reason: 'row $i must be later than row ${i - 1}',
        );
      }
    });
  });
}
