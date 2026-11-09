/// First-run setup: the outlet, the device, and the owner.
///
/// Nothing can be billed until this has run. The whole thing commits in one
/// transaction, so a half-configured app is not a state that can exist: either
/// there is an outlet, a device and an owner, or there is none of it.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/business_date.dart';
import '../core/domain.dart';
import '../core/invoice_no.dart';
import '../core/pin.dart';
import '../core/tax.dart';
import 'bill_repository.dart' show isValidFssai;
import 'db.dart';

class SetupError implements Exception {
  SetupError(this.message);
  final String message;
  @override
  String toString() => 'SetupError: $message';
}

/// What the setup screens collect.
class SetupDetails {
  const SetupDetails({
    required this.outletName,
    required this.address,
    required this.phone,
    required this.fssaiNo,
    required this.taxMode,
    required this.ownerName,
    required this.ownerPin,
    required this.devicePrefix,
    this.gstin,
    this.pricesIncludeTax = false,
    this.billFooter = '',
    this.upiVpa,
    this.businessDayCutoffMinutes = 240,
    this.sacCode = '9963',
  });

  final String outletName;
  final String address;
  final String phone;
  final String fssaiNo;
  final TaxMode taxMode;
  final String? gstin;
  final bool pricesIncludeTax;
  final String billFooter;
  final String? upiVpa;
  final int businessDayCutoffMinutes;
  final String sacCode;

  final String ownerName;
  final String ownerPin;
  final String devicePrefix;
}

/// The ids created by setup, so the caller can sign the owner straight in.
class SetupResult {
  const SetupResult({
    required this.outletId,
    required this.deviceId,
    required this.ownerId,
  });

  final String outletId;
  final String deviceId;
  final String ownerId;
}

class SetupRepository {
  SetupRepository(this._db, {Uuid? uuid, DateTime Function()? clock})
      : _uuid = uuid ?? const Uuid(),
        _clock = clock ?? DateTime.now;

  final PosDatabase _db;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// Whether setup has already run. The app routes on this at launch.
  Future<bool> isConfigured() async {
    final outlet = await _db.select(_db.outlets).getSingleOrNull();
    if (outlet == null) return false;
    final device = await _db.select(_db.devices).getSingleOrNull();
    if (device == null) return false;
    final owners = await (_db.select(_db.users)
          ..where((u) => u.role.equals(UserRole.owner.wireName)))
        .get();
    return owners.isNotEmpty;
  }

  /// Validates everything up front and returns the problems, so the screen can
  /// show them all at once rather than one per attempt.
  ///
  /// Returns an empty list when the details are good.
  List<String> validate(SetupDetails d) {
    final problems = <String>[];

    if (d.outletName.trim().isEmpty) {
      problems.add('The restaurant needs a name.');
    }
    if (d.address.trim().isEmpty) {
      problems.add('The address is printed on every bill, so it is required.');
    }
    if (d.phone.trim().isEmpty) {
      problems.add('A phone number is printed on every bill.');
    }

    // The brief: block billing until a valid FSSAI number is saved. Easier to
    // block it here, at the only point one can be created.
    if (!isValidFssai(d.fssaiNo)) {
      problems.add('The FSSAI licence number must be exactly 14 digits.');
    }

    // A regular registration without a GSTIN would print a tax invoice with no
    // GSTIN on it, which is not a valid tax invoice.
    final needsGstin =
        d.taxMode == TaxMode.regular5 || d.taxMode == TaxMode.regular18;
    if (needsGstin && (d.gstin == null || d.gstin!.trim().isEmpty)) {
      problems.add('A GSTIN is required when registered under regular GST.');
    }
    if (d.gstin != null &&
        d.gstin!.trim().isNotEmpty &&
        !isValidGstin(d.gstin!)) {
      problems.add('That GSTIN is not 15 characters in the expected format.');
    }

    if (d.ownerName.trim().isEmpty) {
      problems.add('The owner needs a name.');
    }
    final pinProblem = pinRejectionReason(d.ownerPin);
    if (pinProblem != null) problems.add(pinProblem);

    if (!InvoiceNo.isValidDevicePrefix(d.devicePrefix)) {
      problems.add('The device letter must be a single letter, A to Z.');
    }

    if (d.businessDayCutoffMinutes < 0 ||
        d.businessDayCutoffMinutes >= 24 * 60) {
      problems.add('The day cutoff must be a time of day.');
    }

    return problems;
  }

  /// Runs setup. One transaction: outlet, tax profile, device, owner, audit.
  Future<SetupResult> completeSetup(SetupDetails d, {DateTime? at}) async {
    final now = at ?? _clock();

    final problems = validate(d);
    if (problems.isNotEmpty) {
      throw SetupError(problems.join(' '));
    }

    return _db.transaction(() async {
      if (await isConfigured()) {
        throw SetupError('This device has already been set up.');
      }

      final outletId = _uuid.v7();
      final deviceId = _uuid.v7();
      final ownerId = _uuid.v7();
      final businessDate = BusinessDate.of(
        now,
        cutoff: Duration(minutes: d.businessDayCutoffMinutes),
      );

      await _db.into(_db.outlets).insert(OutletsCompanion.insert(
            id: outletId,
            name: d.outletName.trim(),
            address: d.address.trim(),
            phone: d.phone.trim(),
            gstin: Value(d.gstin?.trim().toUpperCase()),
            fssaiNo: d.fssaiNo.trim(),
            taxMode: d.taxMode,
            pricesIncludeTax: Value(d.pricesIncludeTax),
            billFooter: Value(d.billFooter.trim()),
            upiVpa: Value(d.upiVpa?.trim()),
            businessDayCutoffMinutes: Value(d.businessDayCutoffMinutes),
            sacCode: Value(d.sacCode),
          ));

      // The tax mode is recorded with its effective date from the very first
      // day, so a bill from any point in the outlet's life can be explained.
      await _db.into(_db.taxProfileHistory).insert(
            TaxProfileHistoryCompanion.insert(
              id: _uuid.v7(),
              outletId: outletId,
              taxMode: d.taxMode,
              effectiveFrom: businessDate,
            ),
          );

      await _db.into(_db.devices).insert(DevicesCompanion.insert(
            id: deviceId,
            outletId: outletId,
            seriesPrefix: d.devicePrefix.toUpperCase(),
            nextSeq: const Value(1),
            seqFy: businessDate.financialYear,
          ));

      await _db.into(_db.users).insert(UsersCompanion.insert(
            id: ownerId,
            name: d.ownerName.trim(),
            role: UserRole.owner,
            pinHash: hashPin(d.ownerPin),
          ));

      await _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: _uuid.v7(),
            at: now,
            userId: Value(ownerId),
            deviceId: deviceId,
            action: AuditAction.settingChanged,
            entity: AuditEntity.outlet,
            entityId: outletId,
            after: Value(jsonEncode({
              'event': 'first_run_setup',
              'outlet_name': d.outletName.trim(),
              'fssai_no': d.fssaiNo.trim(),
              'tax_mode': d.taxMode.wireName,
              'gstin': d.gstin?.trim().toUpperCase(),
              'prices_include_tax': d.pricesIncludeTax,
              'device_prefix': d.devicePrefix.toUpperCase(),
              'business_day_cutoff_minutes': d.businessDayCutoffMinutes,
              'sac_code': d.sacCode,
              'owner_name': d.ownerName.trim(),
              // The PIN and its hash are deliberately absent.
            })),
          ));

      return SetupResult(
        outletId: outletId,
        deviceId: deviceId,
        ownerId: ownerId,
      );
    });
  }

  /// Adds a staff member. Owner only.
  Future<String> addUser({
    required String name,
    required UserRole role,
    required String pin,
    required String byUserId,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    final pinProblem = pinRejectionReason(pin);
    if (pinProblem != null) throw SetupError(pinProblem);
    if (name.trim().isEmpty) throw SetupError('A user needs a name.');

    return _db.transaction(() async {
      final by = await (_db.select(_db.users)
            ..where((u) => u.id.equals(byUserId)))
          .getSingleOrNull();
      if (by == null || !Permission.manageUsers.allows(by.role)) {
        throw SetupError('Only the owner can add a user.');
      }

      final id = _uuid.v7();
      await _db.into(_db.users).insert(UsersCompanion.insert(
            id: id,
            name: name.trim(),
            role: role,
            pinHash: hashPin(pin),
          ));

      await _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: _uuid.v7(),
            at: now,
            userId: Value(byUserId),
            deviceId: await _deviceId(),
            action: AuditAction.userCreated,
            entity: AuditEntity.user,
            entityId: id,
            after: Value(jsonEncode({
              'name': name.trim(),
              'role': role.wireName,
            })),
          ));

      return id;
    });
  }

  /// Deactivates a user. They are never deleted, so the bills they rang up keep
  /// a valid reference.
  Future<void> deactivateUser({
    required String userId,
    required String byUserId,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    await _db.transaction(() async {
      final by = await (_db.select(_db.users)
            ..where((u) => u.id.equals(byUserId)))
          .getSingleOrNull();
      if (by == null || !Permission.manageUsers.allows(by.role)) {
        throw SetupError('Only the owner can deactivate a user.');
      }
      if (userId == byUserId) {
        throw SetupError('You cannot deactivate yourself.');
      }

      final target = await (_db.select(_db.users)
            ..where((u) => u.id.equals(userId)))
          .getSingleOrNull();
      if (target == null) throw SetupError('No such user.');

      // Leaving no active owner would lock everyone out of settings, reports
      // and cancellations permanently, with no way back in.
      if (target.role == UserRole.owner) {
        final owners = await (_db.select(_db.users)
              ..where((u) =>
                  u.role.equals(UserRole.owner.wireName) &
                  u.isActive.equals(true)))
            .get();
        if (owners.length <= 1) {
          throw SetupError('There must be at least one active owner.');
        }
      }

      await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
          .write(const UsersCompanion(isActive: Value(false)));

      await _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: _uuid.v7(),
            at: now,
            userId: Value(byUserId),
            deviceId: await _deviceId(),
            action: AuditAction.userEdited,
            entity: AuditEntity.user,
            entityId: userId,
            before: Value(jsonEncode({'is_active': true})),
            after: Value(jsonEncode({'is_active': false})),
          ));
    });
  }

  /// Brings a deactivated user back. Owner only.
  ///
  /// The counterpart to [deactivateUser], for the same reason the menu can
  /// enable a disabled item: deactivating the wrong person by mistake should
  /// not be a one-way door whose only exit is a second account with the same
  /// name.
  Future<void> reactivateUser({
    required String userId,
    required String byUserId,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    await _db.transaction(() async {
      final by = await (_db.select(_db.users)
            ..where((u) => u.id.equals(byUserId)))
          .getSingleOrNull();
      if (by == null || !Permission.manageUsers.allows(by.role)) {
        throw SetupError('Only the owner can bring a user back.');
      }

      final target = await (_db.select(_db.users)
            ..where((u) => u.id.equals(userId)))
          .getSingleOrNull();
      if (target == null) throw SetupError('No such user.');

      // Their PIN is whatever it was. Nothing here touches it, so coming back
      // does not quietly hand out a known PIN.
      await (_db.update(_db.users)..where((u) => u.id.equals(userId)))
          .write(const UsersCompanion(isActive: Value(true)));

      await _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: _uuid.v7(),
            at: now,
            userId: Value(byUserId),
            deviceId: await _deviceId(),
            action: AuditAction.userEdited,
            entity: AuditEntity.user,
            entityId: userId,
            before: Value(jsonEncode({'is_active': false})),
            after: Value(jsonEncode({'is_active': true})),
          ));
    });
  }

  Future<String> _deviceId() async {
    final device = await _db.select(_db.devices).getSingleOrNull();
    if (device == null) throw SetupError('This device is not set up.');
    return device.id;
  }
}

/// A GSTIN is 15 characters: 2 digits state, 10 character PAN, 1 entity digit,
/// a literal Z, then a checksum character.
///
/// Only the shape is checked. The checksum is not verified, because getting it
/// wrong would block a real restaurant from billing over an arithmetic detail,
/// and the CA sees the number anyway.
bool isValidGstin(String value) => RegExp(
      r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$',
    ).hasMatch(value.trim().toUpperCase());
