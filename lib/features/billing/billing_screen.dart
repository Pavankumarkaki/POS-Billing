/// The billing screen: pick items, see the bill, take payment.
///
/// Tablet: the grid and the bill side by side, as the canvas has it, so the
/// owner sees the running total without leaving the grid. Phone: the grid
/// fills the screen with a bar across the bottom showing the total, which
/// opens the bill. Both put every control within a thumb's reach, because this
/// is used one-handed while the other hand is carrying something.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tax.dart';
import '../../data/db.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';
import 'cart.dart';
import 'payment_sheet.dart';

/// Everything sellable, for the grid.
final sellableItemsProvider = FutureProvider<List<ItemRow>>((ref) async {
  final menu = await ref.watch(menuRepositoryProvider.future);
  if (menu == null) return const [];
  return menu.activeItems();
});

/// Categories that have something sellable in them.
final sellableCategoriesProvider =
    FutureProvider<List<CategoryRow>>((ref) async {
  final menu = await ref.watch(menuRepositoryProvider.future);
  if (menu == null) return const [];
  final tree = await menu.categoryTree();
  return [for (final node in tree) node.category];
});

class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});

  @override
  ConsumerState<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends ConsumerState<BillingScreen> {
  String? _categoryId;
  String _query = '';
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// The outlet's tax configuration. Read fresh each build so a settings
  /// change takes effect on the next bill rather than the next app start.
  TaxConfig? _config() {
    final outlet = ref.watch(outletProvider).value;
    if (outlet == null) return null;
    return TaxConfig(
      mode: outlet.taxMode,
      pricesIncludeTax: outlet.pricesIncludeTax,
      sacCode: outlet.sacCode,
    );
  }

  List<ItemRow> _visible(List<ItemRow> all) {
    final q = _query.trim().toLowerCase();
    return [
      for (final i in all)
        if ((q.isEmpty ||
                i.nameEn.toLowerCase().contains(q) ||
                i.nameTe.contains(_query.trim())) &&
            (_categoryId == null || i.categoryId == _categoryId))
          i,
    ];
  }

  Future<void> _openPayment() async {
    final config = _config();
    final bill = priceCart(ref.read(cartProvider), config!);
    if (bill == null) return;
    await showPaymentSheet(context, ref, bill);
  }

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(sellableItemsProvider);
    final outlet = ref.watch(outletProvider).value;
    final config = _config();
    final cart = ref.watch(cartProvider);
    final bill = config == null ? null : priceCart(cart, config);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: Text(outlet?.name ?? 'Billing'),
        actions: [
          if (cart.isNotEmpty)
            TextButton(
              onPressed: () => ref.read(cartProvider.notifier).clear(),
              child: const Text(
                'Clear',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
        ],
      ),
      body: itemsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load the menu.\n$e')),
        data: (all) {
          if (all.isEmpty) return const _NoItems();

          final grid = _Grid(
            items: _visible(all),
            cart: cart,
            searchController: _searchController,
            query: _query,
            onQuery: (q) => setState(() => _query = q),
            categoryId: _categoryId,
            onCategory: (id) => setState(() => _categoryId = id),
            onAdd: (item) => ref.read(cartProvider.notifier).add(item),
          );

          if (isTablet(context)) {
            return Row(
              children: [
                Expanded(child: grid),
                Container(
                  width: 372,
                  decoration: const BoxDecoration(
                    color: AppColors.surface,
                    border: Border(
                      left: BorderSide(color: AppColors.borderSoft),
                    ),
                  ),
                  child: _BillPanel(
                    bill: bill,
                    onCharge: _openPayment,
                  ),
                ),
              ],
            );
          }

          return Column(
            children: [
              Expanded(child: grid),
              if (bill != null)
                _PhoneTotalBar(
                  bill: bill,
                  itemCount: cart.itemCount,
                  onOpenBill: () => _openPhoneBill(bill),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openPhoneBill(ComputedBill bill) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.sheet),
        ),
      ),
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, controller) => Consumer(
          builder: (context, ref, _) {
            final config = _config();
            final live = config == null
                ? null
                : priceCart(ref.watch(cartProvider), config);
            if (live == null) {
              // The last line was removed from inside the sheet.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Navigator.of(context).pop();
              });
              return const SizedBox.shrink();
            }
            return _BillPanel(
              bill: live,
              scrollController: controller,
              onCharge: () async {
                Navigator.of(context).pop();
                await _openPayment();
              },
            );
          },
        ),
      ),
    );
  }
}

class _NoItems extends StatelessWidget {
  const _NoItems();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Nothing to sell yet.',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: AppSpace.sm),
              Text(
                'Add items to the menu first. Open Menu from the bar below.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: AppColors.muted),
              ),
            ],
          ),
        ),
      );
}

class _Grid extends ConsumerWidget {
  const _Grid({
    required this.items,
    required this.cart,
    required this.searchController,
    required this.query,
    required this.onQuery,
    required this.categoryId,
    required this.onCategory,
    required this.onAdd,
  });

  final List<ItemRow> items;
  final CartState cart;
  final TextEditingController searchController;
  final String query;
  final ValueChanged<String> onQuery;
  final String? categoryId;
  final ValueChanged<String?> onCategory;
  final ValueChanged<ItemRow> onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(sellableCategoriesProvider).value ?? const [];
    final wide = isTablet(context);

    return Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        children: [
          TextField(
            key: const Key('item-search'),
            controller: searchController,
            onChanged: onQuery,
            style: const TextStyle(fontSize: 18),
            decoration: InputDecoration(
              hintText: 'Search items',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear search',
                      onPressed: () {
                        searchController.clear();
                        onQuery('');
                      },
                    ),
            ),
          ),
          const SizedBox(height: AppSpace.sm),

          SizedBox(
            height: AppTouch.min + 8,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _Chip(
                  label: 'All',
                  selected: categoryId == null,
                  onTap: () => onCategory(null),
                ),
                for (final c in categories)
                  _Chip(
                    label: c.nameEn,
                    selected: categoryId == c.id,
                    onTap: () => onCategory(c.id),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.sm),

          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      'Nothing matches.',
                      style: TextStyle(fontSize: 17, color: AppColors.muted),
                    ),
                  )
                : GridView.builder(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      // Tiles stay a usable size instead of stretching: on a
                      // tablet that means more columns, not bigger buttons.
                      maxCrossAxisExtent: wide ? 220 : 190,
                      mainAxisExtent: 96,
                      crossAxisSpacing: AppSpace.sm,
                      mainAxisSpacing: AppSpace.sm,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, i) => _ItemTile(
                      item: items[i],
                      qty: cart.qtyOf(items[i].id),
                      onTap: () => onAdd(items[i]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: AppSpace.sm),
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            backgroundColor:
                selected ? AppColors.softGreen : AppColors.surface,
            foregroundColor: selected ? AppColors.primary : AppColors.ink,
            side: BorderSide(
              color: selected ? AppColors.primary : AppColors.border,
            ),
            minimumSize: const Size(0, AppTouch.min),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      );
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({
    required this.item,
    required this.qty,
    required this.onTap,
  });

  final ItemRow item;
  final int qty;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${item.nameEn}, ${item.pricePaise.rupeesWhole}'
          '${qty > 0 ? ', $qty on the bill' : ''}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.medium),
        child: Container(
          padding: const EdgeInsets.all(AppSpace.sm + 2),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.medium),
            border: Border.all(
              color: qty > 0 ? AppColors.primary : AppColors.borderSoft,
              width: 2,
            ),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      item.nameEn,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    item.pricePaise.rupeesWhole,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              if (qty > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 28),
                    height: 28,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '$qty',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The running bill: order type, lines, discount, totals, and Charge.
class _BillPanel extends ConsumerWidget {
  const _BillPanel({
    required this.bill,
    required this.onCharge,
    this.scrollController,
  });

  final ComputedBill? bill;
  final Future<void> Function() onCharge;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartProvider);
    final notifier = ref.read(cartProvider.notifier);

    return Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'This bill',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Text(
                '${cart.itemCount} item${cart.itemCount == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 15, color: AppColors.muted),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),

          _OrderTypePicker(
            current: cart.orderType,
            onChange: notifier.setOrderType,
          ),
          const SizedBox(height: AppSpace.sm),

          Expanded(
            child: bill == null
                ? const Center(
                    child: Text(
                      'No items yet.\nTap something to start.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 17, color: AppColors.muted),
                    ),
                  )
                : ListView.separated(
                    controller: scrollController,
                    itemCount: cart.entries.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpace.xs),
                    itemBuilder: (context, i) {
                      final e = cart.entries[i];
                      return _CartRow(
                        entry: e,
                        onIncrement: () => notifier.increment(e.itemId),
                        onDecrement: () => notifier.decrement(e.itemId),
                      );
                    },
                  ),
          ),

          if (bill != null) ...[
            const Divider(color: AppColors.borderSoft),
            _Totals(bill: bill!),
            const SizedBox(height: AppSpace.sm),
            FilledButton(
              key: const Key('charge'),
              onPressed: onCharge,
              style: primaryActionStyle(),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Charge'),
                  Text(bill!.total.rupeesWhole),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OrderTypePicker extends StatelessWidget {
  const _OrderTypePicker({required this.current, required this.onChange});

  final OrderType current;
  final ValueChanged<OrderType> onChange;

  @override
  Widget build(BuildContext context) {
    const labels = {
      OrderType.dine: 'Dine in',
      OrderType.takeaway: 'Takeaway',
      OrderType.aggregator: 'Online',
    };

    return Container(
      padding: const EdgeInsets.all(AppSpace.xs),
      decoration: BoxDecoration(
        color: AppColors.neutralAlt,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: Row(
        children: [
          for (final t in OrderType.values)
            Expanded(
              child: InkWell(
                onTap: () => onChange(t),
                borderRadius: BorderRadius.circular(AppRadius.small),
                child: Container(
                  height: AppTouch.min,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: current == t
                        ? AppColors.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.small),
                  ),
                  child: Text(
                    labels[t]!,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: current == t ? AppColors.primary : AppColors.ink,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CartRow extends StatelessWidget {
  const _CartRow({
    required this.entry,
    required this.onIncrement,
    required this.onDecrement,
  });

  final CartEntry entry;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.nameEn,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                '${entry.qty} × ${entry.unitPrice.rupeesWhole}',
                style: const TextStyle(fontSize: 14, color: AppColors.muted),
              ),
            ],
          ),
        ),
        _QtyButton(
          icon: Icons.remove,
          semantic: 'Remove one ${entry.nameEn}',
          onTap: onDecrement,
          leading: true,
        ),
        _QtyButton(
          icon: Icons.add,
          semantic: 'Add one ${entry.nameEn}',
          onTap: onIncrement,
          leading: false,
        ),
        SizedBox(
          width: 76,
          child: Text(
            entry.gross.rupeesWhole,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _QtyButton extends StatelessWidget {
  const _QtyButton({
    required this.icon,
    required this.semantic,
    required this.onTap,
    required this.leading,
  });

  final IconData icon;
  final String semantic;
  final VoidCallback onTap;
  final bool leading;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semantic,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: AppTouch.min,
          height: AppTouch.min,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: leading ? AppColors.surface : AppColors.primary,
            border: Border.all(
              color: leading ? AppColors.border : AppColors.primary,
            ),
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(leading ? AppRadius.small : 0),
              right: Radius.circular(leading ? 0 : AppRadius.small),
            ),
          ),
          child: Icon(
            icon,
            size: 20,
            color: leading ? AppColors.ink : Colors.white,
          ),
        ),
      ),
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.bill});
  final ComputedBill bill;

  @override
  Widget build(BuildContext context) {
    Widget line(String label, String value, {bool muted = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  color: muted ? AppColors.muted : AppColors.ink,
                ),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: 15,
                  color: muted ? AppColors.muted : AppColors.ink,
                ),
              ),
            ],
          ),
        );

    return Column(
      children: [
        line('Subtotal', bill.subtotal.rupees),
        if (bill.discount.isPositive)
          line('Discount', '-${bill.discount.rupees}', muted: true),
        // One block per rate, so a 5% and an 18% line can share a bill.
        for (final b in bill.rateBlocks) ...[
          line('CGST ${b.halfRateLabel}%', b.cgst.rupees, muted: true),
          line('SGST ${b.halfRateLabel}%', b.sgst.rupees, muted: true),
        ],
        if (!bill.roundOff.isZero)
          line(
            'Round off',
            '${bill.roundOff.isNegative ? '' : '+'}${bill.roundOff.rupees}',
            muted: true,
          ),
        const SizedBox(height: AppSpace.xs),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Total',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            Text(
              bill.total.rupeesWhole,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// The phone's bottom bar: the total, and a way into the bill.
class _PhoneTotalBar extends StatelessWidget {
  const _PhoneTotalBar({
    required this.bill,
    required this.itemCount,
    required this.onOpenBill,
  });

  final ComputedBill bill;
  final int itemCount;
  final VoidCallback onOpenBill;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.md),
          child: FilledButton(
            key: const Key('open-bill'),
            onPressed: onOpenBill,
            style: primaryActionStyle(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('$itemCount item${itemCount == 1 ? '' : 's'}'),
                Text('See bill · ${bill.total.rupeesWhole}'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
