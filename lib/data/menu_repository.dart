/// The menu: categories, subcategories and items.
///
/// Two rules shape this file:
///
/// 1. **Nothing is ever deleted.** An item that has been sold is referenced by
///    `bill_line.item_id`, and reports group by it. Deleting one would orphan
///    those rows. So items and categories are deactivated instead, which hides
///    them from billing while leaving history intact.
///
/// 2. **Editing an item cannot change a past bill.** That is already
///    guaranteed by `bill_line` holding its own snapshot of name, price and
///    tax rate, so nothing here has to be careful about it. The tests assert it
///    anyway, because it is the kind of guarantee that quietly stops being true.
///
/// Everything is owner-only, and every change is audited with before and after.
library;

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../core/domain.dart';
import '../core/money.dart';
import '../core/tax.dart';
import 'db.dart';

class MenuError implements Exception {
  MenuError(this.message);
  final String message;
  @override
  String toString() => 'MenuError: $message';
}

/// A category with its subcategories, for the navigation pane.
class CategoryTree {
  const CategoryTree({required this.category, required this.children});

  final CategoryRow category;
  final List<CategoryRow> children;
}

class MenuRepository {
  MenuRepository(
    this._db, {
    required this.deviceId,
    Uuid? uuid,
    DateTime Function()? clock,
  })  : _uuid = uuid ?? const Uuid(),
        _clock = clock ?? DateTime.now;

  final PosDatabase _db;

  /// Recorded on every audit entry.
  final String deviceId;

  final Uuid _uuid;
  final DateTime Function() _clock;

  // --- reads ------------------------------------------------------------

  /// Top-level categories with their subcategories, in sort order.
  ///
  /// [includeInactive] is for the menu admin screen, which must show disabled
  /// entries so they can be re-enabled. The billing grid never passes it.
  Future<List<CategoryTree>> categoryTree({
    bool includeInactive = false,
  }) async {
    final query = _db.select(_db.categories)
      ..orderBy([
        (c) => OrderingTerm.asc(c.sort),
        (c) => OrderingTerm.asc(c.nameEn),
      ]);
    if (!includeInactive) {
      query.where((c) => c.isActive.equals(true));
    }
    final all = await query.get();

    final parents = all.where((c) => c.parentId == null).toList();
    return [
      for (final parent in parents)
        CategoryTree(
          category: parent,
          children:
              all.where((c) => c.parentId == parent.id).toList(growable: false),
        ),
    ];
  }

  /// Items in a category, or in a subcategory when [categoryId] names one.
  Future<List<ItemRow>> itemsIn(
    String categoryId, {
    bool includeInactive = false,
  }) async {
    // A top-level category shows everything beneath it, including items filed
    // under its subcategories. Otherwise picking "Biryani" would show nothing
    // when every biryani is filed under "Chicken" or "Mutton".
    final children = await (_db.select(_db.categories)
          ..where((c) => c.parentId.equals(categoryId)))
        .get();
    final ids = [categoryId, ...children.map((c) => c.id)];

    final query = _db.select(_db.items)
      ..where((i) => i.categoryId.isIn(ids))
      ..orderBy([
        (i) => OrderingTerm.asc(i.sort),
        (i) => OrderingTerm.asc(i.nameEn),
      ]);
    if (!includeInactive) {
      query.where((i) => i.isActive.equals(true));
    }
    return query.get();
  }

  /// Everything sellable, for the billing grid and for search.
  Future<List<ItemRow>> activeItems() => (_db.select(_db.items)
        ..where((i) => i.isActive.equals(true))
        ..orderBy([
          (i) => OrderingTerm.asc(i.sort),
          (i) => OrderingTerm.asc(i.nameEn),
        ]))
      .get();

  /// Items matching [term] in either language.
  ///
  /// Searching both scripts matters: the owner may type "biryani" while the
  /// menu entry a staff member remembers is "బిర్యానీ".
  Future<List<ItemRow>> search(String term) async {
    final q = term.trim();
    if (q.isEmpty) return activeItems();
    final like = '%${q.toLowerCase()}%';
    return (_db.select(_db.items)
          ..where((i) =>
              i.isActive.equals(true) &
              (i.nameEn.lower().like(like) | i.nameTe.like('%$q%')))
          ..orderBy([(i) => OrderingTerm.asc(i.nameEn)]))
        .get();
  }

  Future<ItemRow?> item(String id) =>
      (_db.select(_db.items)..where((i) => i.id.equals(id)))
          .getSingleOrNull();

  // --- categories -------------------------------------------------------

  Future<String> createCategory({
    required String nameEn,
    required String byUserId,
    String nameTe = '',
    String? parentId,
    int? sort,
    DateTime? at,
  }) async {
    final now = at ?? _clock();
    if (nameEn.trim().isEmpty) {
      throw MenuError('A category needs an English name.');
    }

    return _db.transaction(() async {
      await _requireOwner(byUserId);

      if (parentId != null) {
        final parent = await (_db.select(_db.categories)
              ..where((c) => c.id.equals(parentId)))
            .getSingleOrNull();
        if (parent == null) throw MenuError('No such category.');
        // One level of nesting, as the brief specifies: a category or a
        // subcategory, nothing deeper.
        if (parent.parentId != null) {
          throw MenuError(
            'A subcategory cannot sit inside another subcategory.',
          );
        }
      }

      final id = _uuid.v7();
      await _db.into(_db.categories).insert(CategoriesCompanion.insert(
            id: id,
            parentId: Value(parentId),
            nameEn: nameEn.trim(),
            nameTe: Value(nameTe.trim()),
            sort: Value(sort ?? await _nextCategorySort(parentId)),
          ));

      await _audit(
        action: AuditAction.categoryCreated,
        entity: AuditEntity.category,
        entityId: id,
        userId: byUserId,
        at: now,
        after: {
          'name_en': nameEn.trim(),
          'name_te': nameTe.trim(),
          'parent_id': parentId,
        },
      );
      return id;
    });
  }

  Future<void> updateCategory({
    required String id,
    required String byUserId,
    String? nameEn,
    String? nameTe,
    int? sort,
    bool? isActive,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    await _db.transaction(() async {
      await _requireOwner(byUserId);

      final before = await (_db.select(_db.categories)
            ..where((c) => c.id.equals(id)))
          .getSingleOrNull();
      if (before == null) throw MenuError('No such category.');

      if (nameEn != null && nameEn.trim().isEmpty) {
        throw MenuError('A category needs an English name.');
      }

      await (_db.update(_db.categories)..where((c) => c.id.equals(id)))
          .write(CategoriesCompanion(
        nameEn: nameEn == null ? const Value.absent() : Value(nameEn.trim()),
        nameTe: nameTe == null ? const Value.absent() : Value(nameTe.trim()),
        sort: sort == null ? const Value.absent() : Value(sort),
        isActive:
            isActive == null ? const Value.absent() : Value(isActive),
      ));

      // Hiding a category must hide what is in it, or the billing grid would
      // show items under a category that is no longer there.
      if (isActive == false) {
        await (_db.update(_db.items)
              ..where((i) => i.categoryId.equals(id)))
            .write(const ItemsCompanion(isActive: Value(false)));
        await (_db.update(_db.categories)
              ..where((c) => c.parentId.equals(id)))
            .write(const CategoriesCompanion(isActive: Value(false)));
      }

      final after = await (_db.select(_db.categories)
            ..where((c) => c.id.equals(id)))
          .getSingle();

      await _audit(
        action: AuditAction.categoryEdited,
        entity: AuditEntity.category,
        entityId: id,
        userId: byUserId,
        at: now,
        before: _categoryJson(before),
        after: _categoryJson(after),
      );
    });
  }

  // --- items ------------------------------------------------------------

  Future<String> createItem({
    required String categoryId,
    required String nameEn,
    required Paise price,
    required TaxClass taxClass,
    required String byUserId,
    String nameTe = '',
    int? sort,
    DateTime? at,
  }) async {
    final now = at ?? _clock();
    _validateItem(nameEn: nameEn, price: price);

    return _db.transaction(() async {
      await _requireOwner(byUserId);

      final category = await (_db.select(_db.categories)
            ..where((c) => c.id.equals(categoryId)))
          .getSingleOrNull();
      if (category == null) throw MenuError('No such category.');

      final id = _uuid.v7();
      await _db.into(_db.items).insert(ItemsCompanion.insert(
            id: id,
            categoryId: categoryId,
            nameEn: nameEn.trim(),
            nameTe: Value(nameTe.trim()),
            pricePaise: price,
            taxClass: taxClass,
            sort: Value(sort ?? await _nextItemSort(categoryId)),
            updatedAt: now,
          ));

      await _audit(
        action: AuditAction.itemCreated,
        entity: AuditEntity.item,
        entityId: id,
        userId: byUserId,
        at: now,
        after: {
          'name_en': nameEn.trim(),
          'name_te': nameTe.trim(),
          'price_paise': price.value,
          'tax_class': taxClass.wireName,
          'category_id': categoryId,
        },
      );
      await _outbox(AuditEntity.item, 'item_created', id, now);
      return id;
    });
  }

  /// Edits an item. Only the fields given change.
  ///
  /// A price or tax change applies to NEW bills only. Bills already written
  /// keep what they were sold at, because each line holds its own snapshot.
  Future<void> updateItem({
    required String id,
    required String byUserId,
    String? nameEn,
    String? nameTe,
    Paise? price,
    TaxClass? taxClass,
    String? categoryId,
    int? sort,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    await _db.transaction(() async {
      await _requireOwner(byUserId);

      final before = await (_db.select(_db.items)..where((i) => i.id.equals(id)))
          .getSingleOrNull();
      if (before == null) throw MenuError('No such item.');

      _validateItem(
        nameEn: nameEn ?? before.nameEn,
        price: price ?? before.pricePaise,
      );

      if (categoryId != null) {
        final category = await (_db.select(_db.categories)
              ..where((c) => c.id.equals(categoryId)))
            .getSingleOrNull();
        if (category == null) throw MenuError('No such category.');
      }

      await (_db.update(_db.items)..where((i) => i.id.equals(id)))
          .write(ItemsCompanion(
        nameEn: nameEn == null ? const Value.absent() : Value(nameEn.trim()),
        nameTe: nameTe == null ? const Value.absent() : Value(nameTe.trim()),
        pricePaise: price == null ? const Value.absent() : Value(price),
        taxClass: taxClass == null ? const Value.absent() : Value(taxClass),
        categoryId:
            categoryId == null ? const Value.absent() : Value(categoryId),
        sort: sort == null ? const Value.absent() : Value(sort),
        updatedAt: Value(now),
      ));

      final after =
          await (_db.select(_db.items)..where((i) => i.id.equals(id)))
              .getSingle();

      await _audit(
        action: AuditAction.itemEdited,
        entity: AuditEntity.item,
        entityId: id,
        userId: byUserId,
        at: now,
        before: _itemJson(before),
        after: _itemJson(after),
      );
      await _outbox(AuditEntity.item, 'item_edited', id, now);
    });
  }

  /// Hides an item from billing, or brings it back.
  ///
  /// This is what "delete" means in this app. Nothing removes the row.
  Future<void> setItemActive({
    required String id,
    required bool isActive,
    required String byUserId,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    await _db.transaction(() async {
      await _requireOwner(byUserId);

      final before = await (_db.select(_db.items)..where((i) => i.id.equals(id)))
          .getSingleOrNull();
      if (before == null) throw MenuError('No such item.');
      if (before.isActive == isActive) return;

      await (_db.update(_db.items)..where((i) => i.id.equals(id)))
          .write(ItemsCompanion(
        isActive: Value(isActive),
        updatedAt: Value(now),
      ));

      await _audit(
        action: isActive ? AuditAction.itemEnabled : AuditAction.itemDisabled,
        entity: AuditEntity.item,
        entityId: id,
        userId: byUserId,
        at: now,
        before: {'is_active': before.isActive},
        after: {'is_active': isActive, 'name_en': before.nameEn},
      );
      await _outbox(
        AuditEntity.item,
        isActive ? 'item_enabled' : 'item_disabled',
        id,
        now,
      );
    });
  }

  /// Reorders items within a category. [orderedIds] is the new order.
  Future<void> reorderItems({
    required List<String> orderedIds,
    required String byUserId,
    DateTime? at,
  }) async {
    final now = at ?? _clock();

    await _db.transaction(() async {
      await _requireOwner(byUserId);
      for (var i = 0; i < orderedIds.length; i++) {
        await (_db.update(_db.items)
              ..where((it) => it.id.equals(orderedIds[i])))
            .write(ItemsCompanion(sort: Value(i), updatedAt: Value(now)));
      }
      await _audit(
        action: AuditAction.itemEdited,
        entity: AuditEntity.item,
        entityId: orderedIds.isEmpty ? '' : orderedIds.first,
        userId: byUserId,
        at: now,
        after: {'reordered': orderedIds},
      );
    });
  }

  // --- helpers ----------------------------------------------------------

  void _validateItem({required String nameEn, required Paise price}) {
    if (nameEn.trim().isEmpty) {
      throw MenuError('An item needs an English name.');
    }
    if (price.isNegative) {
      throw MenuError('A price cannot be negative.');
    }
  }

  Future<void> _requireOwner(String userId) async {
    final user =
        await (_db.select(_db.users)..where((u) => u.id.equals(userId)))
            .getSingleOrNull();
    if (user == null) throw MenuError('Unknown user.');
    if (!user.isActive) throw MenuError('That user is no longer active.');
    if (!Permission.editMenu.allows(user.role)) {
      throw MenuError('Only the owner can change the menu.');
    }
  }

  Future<int> _nextItemSort(String categoryId) async {
    final rows = await (_db.select(_db.items)
          ..where((i) => i.categoryId.equals(categoryId)))
        .get();
    if (rows.isEmpty) return 0;
    return rows.map((r) => r.sort).reduce((a, b) => a > b ? a : b) + 1;
  }

  Future<int> _nextCategorySort(String? parentId) async {
    final query = _db.select(_db.categories);
    if (parentId == null) {
      query.where((c) => c.parentId.isNull());
    } else {
      query.where((c) => c.parentId.equals(parentId));
    }
    final rows = await query.get();
    if (rows.isEmpty) return 0;
    return rows.map((r) => r.sort).reduce((a, b) => a > b ? a : b) + 1;
  }

  Map<String, Object?> _itemJson(ItemRow i) => {
        'name_en': i.nameEn,
        'name_te': i.nameTe,
        'price_paise': i.pricePaise.value,
        'tax_class': i.taxClass.wireName,
        'category_id': i.categoryId,
        'is_active': i.isActive,
        'sort': i.sort,
      };

  Map<String, Object?> _categoryJson(CategoryRow c) => {
        'name_en': c.nameEn,
        'name_te': c.nameTe,
        'parent_id': c.parentId,
        'is_active': c.isActive,
        'sort': c.sort,
      };

  Future<void> _audit({
    required AuditAction action,
    required AuditEntity entity,
    required String entityId,
    required String userId,
    required DateTime at,
    Map<String, Object?>? before,
    Map<String, Object?>? after,
  }) =>
      _db.into(_db.auditLog).insert(AuditLogCompanion.insert(
            id: _uuid.v7(),
            at: at,
            userId: Value(userId),
            deviceId: deviceId,
            action: action,
            entity: entity,
            entityId: entityId,
            before: Value(before == null ? null : jsonEncode(before)),
            after: Value(after == null ? null : jsonEncode(after)),
          ));

  Future<void> _outbox(
    AuditEntity entity,
    String op,
    String id,
    DateTime at,
  ) =>
      _db.into(_db.outbox).insert(OutboxCompanion.insert(
            opId: _uuid.v7(),
            entity: entity,
            payload: jsonEncode({'op': op, 'id': id}),
            createdAt: at,
          ));
}
