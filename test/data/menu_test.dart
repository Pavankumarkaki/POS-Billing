/// Menu management: permissions, the disable-never-delete rule, and the
/// guarantee that editing the menu cannot change a bill already written.
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
import 'package:restaurant_pos/data/menu_repository.dart';

import 'fixture.dart';

void main() {
  late Fixture f;
  late MenuRepository menu;

  setUp(() async {
    f = await Fixture.create();
    menu = MenuRepository(f.db, deviceId: kDeviceId);
  });

  tearDown(() => f.close());

  group('permissions', () {
    test('the owner can create an item', () async {
      final id = await menu.createItem(
        categoryId: kCategoryId,
        nameEn: 'Chicken 65',
        price: Paise.fromRupees(210),
        taxClass: TaxClass.gst5,
        byUserId: kOwnerId,
      );
      expect(await menu.item(id), isNotNull);
    });

    test('staff cannot create, edit, disable or reorder', () async {
      await expectLater(
        menu.createItem(
          categoryId: kCategoryId,
          nameEn: 'Chicken 65',
          price: Paise.fromRupees(210),
          taxClass: TaxClass.gst5,
          byUserId: kStaffId,
        ),
        throwsA(isA<MenuError>()),
      );
      await expectLater(
        menu.updateItem(id: kItemBiryani, byUserId: kStaffId, nameEn: 'X'),
        throwsA(isA<MenuError>()),
      );
      await expectLater(
        menu.setItemActive(
          id: kItemBiryani,
          isActive: false,
          byUserId: kStaffId,
        ),
        throwsA(isA<MenuError>()),
      );
      await expectLater(
        menu.reorderItems(orderedIds: [kItemBiryani], byUserId: kStaffId),
        throwsA(isA<MenuError>()),
      );
      await expectLater(
        menu.createCategory(nameEn: 'Sweets', byUserId: kStaffId),
        throwsA(isA<MenuError>()),
      );
    });

    test('a staff attempt changes nothing', () async {
      final before = await menu.item(kItemBiryani);
      await expectLater(
        menu.updateItem(
          id: kItemBiryani,
          byUserId: kStaffId,
          price: Paise.fromRupees(999),
        ),
        throwsA(isA<MenuError>()),
      );
      final after = await menu.item(kItemBiryani);
      expect(after!.pricePaise.value, before!.pricePaise.value);
    });

    test('an unknown or deactivated user cannot edit', () async {
      await expectLater(
        menu.updateItem(id: kItemBiryani, byUserId: 'nobody', nameEn: 'X'),
        throwsA(isA<MenuError>()),
      );
      await (f.db.update(f.db.users)..where((u) => u.id.equals(kOwnerId)))
          .write(const UsersCompanion(isActive: Value(false)));
      await expectLater(
        menu.updateItem(id: kItemBiryani, byUserId: kOwnerId, nameEn: 'X'),
        throwsA(isA<MenuError>()),
      );
    });
  });

  group('categories and subcategories', () {
    test('a null parent is a category, a set one a subcategory', () async {
      final tiffins =
          await menu.createCategory(nameEn: 'Tiffins', byUserId: kOwnerId);
      await menu.createCategory(
        nameEn: 'Dosa',
        parentId: tiffins,
        byUserId: kOwnerId,
      );

      final tree = await menu.categoryTree();
      final node = tree.firstWhere((t) => t.category.id == tiffins);
      expect(node.category.parentId, isNull);
      expect(node.children, hasLength(1));
      expect(node.children.single.nameEn, 'Dosa');
    });

    test('nesting stops at one level', () async {
      final tiffins =
          await menu.createCategory(nameEn: 'Tiffins', byUserId: kOwnerId);
      final dosa = await menu.createCategory(
        nameEn: 'Dosa',
        parentId: tiffins,
        byUserId: kOwnerId,
      );
      await expectLater(
        menu.createCategory(
          nameEn: 'Plain',
          parentId: dosa,
          byUserId: kOwnerId,
        ),
        throwsA(isA<MenuError>()),
      );
    });

    test('Telugu names are stored', () async {
      final id = await menu.createCategory(
        nameEn: 'Tiffins',
        nameTe: 'టిఫిన్లు',
        byUserId: kOwnerId,
      );
      final tree = await menu.categoryTree();
      expect(
        tree.firstWhere((t) => t.category.id == id).category.nameTe,
        'టిఫిన్లు',
      );
    });

    test('hiding a category hides its items and subcategories', () async {
      final sub = await menu.createCategory(
        nameEn: 'Chicken',
        parentId: kCategoryId,
        byUserId: kOwnerId,
      );
      await menu.updateCategory(
        id: kCategoryId,
        isActive: false,
        byUserId: kOwnerId,
      );

      final items = await menu.activeItems();
      expect(items, isEmpty, reason: 'nothing under it may still be sellable');

      final hiddenSub = await (f.db.select(f.db.categories)
            ..where((c) => c.id.equals(sub)))
          .getSingle();
      expect(hiddenSub.isActive, isFalse);
    });

    test('a category needs an English name', () async {
      await expectLater(
        menu.createCategory(nameEn: '   ', byUserId: kOwnerId),
        throwsA(isA<MenuError>()),
      );
    });
  });

  group('items', () {
    test('both names, price and tax class are stored', () async {
      final id = await menu.createItem(
        categoryId: kCategoryId,
        nameEn: 'Gongura Mutton',
        nameTe: 'గోంగూర మటన్',
        price: Paise.fromRupees(320),
        taxClass: TaxClass.gst5,
        byUserId: kOwnerId,
      );
      final row = await menu.item(id);
      expect(row!.nameEn, 'Gongura Mutton');
      expect(row.nameTe, 'గోంగూర మటన్');
      expect(row.pricePaise.value, 32000);
      expect(row.taxClass, TaxClass.gst5);
      expect(row.isActive, isTrue);
    });

    test('an item needs a name and a non-negative price', () async {
      await expectLater(
        menu.createItem(
          categoryId: kCategoryId,
          nameEn: '  ',
          price: Paise.fromRupees(10),
          taxClass: TaxClass.gst5,
          byUserId: kOwnerId,
        ),
        throwsA(isA<MenuError>()),
      );
      await expectLater(
        menu.createItem(
          categoryId: kCategoryId,
          nameEn: 'Free sample',
          price: const Paise(-1),
          taxClass: TaxClass.gst5,
          byUserId: kOwnerId,
        ),
        throwsA(isA<MenuError>()),
      );
    });

    test('a zero price is allowed, for a complimentary item', () async {
      final id = await menu.createItem(
        categoryId: kCategoryId,
        nameEn: 'Water (free)',
        price: Paise.zero,
        taxClass: TaxClass.nonGst,
        byUserId: kOwnerId,
      );
      expect((await menu.item(id))!.pricePaise.value, 0);
    });

    test('an item cannot be filed under a category that does not exist',
        () async {
      await expectLater(
        menu.createItem(
          categoryId: 'nope',
          nameEn: 'Ghost',
          price: Paise.fromRupees(10),
          taxClass: TaxClass.gst5,
          byUserId: kOwnerId,
        ),
        throwsA(isA<MenuError>()),
      );
    });

    test('new items get an increasing sort order', () async {
      final a = await menu.createItem(
        categoryId: kCategoryId,
        nameEn: 'A',
        price: Paise.fromRupees(10),
        taxClass: TaxClass.gst5,
        byUserId: kOwnerId,
      );
      final b = await menu.createItem(
        categoryId: kCategoryId,
        nameEn: 'B',
        price: Paise.fromRupees(10),
        taxClass: TaxClass.gst5,
        byUserId: kOwnerId,
      );
      expect((await menu.item(b))!.sort,
          greaterThan((await menu.item(a))!.sort));
    });

    test('reordering rewrites sort in the order given', () async {
      final ids = [kItemWater, kItemColdDrink, kItemBiryani];
      await menu.reorderItems(orderedIds: ids, byUserId: kOwnerId);
      for (var i = 0; i < ids.length; i++) {
        expect((await menu.item(ids[i]))!.sort, i);
      }
    });
  });

  group('disable, never delete', () {
    test('disabling hides from billing but keeps the row', () async {
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: false,
        byUserId: kOwnerId,
      );

      final active = await menu.activeItems();
      expect(active.any((i) => i.id == kItemBiryani), isFalse);

      final row = await menu.item(kItemBiryani);
      expect(row, isNotNull, reason: 'the row survives');
      expect(row!.isActive, isFalse);
    });

    test('a disabled item can be brought back', () async {
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: false,
        byUserId: kOwnerId,
      );
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: true,
        byUserId: kOwnerId,
      );
      expect((await menu.activeItems()).any((i) => i.id == kItemBiryani),
          isTrue);
    });

    test('the admin screen can still see disabled items', () async {
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: false,
        byUserId: kOwnerId,
      );
      final visible = await menu.itemsIn(kCategoryId, includeInactive: true);
      expect(visible.any((i) => i.id == kItemBiryani), isTrue);
    });

    test('the repository exposes no way to delete an item', () {
      // A structural check. Adding a delete would orphan bill_line rows and
      // break every historical report that groups by item.
      final source =
          File('lib/data/menu_repository.dart').readAsStringSync();
      for (final forbidden in [
        'delete(_db.items)',
        'delete(_db.categories)',
        'Future<void> deleteItem',
        'Future<void> deleteCategory',
      ]) {
        expect(source.contains(forbidden), isFalse, reason: forbidden);
      }
    });

    test('setting the same state twice writes no second audit entry',
        () async {
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: false,
        byUserId: kOwnerId,
      );
      final after = await f.auditCount();
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: false,
        byUserId: kOwnerId,
      );
      expect(await f.auditCount(), after, reason: 'nothing changed');
    });
  });

  group('editing the menu cannot change a bill already written', () {
    test('a price change after a sale leaves the bill alone', () async {
      final repo = BillRepository(f.db);
      final computed = await f.compute();
      final saved = await repo.commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: kDeviceId,
        userId: kOwnerId,
      );

      await menu.updateItem(
        id: kItemBiryani,
        price: Paise.fromRupees(999),
        byUserId: kOwnerId,
      );

      final bill = await repo.loadBill(saved.id);
      expect(bill!.lines.single.unitPrice.value, 24000);
      expect(bill.bill.total.value, computed.total.value);
    });

    test('a rename, a tax change and a disable, all at once', () async {
      final repo = BillRepository(f.db);
      final computed = await f.compute();
      final saved = await repo.commitSale(
        computed: computed,
        payments: [PaymentIntent(PaymentMode.cash, computed.total)],
        deviceId: kDeviceId,
        userId: kOwnerId,
      );

      await menu.updateItem(
        id: kItemBiryani,
        nameEn: 'Renamed Entirely',
        nameTe: 'మార్చబడింది',
        price: Paise.fromRupees(500),
        taxClass: TaxClass.gst18,
        byUserId: kOwnerId,
      );
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: false,
        byUserId: kOwnerId,
      );

      final bill = await repo.loadBill(saved.id);
      final line = bill!.lines.single;
      expect(line.nameSnapshot, 'Chicken Dum Biryani');
      expect(line.nameTeSnapshot, 'చికెన్ దమ్ బిర్యానీ');
      expect(line.unitPrice.value, 24000);
      expect(line.taxRate, 500);
      expect(bill.bill.cgst.value, computed.cgst.value);
      expect(bill.bill.total.value, computed.total.value);
    });
  });

  group('searching in both scripts', () {
    test('finds by English name', () async {
      final hits = await menu.search('biryani');
      expect(hits.any((i) => i.id == kItemBiryani), isTrue);
    });

    test('is case insensitive', () async {
      expect((await menu.search('BIRYANI')).any((i) => i.id == kItemBiryani),
          isTrue);
    });

    test('finds by Telugu name', () async {
      final hits = await menu.search('బిర్యానీ');
      expect(hits.any((i) => i.id == kItemBiryani), isTrue,
          reason: 'staff may remember the Telugu name, not the English one');
    });

    test('an empty term returns everything sellable', () async {
      expect((await menu.search('   ')).length,
          (await menu.activeItems()).length);
    });

    test('a disabled item is not found', () async {
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: false,
        byUserId: kOwnerId,
      );
      expect((await menu.search('biryani')).any((i) => i.id == kItemBiryani),
          isFalse);
    });
  });

  group('browsing by category', () {
    test('a top-level category includes items in its subcategories',
        () async {
      final sub = await menu.createCategory(
        nameEn: 'Chicken',
        parentId: kCategoryId,
        byUserId: kOwnerId,
      );
      final id = await menu.createItem(
        categoryId: sub,
        nameEn: 'Chicken Fry Piece Biryani',
        price: Paise.fromRupees(270),
        taxClass: TaxClass.gst5,
        byUserId: kOwnerId,
      );

      final inParent = await menu.itemsIn(kCategoryId);
      expect(
        inParent.any((i) => i.id == id),
        isTrue,
        reason: 'otherwise picking Biryani would show nothing',
      );
    });

    test('a subcategory shows only its own', () async {
      final sub = await menu.createCategory(
        nameEn: 'Chicken',
        parentId: kCategoryId,
        byUserId: kOwnerId,
      );
      final id = await menu.createItem(
        categoryId: sub,
        nameEn: 'Chicken Fry Piece Biryani',
        price: Paise.fromRupees(270),
        taxClass: TaxClass.gst5,
        byUserId: kOwnerId,
      );

      final inSub = await menu.itemsIn(sub);
      expect(inSub.map((i) => i.id), [id]);
    });
  });

  group('the audit trail', () {
    test('a create records the new state and no before', () async {
      final id = await menu.createItem(
        categoryId: kCategoryId,
        nameEn: 'Chicken 65',
        price: Paise.fromRupees(210),
        taxClass: TaxClass.gst5,
        byUserId: kOwnerId,
      );

      final entry = await (f.db.select(f.db.auditLog)
            ..where((a) => a.entityId.equals(id)))
          .getSingle();
      expect(entry.action, AuditAction.itemCreated);
      expect(entry.before, isNull);
      final after = jsonDecode(entry.after!) as Map<String, Object?>;
      expect(after['name_en'], 'Chicken 65');
      expect(after['price_paise'], 21000);
    });

    test('an edit records both before and after', () async {
      await menu.updateItem(
        id: kItemBiryani,
        price: Paise.fromRupees(260),
        byUserId: kOwnerId,
      );

      final entry = await (f.db.select(f.db.auditLog)
            ..where((a) => a.action.equals(AuditAction.itemEdited.wireName)))
          .getSingle();
      final before = jsonDecode(entry.before!) as Map<String, Object?>;
      final after = jsonDecode(entry.after!) as Map<String, Object?>;
      expect(before['price_paise'], 24000);
      expect(after['price_paise'], 26000);
      expect(entry.userId, kOwnerId);
      expect(entry.deviceId, kDeviceId);
    });

    test('disabling and enabling are logged as distinct actions', () async {
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: false,
        byUserId: kOwnerId,
      );
      await menu.setItemActive(
        id: kItemBiryani,
        isActive: true,
        byUserId: kOwnerId,
      );

      final actions = (await f.db.select(f.db.auditLog).get())
          .map((e) => e.action)
          .toSet();
      expect(actions, contains(AuditAction.itemDisabled));
      expect(actions, contains(AuditAction.itemEnabled));
    });

    test('a category change is logged', () async {
      await menu.updateCategory(
        id: kCategoryId,
        nameEn: 'Biryanis',
        byUserId: kOwnerId,
      );
      final entry = await (f.db.select(f.db.auditLog)
            ..where(
                (a) => a.action.equals(AuditAction.categoryEdited.wireName)))
          .getSingle();
      final before = jsonDecode(entry.before!) as Map<String, Object?>;
      final after = jsonDecode(entry.after!) as Map<String, Object?>;
      expect(before['name_en'], 'Biryani');
      expect(after['name_en'], 'Biryanis');
    });

    test('menu changes fill the outbox for a later sync phase', () async {
      final before = await f.outboxCount();
      await menu.createItem(
        categoryId: kCategoryId,
        nameEn: 'Chicken 65',
        price: Paise.fromRupees(210),
        taxClass: TaxClass.gst5,
        byUserId: kOwnerId,
      );
      await menu.updateItem(
        id: kItemBiryani,
        price: Paise.fromRupees(260),
        byUserId: kOwnerId,
      );
      expect(await f.outboxCount(), before + 2);
    });
  });

  group('a failed edit leaves nothing behind', () {
    test('a rejected create writes no audit or outbox row', () async {
      final audits = await f.auditCount();
      final outbox = await f.outboxCount();

      await expectLater(
        menu.createItem(
          categoryId: kCategoryId,
          nameEn: 'Nope',
          price: Paise.fromRupees(10),
          taxClass: TaxClass.gst5,
          byUserId: kStaffId,
        ),
        throwsA(isA<MenuError>()),
      );

      expect(await f.auditCount(), audits);
      expect(await f.outboxCount(), outbox);
    });
  });
}
