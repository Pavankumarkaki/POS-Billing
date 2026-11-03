/// Role permissions, enumerated rather than spot-checked.
///
/// The brief: "Only the owner can cancel bills, edit the menu, change
/// settings, or view reports." Everything else is open to staff. These tests
/// walk every permission and assert both answers, so adding a new permission
/// without deciding who may use it fails here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';

void main() {
  group('the owner may do everything', () {
    for (final p in Permission.values) {
      test('owner may ${p.name}', () {
        expect(p.allows(UserRole.owner), isTrue);
      });
    }
  });

  group('staff may bill and reprint, and nothing else', () {
    const staffMay = {Permission.createBill, Permission.reprintBill};

    for (final p in Permission.values) {
      final expected = staffMay.contains(p);
      test('staff may${expected ? '' : ' not'} ${p.name}', () {
        expect(p.allows(UserRole.staff), expected);
      });
    }

    test('the four the brief names are owner only', () {
      expect(Permission.cancelBill.allows(UserRole.staff), isFalse);
      expect(Permission.editMenu.allows(UserRole.staff), isFalse);
      expect(Permission.changeSettings.allows(UserRole.staff), isFalse);
      expect(Permission.viewReports.allows(UserRole.staff), isFalse);
    });

    test('every permission has an explicit answer for both roles', () {
      // Guards against a new enum value falling through to a default that
      // happens to grant access.
      for (final p in Permission.values) {
        for (final r in UserRole.values) {
          expect(() => p.allows(r), returnsNormally, reason: '${p.name}/$r');
        }
      }
      expect(Permission.values, hasLength(8),
          reason: 'add a case above when a permission is added');
    });
  });

  group('wire names are stable', () {
    test('roles', () {
      expect(UserRole.owner.wireName, 'owner');
      expect(UserRole.staff.wireName, 'staff');
      for (final r in UserRole.values) {
        expect(UserRole.parse(r.wireName), r);
      }
    });

    test('bill status', () {
      expect(BillStatus.paid.wireName, 'paid');
      expect(BillStatus.cancelled.wireName, 'cancelled');
      for (final s in BillStatus.values) {
        expect(BillStatus.parse(s.wireName), s);
      }
    });

    test('payment modes, as the brief spells them', () {
      expect(
        PaymentMode.values.map((m) => m.wireName).toList(),
        ['cash', 'upi', 'card', 'aggregator', 'credit'],
      );
      for (final m in PaymentMode.values) {
        expect(PaymentMode.parse(m.wireName), m);
      }
    });

    test('only cash takes change', () {
      expect(PaymentMode.cash.takesChange, isTrue);
      for (final m in PaymentMode.values.where((m) => m != PaymentMode.cash)) {
        expect(m.takesChange, isFalse, reason: m.wireName);
      }
    });

    test('audit actions and entities round trip', () {
      for (final a in AuditAction.values) {
        expect(AuditAction.parse(a.wireName), a);
      }
      for (final e in AuditEntity.values) {
        expect(AuditEntity.parse(e.wireName), e);
      }
    });

    test('an unknown stored value is rejected, not guessed at', () {
      expect(() => UserRole.parse('admin'), throwsA(isA<UnknownWireValue>()));
      expect(() => BillStatus.parse('void'), throwsA(isA<UnknownWireValue>()));
      expect(
        () => PaymentMode.parse('bitcoin'),
        throwsA(isA<UnknownWireValue>()),
      );
      expect(
        () => AuditAction.parse('nonsense'),
        throwsA(isA<UnknownWireValue>()),
      );
    });

    test('wire names are unique within each enum', () {
      expect(
        PaymentMode.values.map((e) => e.wireName).toSet(),
        hasLength(PaymentMode.values.length),
      );
      expect(
        AuditAction.values.map((e) => e.wireName).toSet(),
        hasLength(AuditAction.values.length),
      );
      expect(
        AuditEntity.values.map((e) => e.wireName).toSet(),
        hasLength(AuditEntity.values.length),
      );
    });
  });
}
