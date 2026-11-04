/// Menu admin. Owner only.
///
/// Tablet: three panes, as the design canvas has it — categories, items, and
/// the editor. Phone: categories and items in one list, with the editor pushed
/// as its own screen, because three panes do not fit in 390px.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/domain.dart';
import '../../core/tax.dart';
import '../../data/db.dart';
import '../../data/menu_repository.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';
import 'item_editor.dart';

class MenuScreen extends ConsumerStatefulWidget {
  const MenuScreen({super.key});

  @override
  ConsumerState<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends ConsumerState<MenuScreen> {
  String? _categoryId;
  String? _selectedItemId;
  bool _creating = false;

  Future<void> _saveItem(ItemDraft draft) async {
    final session = ref.read(sessionProvider);
    final menu = await ref.read(menuRepositoryProvider.future);
    if (session == null || menu == null) return;

    if (_creating || _selectedItemId == null) {
      final id = await menu.createItem(
        categoryId: _categoryId!,
        nameEn: draft.nameEn,
        nameTe: draft.nameTe,
        price: draft.price,
        taxClass: draft.taxClass,
        byUserId: session.userId,
      );
      if (!draft.isActive) {
        await menu.setItemActive(
          id: id,
          isActive: false,
          byUserId: session.userId,
        );
      }
      if (mounted) {
        setState(() {
          _creating = false;
          _selectedItemId = id;
        });
      }
    } else {
      await menu.updateItem(
        id: _selectedItemId!,
        nameEn: draft.nameEn,
        nameTe: draft.nameTe,
        price: draft.price,
        taxClass: draft.taxClass,
        byUserId: session.userId,
      );
      await menu.setItemActive(
        id: _selectedItemId!,
        isActive: draft.isActive,
        byUserId: session.userId,
      );
    }

    // No invalidation: the menu providers are streams and have already
    // updated from the database.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved')),
      );
    }
  }

  Future<void> _addCategory() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;

    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NameDialog(title: 'Add category'),
    );
    if (name == null || name.trim().isEmpty) return;

    final menu = await ref.read(menuRepositoryProvider.future);
    await menu?.createCategory(nameEn: name, byUserId: session.userId);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);

    // Fails closed: a screen reached without the right role shows nothing
    // rather than an empty but editable form.
    if (session == null || !session.can(Permission.editMenu)) {
      return const _OwnerOnly();
    }

    final treeAsync = ref.watch(categoryTreeProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Menu'),
      ),
      body: treeAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load the menu.\n$e')),
        data: (tree) {
          if (tree.isEmpty) {
            return _EmptyMenu(onAddCategory: _addCategory);
          }
          _categoryId ??= tree.first.category.id;

          return isTablet(context)
              ? _tabletLayout(tree)
              : _phoneLayout(tree);
        },
      ),
    );
  }

  // --- tablet: categories | items | editor ------------------------------

  Widget _tabletLayout(List<CategoryTree> tree) {
    return Row(
      children: [
        SizedBox(
          width: 240,
          child: _CategoryPane(
            tree: tree,
            selectedId: _categoryId,
            onSelect: (id) => setState(() {
              _categoryId = id;
              _selectedItemId = null;
              _creating = false;
            }),
            onAdd: _addCategory,
          ),
        ),
        const VerticalDivider(width: 1, color: AppColors.borderSoft),
        Expanded(
          child: _ItemList(
            categoryId: _categoryId!,
            selectedId: _selectedItemId,
            onSelect: (id) => setState(() {
              _selectedItemId = id;
              _creating = false;
            }),
            onAdd: () => setState(() {
              _creating = true;
              _selectedItemId = null;
            }),
          ),
        ),
        const VerticalDivider(width: 1, color: AppColors.borderSoft),
        Container(
          width: 400,
          color: AppColors.surface,
          padding: const EdgeInsets.all(AppSpace.lg),
          child: _editorOrHint(),
        ),
      ],
    );
  }

  Widget _editorOrHint() {
    if (_creating) {
      return ItemEditor(
        key: const Key('editor-new'),
        item: null,
        title: 'Add item',
        onSave: _saveItem,
        onCancel: () => setState(() => _creating = false),
      );
    }
    if (_selectedItemId == null) {
      return const Center(
        child: Text(
          'Pick an item to edit it,\nor add a new one.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, color: AppColors.muted),
        ),
      );
    }
    return Consumer(
      builder: (context, ref, _) {
        final items = ref.watch(categoryItemsProvider(_categoryId!));
        final item = items.value?.where((i) => i.id == _selectedItemId).firstOrNull;
        if (item == null) return const SizedBox.shrink();
        return ItemEditor(
          key: Key('editor-${item.id}'),
          item: item,
          onSave: _saveItem,
        );
      },
    );
  }

  // --- phone: one list, editor on its own screen ------------------------

  Widget _phoneLayout(List<CategoryTree> tree) {
    return Column(
      children: [
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
            children: [
              for (final node in tree) ...[
                Padding(
                  padding: const EdgeInsets.only(right: AppSpace.sm),
                  child: _CategoryChip(
                    label: node.category.nameEn,
                    selected: _categoryId == node.category.id,
                    dimmed: !node.category.isActive,
                    onTap: () => setState(() {
                      _categoryId = node.category.id;
                    }),
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.only(right: AppSpace.sm),
                child: _CategoryChip(
                  label: '+ Category',
                  selected: false,
                  dimmed: false,
                  onTap: _addCategory,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: AppColors.borderSoft),
        Expanded(
          child: _ItemList(
            categoryId: _categoryId!,
            selectedId: null,
            onSelect: _openEditorPage,
            onAdd: () => _openEditorPage(null),
          ),
        ),
      ],
    );
  }

  Future<void> _openEditorPage(String? itemId) async {
    setState(() {
      _selectedItemId = itemId;
      _creating = itemId == null;
    });

    final items = await ref.read(categoryItemsProvider(_categoryId!).future);
    final item = items.where((i) => i.id == itemId).firstOrNull;
    if (!mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            title: Text(item == null ? 'Add item' : 'Edit item'),
          ),
          body: Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: ItemEditor(
              item: item,
              title: item == null ? 'Add item' : 'Edit item',
              onSave: (draft) async {
                await _saveItem(draft);
                if (context.mounted) Navigator.of(context).pop();
              },
            ),
          ),
        ),
      ),
    );
    setState(() => _creating = false);
  }
}

class _OwnerOnly extends StatelessWidget {
  const _OwnerOnly();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          title: const Text('Menu'),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpace.xxl),
            child: Text(
              'Only the owner can change the menu.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 17, color: AppColors.muted),
            ),
          ),
        ),
      );
}

class _EmptyMenu extends StatelessWidget {
  const _EmptyMenu({required this.onAddCategory});
  final VoidCallback onAddCategory;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'No categories yet.',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpace.sm),
              const Text(
                'Start with a category such as Biryani or Tiffins, '
                'then add items to it.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: AppColors.muted),
              ),
              const SizedBox(height: AppSpace.xl),
              FilledButton(
                onPressed: onAddCategory,
                style: primaryActionStyle(),
                child: const Text('Add a category'),
              ),
            ],
          ),
        ),
      );
}

class _CategoryPane extends StatelessWidget {
  const _CategoryPane({
    required this.tree,
    required this.selectedId,
    required this.onSelect,
    required this.onAdd,
  });

  final List<CategoryTree> tree;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.lg,
      ),
      child: ListView(
        children: [
          for (final node in tree) ...[
            _CategoryRow(
              name: node.category.nameEn,
              count: null,
              selected: selectedId == node.category.id,
              dimmed: !node.category.isActive,
              onTap: () => onSelect(node.category.id),
            ),
            for (final child in node.children)
              Padding(
                padding: const EdgeInsets.only(left: AppSpace.md),
                child: _CategoryRow(
                  name: child.nameEn,
                  count: null,
                  selected: selectedId == child.id,
                  dimmed: !child.isActive,
                  small: true,
                  onTap: () => onSelect(child.id),
                ),
              ),
          ],
          const SizedBox(height: AppSpace.sm),
          OutlinedButton(
            onPressed: onAdd,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 48),
              side: const BorderSide(
                color: AppColors.muted,
                style: BorderStyle.solid,
              ),
            ),
            child: const Text('Add category'),
          ),
        ],
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.name,
    required this.count,
    required this.selected,
    required this.dimmed,
    required this.onTap,
    this.small = false,
  });

  final String name;
  final int? count;
  final bool selected;
  final bool dimmed;
  final bool small;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.xs),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.small),
        child: Container(
          constraints: BoxConstraints(minHeight: small ? 44 : 52),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
          decoration: BoxDecoration(
            color: selected ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.small),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    fontSize: small ? 15 : 17,
                    fontWeight: small ? FontWeight.w600 : FontWeight.w700,
                    color: selected ? Colors.white : AppColors.ink,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (dimmed)
                Text(
                  'Hidden',
                  style: TextStyle(
                    fontSize: 13,
                    color: selected ? Colors.white70 : AppColors.muted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? AppColors.softGreen : AppColors.surface,
          foregroundColor:
              selected ? AppColors.primary : AppColors.ink,
          side: BorderSide(
            color: selected ? AppColors.primary : AppColors.border,
          ),
          minimumSize: const Size(0, AppTouch.min),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
        ),
        child: Text(
          dimmed ? '$label (hidden)' : label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      );
}

class _ItemList extends ConsumerWidget {
  const _ItemList({
    required this.categoryId,
    required this.selectedId,
    required this.onSelect,
    required this.onAdd,
  });

  final String categoryId;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsAsync = ref.watch(categoryItemsProvider(categoryId));

    return Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Items',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              FilledButton(
                key: const Key('add-item'),
                onPressed: onAdd,
                child: const Text('Add item'),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          Expanded(
            child: itemsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (items) {
                if (items.isEmpty) {
                  return const Center(
                    child: Text(
                      'Nothing here yet.',
                      style: TextStyle(fontSize: 17, color: AppColors.muted),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpace.sm),
                  itemBuilder: (context, i) => _ItemRow(
                    item: items[i],
                    selected: items[i].id == selectedId,
                    onTap: () => onSelect(items[i].id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final ItemRow item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final taxLabel = switch (item.taxClass) {
      TaxClass.gst5 => 'GST 5%',
      TaxClass.gst18 => 'GST 18%',
      TaxClass.nonGst => 'No GST',
    };

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.medium),
      child: Container(
        constraints: const BoxConstraints(minHeight: AppTouch.large),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.medium),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.borderSoft,
            width: 2,
          ),
        ),
        child: Opacity(
          // Dimmed, not hidden: the owner must be able to find a disabled item
          // to bring it back.
          opacity: item.isActive ? 1 : 0.6,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.nameEn,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.nameTe.isNotEmpty)
                      Text(
                        item.nameTe,
                        style: const TextStyle(
                          fontSize: 15,
                          color: AppColors.muted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    item.pricePaise.rupeesWhole,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    item.isActive ? taxLabel : 'Hidden from billing',
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title});
  final String title;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          key: const Key('category-name'),
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name in English'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('Add'),
          ),
        ],
      );
}
