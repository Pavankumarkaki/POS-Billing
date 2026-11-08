/// Editing the bill details after setup.
///
/// Most of the weight here is on two things: that a tax mode change is dated
/// and readable back, and that nothing about it can reach a bill that was
/// already rung up. The second is the reason this is safe to allow at all.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/outlet_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';

void main() {
  late PosDatabase db;
  late OutletRepository repo;
  late String ownerId;
  late String staffId;
  late String deviceId;
  late String itemId;

  /// [at] dates the setup. It defaults to the start of the financial year
  /// rather than now, because a profile row dated today would be replaced by
  /// any change made today, and then there would be nothing to read back for
  /// a past date. On a real device setup is in the past by the time anyone
  /// edits these fields.
  Future<void> seed({
    TaxMode mode = TaxMode.regular5,
    DateTime? at,
  }) async {
    db = PosDatabase.memory();
    final setup = SetupRepository(db);
    final r = await setup.completeSetup(
      SetupDetails(
        outletName: 'Annapurna Mess',
        address: 'Main Road',
        phone: '9000000000',
        fssaiNo: '12345678901234',
        taxMode: mode,
        gstin: mode == TaxMode.unregistered ? null : '37ABCDE1234F1Z5',
        ownerName: 'Ravi',
        ownerPin: '1357',
        devicePrefix: 'A',
      ),
      at: at ?? DateTime(2026, 4, 1, 10),
    );
    ownerId = r.ownerId;
    deviceId = r.deviceId;
    staffId = await setup.addUser(
      name: 'Kiran',
      role: UserRole.staff,
      pin: '2468',
      byUserId: ownerId,
    );

    final menu = MenuRepository(db, deviceId: deviceId);
    final cat = await menu.createCategory(nameEn: 'Biryani', byUserId: ownerId);
    itemId = await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );

    repo = OutletRepository(db);
  }

  setUp(() => seed());
  tearDown(() => db.close());

  Future<SavedBill> sell({TaxMode? mode}) async {
    final outlet = await db.select(db.outlets).getSingle();
    final computed = computeBill(
      cart: [
        CartLine(
          itemId: itemId,
          nameSnapshot: 'Chicken Dum Biryani',
          unitPrice: Paise.fromRupees(240),
          qty: 1,
          taxClass: TaxClass.gst5,
        ),
      ],
      config: TaxConfig(
        mode: mode ?? outlet.taxMode,
        pricesIncludeTax: outlet.pricesIncludeTax,
      ),
      orderType: OrderType.dine,
    );
    return BillRepository(db).commitSale(
      computed: computed,
      payments: [PaymentIntent(PaymentMode.cash, computed.total)],
      deviceId: deviceId,
      userId: ownerId,
    );
  }

  Future<OutletRow> outlet() => db.select(db.outlets).getSingle();

  group('what can be saved', () {
    test('a corrected FSSAI number', () async {
      final changed = await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '99999999999999',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      expect(changed, isTrue);
      expect((await outlet()).fssaiNo, '99999999999999');
    });

    test('a GSTIN is upper-cased and trimmed', () async {
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.regular5,
          gstin: '  37abcde1234f1z5  ',
        ),
        byUserId: ownerId,
      );
      expect((await outlet()).gstin, '37ABCDE1234F1Z5');
    });

    test('saving the same values again reports that nothing changed',
        () async {
      // So the screen can say "Saved" honestly rather than for a tap that did
      // nothing, and so an unchanged save leaves no audit noise.
      final changed = await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );
      expect(changed, isFalse);
      expect(await db.select(db.taxProfileHistory).get(), hasLength(1));
    });
  });

  group('what is refused', () {
    test('an FSSAI number that is not 14 digits', () async {
      await expectLater(
        repo.updateBillDetails(
          const BillDetails(
            fssaiNo: '123',
            taxMode: TaxMode.regular5,
            gstin: '37ABCDE1234F1Z5',
          ),
          byUserId: ownerId,
        ),
        throwsA(isA<OutletError>()),
      );
      expect((await outlet()).fssaiNo, '12345678901234',
          reason: 'the stored one must survive a refused edit');
    });

    test('an empty FSSAI number, so billing can never be unblocked by '
        'clearing it', () async {
      // The brief blocks billing until a valid number is saved. An edit screen
      // that lets the owner blank it would be a way around that rule.
      await expectLater(
        repo.updateBillDetails(
          const BillDetails(fssaiNo: '', taxMode: TaxMode.unregistered),
          byUserId: ownerId,
        ),
        throwsA(isA<OutletError>()),
      );
    });

    test('regular GST with no GSTIN', () async {
      await expectLater(
        repo.updateBillDetails(
          const BillDetails(fssaiNo: '12345678901234', taxMode: TaxMode.regular5),
          byUserId: ownerId,
        ),
        throwsA(isA<OutletError>()),
      );
    });

    test('a GSTIN of the wrong shape', () async {
      await expectLater(
        repo.updateBillDetails(
          const BillDetails(
            fssaiNo: '12345678901234',
            taxMode: TaxMode.regular5,
            gstin: 'NOPE',
          ),
          byUserId: ownerId,
        ),
        throwsA(isA<OutletError>()),
      );
    });

    test('staff', () async {
      await expectLater(
        repo.updateBillDetails(
          const BillDetails(
            fssaiNo: '99999999999999',
            taxMode: TaxMode.regular5,
            gstin: '37ABCDE1234F1Z5',
          ),
          byUserId: staffId,
        ),
        throwsA(isA<OutletError>()),
      );
      expect((await outlet()).fssaiNo, '12345678901234');
    });

    test('an unknown user', () async {
      await expectLater(
        repo.updateBillDetails(
          const BillDetails(
            fssaiNo: '99999999999999',
            taxMode: TaxMode.regular5,
            gstin: '37ABCDE1234F1Z5',
          ),
          byUserId: 'nobody',
        ),
        throwsA(isA<OutletError>()),
      );
    });

    test('a refusal leaves no audit entry and no profile row', () async {
      final auditBefore = (await db.select(db.auditLog).get()).length;

      await expectLater(
        repo.updateBillDetails(
          const BillDetails(fssaiNo: '123', taxMode: TaxMode.unregistered),
          byUserId: ownerId,
        ),
        throwsA(isA<OutletError>()),
      );

      expect((await db.select(db.auditLog).get()).length, auditBefore);
      expect(await db.select(db.taxProfileHistory).get(), hasLength(1));
    });
  });

  group('the GSTIN follows the registration', () {
    test('going unregistered clears it, so no bill prints a GSTIN the '
        'outlet does not have', () async {
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.unregistered,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );
      expect((await outlet()).gstin, isNull);
    });

    test('composition keeps it, because a composition dealer is registered',
        () async {
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.composition,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );
      expect((await outlet()).gstin, '37ABCDE1234F1Z5');
    });

    test('composition does not require one', () async {
      await seed(mode: TaxMode.unregistered);
      final changed = await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.composition,
        ),
        byUserId: ownerId,
      );
      expect(changed, isTrue);
      expect((await outlet()).gstin, isNull);
    });
  });

  group('a tax mode change is dated', () {
    test('setup writes the first profile row', () async {
      final history = await repo.taxProfileHistory();
      expect(history, hasLength(1));
      expect(history.single.mode, TaxMode.regular5);
    });

    test('a change adds a row dated today', () async {
      final at = DateTime(2026, 11, 8, 13);
      await OutletRepository(db, clock: () => at).updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.regular18,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      final history = await repo.taxProfileHistory();
      expect(history, hasLength(2));
      expect(history.first.from, const BusinessDate(2026, 4, 1),
          reason: 'setup, still on the record');
      expect(history.last.mode, TaxMode.regular18);
      expect(history.last.from, const BusinessDate(2026, 11, 8));
    });

    test('a change after midnight is dated the night before', () async {
      // The 4 AM cutoff. A mode changed at 1 AM belongs to the trading day
      // that is still running, not to the calendar date.
      await OutletRepository(db, clock: () => DateTime(2026, 11, 8, 1, 30))
          .updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.regular18,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      expect(
        (await repo.taxProfileHistory()).last.from,
        const BusinessDate(2026, 11, 7),
        reason: '1:30 AM is still the night before, with a 4 AM cutoff',
      );
    });

    test('changing twice in one day leaves one row for that day', () async {
      // This table answers "which mode applied on this date", and that has to
      // be one value. The flip-flop itself stays in the audit log.
      final at = DateTime(2026, 11, 8, 13);
      final dated = OutletRepository(db, clock: () => at);

      await dated.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.regular18,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );
      await dated.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.composition,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      final sameDay = (await repo.taxProfileHistory())
          .where((e) => e.from == const BusinessDate(2026, 11, 8));
      expect(sameDay, hasLength(1));
      expect(sameDay.single.mode, TaxMode.composition);

      // And both changes are still on the record.
      final modeChanges = (await db.select(db.auditLog).get())
          .where((e) => e.action == AuditAction.taxModeChanged);
      expect(modeChanges, hasLength(2));
    });

    test('editing only the FSSAI number writes no profile row', () async {
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '99999999999999',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );
      expect(await repo.taxProfileHistory(), hasLength(1));
    });
  });

  group('reading the mode back for a date', () {
    test('the mode that applied on a past day, not today\'s', () async {
      // The whole point of the dated history: an outlet that registered in
      // November must still explain an October bill as unregistered.
      await seed(mode: TaxMode.unregistered);

      await OutletRepository(db, clock: () => DateTime(2026, 11, 8, 13))
          .updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      expect(
        await repo.taxModeOn(const BusinessDate(2026, 11, 8)),
        TaxMode.regular5,
      );
      expect(
        await repo.taxModeOn(const BusinessDate(2026, 11, 9)),
        TaxMode.regular5,
      );
      expect(
        await repo.taxModeOn(const BusinessDate(2026, 10, 1)),
        TaxMode.unregistered,
        reason: 'October was before the registration',
      );
    });

    test('a date before the outlet existed has no answer', () async {
      expect(await repo.taxModeOn(const BusinessDate(2000, 1, 1)), isNull);
    });
  });

  group('bills already rung up do not move', () {
    test('an old bill keeps its amounts and its document type', () async {
      final before = await sell();
      expect(before.computed.docType, DocType.invoice);
      expect(before.computed.total, const Paise(25200));

      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '99999999999999',
          taxMode: TaxMode.unregistered,
        ),
        byUserId: ownerId,
      );

      final row = await (db.select(db.bills)
            ..where((b) => b.id.equals(before.id)))
          .getSingle();

      expect(row.total, const Paise(25200));
      expect(row.cgst, const Paise(600));
      expect(row.sgst, const Paise(600));
      expect(row.docType, DocType.invoice,
          reason: 'it was a tax invoice when it was issued, and still is');
      expect(row.invoiceNo, before.invoiceNo.formatted);
    });

    test('the next bill uses the new mode', () async {
      await sell();
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.unregistered,
        ),
        byUserId: ownerId,
      );

      final after = await sell();
      expect(after.computed.docType, DocType.billOfSupply);
      expect(after.computed.total, const Paise(24000),
          reason: 'no GST on an unregistered outlet');
    });

    test('the invoice sequence carries on across the change', () async {
      // The numbers must not restart or repeat: one of them is on a bill a
      // customer is holding.
      final first = await sell();
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.unregistered,
        ),
        byUserId: ownerId,
      );
      final second = await sell();

      expect(first.invoiceNo.formatted, 'A/2627/000001');
      expect(second.invoiceNo.formatted, 'A/2627/000002');
    });
  });

  group('the audit trail', () {
    test('a mode change is logged as one, with before and after', () async {
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '12345678901234',
          taxMode: TaxMode.unregistered,
        ),
        byUserId: ownerId,
      );

      final entry = (await db.select(db.auditLog).get())
          .lastWhere((e) => e.action == AuditAction.taxModeChanged);

      expect(entry.entity, AuditEntity.outlet);
      expect(entry.userId, ownerId);
      expect(entry.before, contains('regular_5'));
      expect(entry.after, contains('unregistered'));
    });

    test('a licence correction is logged as a setting change, not a mode '
        'change', () async {
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '99999999999999',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      final entries = await db.select(db.auditLog).get();
      expect(
        entries.where((e) => e.action == AuditAction.taxModeChanged),
        isEmpty,
      );
      final entry =
          entries.lastWhere((e) => e.action == AuditAction.settingChanged);
      expect(entry.before, contains('12345678901234'));
      expect(entry.after, contains('99999999999999'));
    });

    test('the old FSSAI number is recoverable from the log', () async {
      // Someone will mistype it and need to know what it was before.
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '99999999999999',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );
      final entry = (await db.select(db.auditLog).get())
          .lastWhere((e) => e.action == AuditAction.settingChanged);
      expect(entry.before, contains('12345678901234'));
    });
  });

  group('the name, address and phone', () {
    test('save, and reach the bills printed after', () async {
      final changed = await repo.updateIdentity(
        const OutletIdentity(
          name: 'Annapurna Mess & Tiffins',
          address: 'Shop 4, Main Road, Guntur',
          phone: '9888877777',
        ),
        byUserId: ownerId,
      );

      expect(changed, isTrue);
      final o = await outlet();
      expect(o.name, 'Annapurna Mess & Tiffins');
      expect(o.address, 'Shop 4, Main Road, Guntur');
      expect(o.phone, '9888877777');
    });

    test('are trimmed', () async {
      await repo.updateIdentity(
        const OutletIdentity(
          name: '  Annapurna Mess  ',
          address: '  Main Road  ',
          phone: '  9000000000  ',
        ),
        byUserId: ownerId,
      );
      final o = await outlet();
      expect(o.name, 'Annapurna Mess');
      expect(o.address, 'Main Road');
    });

    test('saving the same values reports no change', () async {
      final changed = await repo.updateIdentity(
        const OutletIdentity(
          name: 'Annapurna Mess',
          address: 'Main Road',
          phone: '9000000000',
        ),
        byUserId: ownerId,
      );
      expect(changed, isFalse);
    });

    test('an empty name, address or phone is refused', () async {
      for (final bad in const [
        OutletIdentity(name: '', address: 'Main Road', phone: '9000000000'),
        OutletIdentity(name: 'A', address: '  ', phone: '9000000000'),
        OutletIdentity(name: 'A', address: 'Main Road', phone: ''),
      ]) {
        await expectLater(
          repo.updateIdentity(bad, byUserId: ownerId),
          throwsA(isA<OutletError>()),
        );
      }
      expect((await outlet()).name, 'Annapurna Mess');
    });

    test('a name longer than the column allows is refused with a sentence',
        () async {
      // Without the check this fails inside drift with a constraint error,
      // which the screen would show to the owner as it is.
      await expectLater(
        repo.updateIdentity(
          OutletIdentity(
            name: 'A' * (kOutletNameMaxLength + 1),
            address: 'Main Road',
            phone: '9000000000',
          ),
          byUserId: ownerId,
        ),
        throwsA(
          isA<OutletError>().having(
            (e) => e.message,
            'message',
            contains('too long'),
          ),
        ),
      );
    });

    test('a name of exactly the limit is accepted', () async {
      final changed = await repo.updateIdentity(
        OutletIdentity(
          name: 'A' * kOutletNameMaxLength,
          address: 'Main Road',
          phone: '9000000000',
        ),
        byUserId: ownerId,
      );
      expect(changed, isTrue);
    });

    test('staff cannot', () async {
      await expectLater(
        repo.updateIdentity(
          const OutletIdentity(
            name: 'Not Annapurna',
            address: 'Main Road',
            phone: '9000000000',
          ),
          byUserId: staffId,
        ),
        throwsA(isA<OutletError>()),
      );
      expect((await outlet()).name, 'Annapurna Mess');
    });

    test('the change is audited with before and after', () async {
      await repo.updateIdentity(
        const OutletIdentity(
          name: 'Annapurna Mess & Tiffins',
          address: 'Main Road',
          phone: '9000000000',
        ),
        byUserId: ownerId,
      );

      final entry = (await db.select(db.auditLog).get())
          .lastWhere((e) => e.action == AuditAction.settingChanged);
      expect(entry.entity, AuditEntity.outlet);
      expect(entry.before, contains('Annapurna Mess'));
      expect(entry.after, contains('Tiffins'));
    });

    test('it does not touch the tax profile history', () async {
      await repo.updateIdentity(
        const OutletIdentity(
          name: 'Annapurna Mess & Tiffins',
          address: 'Main Road',
          phone: '9000000000',
        ),
        byUserId: ownerId,
      );
      expect(await repo.taxProfileHistory(), hasLength(1));
    });

    test('currentIdentity reflects what was saved', () async {
      await repo.updateIdentity(
        const OutletIdentity(
          name: 'Annapurna Mess & Tiffins',
          address: 'Shop 4',
          phone: '9888877777',
        ),
        byUserId: ownerId,
      );
      final now = await repo.currentIdentity();
      expect(now!.name, 'Annapurna Mess & Tiffins');
      expect(now.address, 'Shop 4');
      expect(now.phone, '9888877777');
    });

    test('a bill printed before the rename still reprints under the old '
        'name', () async {
      // The reason the bill snapshots its own header. Covered end to end in
      // test/printing/reprint_header_test.dart; this pins the stored value.
      final bill = await sell();
      await repo.updateIdentity(
        const OutletIdentity(
          name: 'Completely Different Mess',
          address: 'Elsewhere',
          phone: '9111111111',
        ),
        byUserId: ownerId,
      );

      final row = await (db.select(db.bills)
            ..where((b) => b.id.equals(bill.id)))
          .getSingle();
      expect(row.outletName, 'Annapurna Mess');
      expect(row.outletAddress, 'Main Road');
      expect(row.outletPhone, '9000000000');
    });
  });

  group('reading the current details', () {
    test('current() reflects what was saved', () async {
      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '99999999999999',
          taxMode: TaxMode.composition,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      final now = await repo.current();
      expect(now!.fssaiNo, '99999999999999');
      expect(now.taxMode, TaxMode.composition);
      expect(now.gstin, '37ABCDE1234F1Z5');
    });

    test('watch() sees a change made while it is being watched', () async {
      final seen = repo.watch();

      await repo.updateBillDetails(
        const BillDetails(
          fssaiNo: '99999999999999',
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        ),
        byUserId: ownerId,
      );

      await expectLater(
        seen,
        emitsThrough(
          predicate<BillDetails?>((d) => d?.fssaiNo == '99999999999999'),
        ),
      );
    });

    test('current() is null before setup', () async {
      final empty = PosDatabase.memory();
      addTearDown(empty.close);
      expect(await OutletRepository(empty).current(), isNull);
    });
  });
}
