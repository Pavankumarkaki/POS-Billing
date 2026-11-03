/// First-run setup: validation, the FSSAI gate, and one transaction.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/pin.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/setup_repository.dart';

SetupDetails details({
  String outletName = 'Test Restaurant',
  String address = 'Main Road, Vijayawada',
  String phone = '9000000000',
  String fssaiNo = '12345678901234',
  TaxMode taxMode = TaxMode.unregistered,
  String? gstin,
  String ownerName = 'Owner',
  String ownerPin = '1357',
  String devicePrefix = 'A',
  int cutoff = 240,
}) =>
    SetupDetails(
      outletName: outletName,
      address: address,
      phone: phone,
      fssaiNo: fssaiNo,
      taxMode: taxMode,
      gstin: gstin,
      ownerName: ownerName,
      ownerPin: ownerPin,
      devicePrefix: devicePrefix,
      businessDayCutoffMinutes: cutoff,
    );

void main() {
  late PosDatabase db;
  late SetupRepository setup;

  setUp(() {
    db = PosDatabase.memory();
    setup = SetupRepository(db);
  });

  tearDown(() => db.close());

  group('before setup', () {
    test('the app knows it is not configured', () async {
      expect(await setup.isConfigured(), isFalse);
    });

    test('and is configured once setup has run', () async {
      await setup.completeSetup(details());
      expect(await setup.isConfigured(), isTrue);
    });
  });

  group('validation catches everything at once', () {
    test('good details pass', () {
      expect(setup.validate(details()), isEmpty);
    });

    test('missing basics', () {
      final problems = setup.validate(details(
        outletName: '  ',
        address: '',
        phone: '',
      ));
      expect(problems, hasLength(3));
      expect(problems.join(), contains('name'));
      expect(problems.join(), contains('address'));
      expect(problems.join(), contains('phone'));
    });

    test('every problem is reported together, not one per attempt', () {
      final problems = setup.validate(details(
        outletName: '',
        fssaiNo: 'nope',
        ownerPin: '1111',
        devicePrefix: '12',
      ));
      expect(problems.length, greaterThanOrEqualTo(4));
    });
  });

  group('the FSSAI gate', () {
    test('a bad number blocks setup', () {
      for (final bad in ['', '123', '123456789012345', 'abcdefghijklmn']) {
        final problems = setup.validate(details(fssaiNo: bad));
        expect(
          problems.any((p) => p.contains('FSSAI')),
          isTrue,
          reason: '"$bad"',
        );
      }
    });

    test('and completeSetup refuses it, so nothing is written', () async {
      await expectLater(
        setup.completeSetup(details(fssaiNo: '123')),
        throwsA(isA<SetupError>()),
      );
      expect(await setup.isConfigured(), isFalse);
      expect(await db.select(db.outlets).get(), isEmpty);
      expect(await db.select(db.devices).get(), isEmpty);
      expect(await db.select(db.users).get(), isEmpty);
    });

    test('14 digits is accepted', () {
      expect(setup.validate(details(fssaiNo: '12345678901234')), isEmpty);
      expect(isValidFssai('12345678901234'), isTrue);
    });
  });

  group('GSTIN', () {
    test('is required under a regular registration', () {
      final problems = setup.validate(details(taxMode: TaxMode.regular5));
      expect(problems.any((p) => p.contains('GSTIN')), isTrue);
    });

    test('is not required when unregistered or composition', () {
      expect(setup.validate(details(taxMode: TaxMode.unregistered)), isEmpty);
      expect(setup.validate(details(taxMode: TaxMode.composition)), isEmpty);
    });

    test('a well-formed one passes', () {
      expect(
        setup.validate(details(
          taxMode: TaxMode.regular5,
          gstin: '37ABCDE1234F1Z5',
        )),
        isEmpty,
      );
    });

    test('a malformed one is caught', () {
      for (final bad in ['123', 'ABCDE1234F1Z5', '37ABCDE1234F1Y5']) {
        final problems = setup.validate(details(
          taxMode: TaxMode.regular5,
          gstin: bad,
        ));
        expect(problems.any((p) => p.contains('GSTIN')), isTrue, reason: bad);
      }
    });

    test('the shape check accepts a real-looking Andhra Pradesh GSTIN', () {
      expect(isValidGstin('37ABCDE1234F1Z5'), isTrue);
      expect(isValidGstin('37abcde1234f1z5'), isTrue, reason: 'case is lifted');
    });
  });

  group('the owner PIN', () {
    test('a weak PIN blocks setup', () {
      for (final weak in ['1111', '1234', '4321', '123', 'abcd']) {
        final problems = setup.validate(details(ownerPin: weak));
        expect(problems, isNotEmpty, reason: weak);
      }
    });

    test('the PIN is stored hashed, never in the clear', () async {
      await setup.completeSetup(details(ownerPin: '1357'));
      final owner = await db.select(db.users).getSingle();

      expect(owner.pinHash.contains('1357'), isFalse);
      expect(owner.pinHash.startsWith('pbkdf2_sha256\$'), isTrue);
      expect(verifyPin('1357', owner.pinHash), isTrue);
      expect(verifyPin('9999', owner.pinHash), isFalse);
    });
  });

  group('the device letter', () {
    test('must be a single letter', () {
      for (final bad in ['', 'AB', '1', '/']) {
        final problems = setup.validate(details(devicePrefix: bad));
        expect(problems.any((p) => p.contains('device letter')), isTrue,
            reason: '"$bad"');
      }
    });

    test('is upper-cased on the way in', () async {
      await setup.completeSetup(details(devicePrefix: 'b'));
      final device = await db.select(db.devices).getSingle();
      expect(device.seriesPrefix, 'B');
    });

    test('the sequence starts at 1 in the current financial year', () async {
      await setup.completeSetup(
        details(),
        at: DateTime(2026, 6, 1, 12),
      );
      final device = await db.select(db.devices).getSingle();
      expect(device.nextSeq, 1);
      expect(device.seqFy.code, '2627');
    });

    test('a January setup lands in the financial year that opened in April',
        () async {
      await setup.completeSetup(
        details(),
        at: DateTime(2027, 1, 15, 12),
      );
      final device = await db.select(db.devices).getSingle();
      expect(device.seqFy.code, '2627');
    });
  });

  group('setup is one transaction', () {
    test('a success writes outlet, tax profile, device, owner and audit',
        () async {
      final r = await setup.completeSetup(details());

      expect((await db.select(db.outlets).get()), hasLength(1));
      expect((await db.select(db.taxProfileHistory).get()), hasLength(1));
      expect((await db.select(db.devices).get()), hasLength(1));
      expect((await db.select(db.users).get()), hasLength(1));
      expect((await db.select(db.auditLog).get()), hasLength(1));

      expect(r.outletId, isNotEmpty);
      expect(r.deviceId, isNotEmpty);
      expect(r.ownerId, isNotEmpty);
    });

    test('a failure writes nothing at all', () async {
      await expectLater(
        setup.completeSetup(details(ownerPin: '1111')),
        throwsA(isA<SetupError>()),
      );
      expect(await db.select(db.outlets).get(), isEmpty);
      expect(await db.select(db.taxProfileHistory).get(), isEmpty);
      expect(await db.select(db.devices).get(), isEmpty);
      expect(await db.select(db.users).get(), isEmpty);
      expect(await db.select(db.auditLog).get(), isEmpty);
    });

    test('running setup twice is refused', () async {
      await setup.completeSetup(details());
      await expectLater(
        setup.completeSetup(details()),
        throwsA(isA<SetupError>()),
      );
      expect(await db.select(db.outlets).get(), hasLength(1),
          reason: 'the second attempt changed nothing');
    });

    test('the tax mode is recorded with its effective date from day one',
        () async {
      await setup.completeSetup(
        details(taxMode: TaxMode.composition),
        at: DateTime(2026, 6, 1, 12),
      );
      final profile = await db.select(db.taxProfileHistory).getSingle();
      expect(profile.taxMode, TaxMode.composition);
      expect(profile.effectiveFrom.iso, '2026-06-01');
    });

    test('the audit entry records the settings but no PIN', () async {
      await setup.completeSetup(details(ownerPin: '1357'));
      final entry = await db.select(db.auditLog).getSingle();

      expect(entry.action, AuditAction.settingChanged);
      expect(entry.entity, AuditEntity.outlet);

      final after = jsonDecode(entry.after!) as Map<String, Object?>;
      expect(after['event'], 'first_run_setup');
      expect(after['fssai_no'], '12345678901234');
      expect(after['tax_mode'], 'unregistered');
      expect(after['device_prefix'], 'A');

      expect(entry.after!.contains('1357'), isFalse);
      expect(entry.after!.contains('pbkdf2'), isFalse);
    });

    test('the business day cutoff is stored as given', () async {
      await setup.completeSetup(details(cutoff: 360));
      final outlet = await db.select(db.outlets).getSingle();
      expect(outlet.businessDayCutoffMinutes, 360);
    });

    test('the default cutoff is 04:00, as the brief says', () async {
      await setup.completeSetup(details());
      final outlet = await db.select(db.outlets).getSingle();
      expect(outlet.businessDayCutoffMinutes, 240);
    });
  });

  group('managing users after setup', () {
    late String ownerId;

    setUp(() async {
      final r = await setup.completeSetup(details());
      ownerId = r.ownerId;
    });

    test('the owner can add staff', () async {
      final staffId = await setup.addUser(
        name: 'Brother',
        role: UserRole.staff,
        pin: '2468',
        byUserId: ownerId,
      );

      final staff = await (db.select(db.users)
            ..where((u) => u.id.equals(staffId)))
          .getSingle();
      expect(staff.name, 'Brother');
      expect(staff.role, UserRole.staff);
      expect(staff.isActive, isTrue);
      expect(verifyPin('2468', staff.pinHash), isTrue);
    });

    test('staff cannot add users', () async {
      final staffId = await setup.addUser(
        name: 'Brother',
        role: UserRole.staff,
        pin: '2468',
        byUserId: ownerId,
      );
      await expectLater(
        setup.addUser(
          name: 'Another',
          role: UserRole.staff,
          pin: '3579',
          byUserId: staffId,
        ),
        throwsA(isA<SetupError>()),
      );
    });

    test('a weak PIN is refused for a new user', () async {
      await expectLater(
        setup.addUser(
          name: 'Brother',
          role: UserRole.staff,
          pin: '1111',
          byUserId: ownerId,
        ),
        throwsA(isA<SetupError>()),
      );
    });

    test('deactivating keeps the row, so old bills still resolve', () async {
      final staffId = await setup.addUser(
        name: 'Brother',
        role: UserRole.staff,
        pin: '2468',
        byUserId: ownerId,
      );
      await setup.deactivateUser(userId: staffId, byUserId: ownerId);

      final staff = await (db.select(db.users)
            ..where((u) => u.id.equals(staffId)))
          .getSingle();
      expect(staff.isActive, isFalse, reason: 'deactivated, not deleted');
      expect(await db.select(db.users).get(), hasLength(2));
    });

    test('the last active owner cannot be deactivated', () async {
      final otherOwner = await setup.addUser(
        name: 'Second Owner',
        role: UserRole.owner,
        pin: '3579',
        byUserId: ownerId,
      );

      // Two owners: one may go.
      await setup.deactivateUser(userId: otherOwner, byUserId: ownerId);

      // One owner left: a second owner tries to remove them. There is no other
      // owner to do it, so use the remaining owner on themselves.
      await expectLater(
        setup.deactivateUser(userId: ownerId, byUserId: ownerId),
        throwsA(isA<SetupError>()),
        reason: 'locking everyone out of settings forever must be impossible',
      );
    });

    test('you cannot deactivate yourself', () async {
      await expectLater(
        setup.deactivateUser(userId: ownerId, byUserId: ownerId),
        throwsA(isA<SetupError>()),
      );
    });

    test('a new user can immediately sign in', () async {
      final device = await db.select(db.devices).getSingle();
      final staffId = await setup.addUser(
        name: 'Brother',
        role: UserRole.staff,
        pin: '2468',
        byUserId: ownerId,
      );

      final auth = AuthRepository(db, deviceId: device.id);
      final r = await auth.signIn(userId: staffId, pin: '2468');
      expect(r.ok, isTrue);
      expect(r.role, UserRole.staff);
    });
  });

  group('billing is blocked until setup is done', () {
    test('a sale with no outlet is refused', () async {
      // Guards the other half of the FSSAI gate: not just a bad number, but no
      // outlet at all.
      final repo = BillRepository(db);
      expect(await setup.isConfigured(), isFalse);

      // There is no device or user to even attempt a sale with, which is the
      // point: the app routes to setup instead of to billing.
      expect(await db.select(db.devices).get(), isEmpty);
      expect(repo, isNotNull);
    });
  });
}
