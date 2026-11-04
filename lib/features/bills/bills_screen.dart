/// Today's bills: find one, reprint it, or cancel it.
///
/// Tablet: list and detail side by side, as the canvas has it. Phone: the list
/// fills the screen and a tap opens the detail as a sheet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_date.dart';
import '../../core/domain.dart';
import '../../data/bill_repository.dart' show FullBill;
import '../../data/bills_query.dart';
import '../../data/db.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';
import 'cancel_dialog.dart';

class BillsScreen extends ConsumerStatefulWidget {
  const BillsScreen({super.key});

  @override
  ConsumerState<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends ConsumerState<BillsScreen> {
  BillFilter _filter = BillFilter.all;
  String? _selectedId;

  Future<void> _reprint(BillRow bill) async {
    final session = ref.read(sessionProvider);
    if (session == null) return;

    final messenger = ScaffoldMessenger.of(context);

    // await the future rather than reading .value: on a freshly built screen
    // the provider has not resolved yet and .value is null, which silently
    // did nothing at all.
    final device = await ref.read(deviceProvider.future);
    if (device == null) return;

    // Logged first, then printed. The brief requires every reprint to be
    // recorded; if the printer fails the record should still exist, because
    // "someone asked for another copy" is the thing being audited.
    await ref.read(billRepositoryProvider).recordReprint(
          billId: bill.id,
          userId: session.userId,
          deviceId: device.id,
        );

    final result = await ref
        .read(printServiceProvider)
        .printBill(bill.id, duplicate: true);

    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? 'Sent to the printer, marked DUPLICATE'
              : (result.error ?? 'It did not print.'),
        ),
      ),
    );
    ref.invalidate(billHistoryProvider(bill.id));
  }

  Future<void> _cancel(BillRow bill) async {
    final cancelled = await showCancelDialog(context, ref, bill);
    if (!cancelled || !mounted) return;

    ref
      ..invalidate(billsForTodayProvider)
      ..invalidate(todaySummaryProvider)
      ..invalidate(billHistoryProvider(bill.id));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${bill.invoiceNo} cancelled')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final billsAsync = ref.watch(billsForTodayProvider);
    final summary = ref.watch(todaySummaryProvider).value;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text("Today's bills"),
      ),
      body: billsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load bills.\n$e')),
        data: (all) {
          final shown = all.where((e) => _matches(e)).toList(growable: false);

          final list = Column(
            children: [
              if (summary != null) _SummaryStrip(summary: summary),
              _FilterBar(
                current: _filter,
                cancelledCount: summary?.cancelledCount ?? 0,
                onChange: (f) => setState(() => _filter = f),
              ),
              Expanded(
                child: shown.isEmpty
                    ? _Empty(filter: _filter, anyAtAll: all.isNotEmpty)
                    : ListView.separated(
                        padding: const EdgeInsets.all(AppSpace.md),
                        itemCount: shown.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: AppSpace.sm),
                        itemBuilder: (context, i) => _BillRowTile(
                          entry: shown[i],
                          selected: shown[i].bill.id == _selectedId,
                          onTap: () => _open(shown[i]),
                        ),
                      ),
              ),
            ],
          );

          if (!isTablet(context)) return list;

          final selected = shown
              .where((e) => e.bill.id == _selectedId)
              .firstOrNull;

          return Row(
            children: [
              Expanded(child: list),
              Container(
                width: 400,
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border:
                      Border(left: BorderSide(color: AppColors.borderSoft)),
                ),
                child: selected == null
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(AppSpace.xxl),
                          child: Text(
                            'Pick a bill to see it,\nreprint it or cancel it.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 17,
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                      )
                    : BillDetail(
                        entry: selected,
                        onReprint: () => _reprint(selected.bill),
                        onCancel: () => _cancel(selected.bill),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  bool _matches(BillListEntry e) => switch (_filter) {
        BillFilter.all => true,
        BillFilter.cancelled => e.isCancelled,
        BillFilter.cash =>
          !e.isCancelled && e.paymentModes.contains(PaymentMode.cash),
        BillFilter.upi =>
          !e.isCancelled && e.paymentModes.contains(PaymentMode.upi),
        BillFilter.card =>
          !e.isCancelled && e.paymentModes.contains(PaymentMode.card),
      };

  Future<void> _open(BillListEntry entry) async {
    setState(() => _selectedId = entry.bill.id);
    if (isTablet(context)) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        maxChildSize: 0.95,
        builder: (context, controller) => Consumer(
          builder: (context, ref, _) {
            final live = ref
                .watch(billsForTodayProvider)
                .value
                ?.where((e) => e.bill.id == entry.bill.id)
                .firstOrNull;
            if (live == null) return const SizedBox.shrink();
            return BillDetail(
              entry: live,
              scrollController: controller,
              onReprint: () => _reprint(live.bill),
              onCancel: () async {
                Navigator.of(sheetContext).pop();
                await _cancel(live.bill);
              },
            );
          },
        ),
      ),
    );
  }
}

/// The day's figures. Under the bar rather than in it: at phone width an
/// AppBar action long enough to be useful overflows the title.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});
  final DaySummary summary;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.lg,
        vertical: AppSpace.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${summary.paidCount} paid'
              '${summary.cancelledCount > 0 ? ' · ${summary.cancelledCount} cancelled' : ''}',
              style: const TextStyle(fontSize: 15, color: AppColors.muted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            summary.total.rupeesWhole,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.current,
    required this.cancelledCount,
    required this.onChange,
  });

  final BillFilter current;
  final int cancelledCount;
  final ValueChanged<BillFilter> onChange;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppTouch.min + 16,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
        children: [
          for (final f in BillFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: AppSpace.sm, top: 8),
              child: OutlinedButton(
                onPressed: () => onChange(f),
                style: OutlinedButton.styleFrom(
                  backgroundColor: current == f
                      ? AppColors.softGreen
                      : AppColors.surface,
                  foregroundColor:
                      current == f ? AppColors.primary : AppColors.ink,
                  side: BorderSide(
                    color: current == f ? AppColors.primary : AppColors.border,
                  ),
                  minimumSize: const Size(0, AppTouch.min),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
                child: Text(
                  f == BillFilter.cancelled && cancelledCount > 0
                      ? '${f.label} ($cancelledCount)'
                      : f.label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.filter, required this.anyAtAll});
  final BillFilter filter;
  final bool anyAtAll;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Text(
            !anyAtAll
                ? 'No bills today yet.'
                : 'Nothing matches "${filter.label}".',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, color: AppColors.muted),
          ),
        ),
      );
}

class _BillRowTile extends StatelessWidget {
  const _BillRowTile({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final BillListEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bill = entry.bill;
    final time = TimeOfDay.fromDateTime(bill.createdAt).format(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.medium),
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
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
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      // Flexible on both: an invoice number and a time are
                      // short, but neither is guaranteed to be, and a row
                      // that overflows prints yellow stripes over the till.
                      Flexible(
                        child: Text(
                          bill.invoiceNo,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpace.sm),
                      Flexible(
                        child: Text(
                          time,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    entry.isCancelled
                        ? '${entry.summary} · Cancelled'
                        : entry.summary,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.muted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Text(
              bill.total.rupeesWhole,
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w700,
                // Struck through, not hidden: the bill is still a record.
                decoration:
                    entry.isCancelled ? TextDecoration.lineThrough : null,
                color: entry.isCancelled ? AppColors.muted : AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The detail panel: lines, totals, history, and the two actions.
class BillDetail extends ConsumerWidget {
  const BillDetail({
    super.key,
    required this.entry,
    required this.onReprint,
    required this.onCancel,
    this.scrollController,
  });

  final BillListEntry entry;
  final Future<void> Function() onReprint;
  final Future<void> Function() onCancel;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bill = entry.bill;
    final full = ref.watch(fullBillProvider(bill.id));
    final history = ref.watch(billHistoryProvider(bill.id)).value ?? const [];
    final mayCancel = canCancel(ref);

    return Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  bill.invoiceNo,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.md,
                  vertical: AppSpace.xs,
                ),
                decoration: BoxDecoration(
                  color: entry.isCancelled
                      ? AppColors.dangerBg
                      : AppColors.softGreen,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Text(
                  entry.isCancelled ? 'Cancelled' : 'Paid',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: entry.isCancelled
                        ? AppColors.dangerText
                        : AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            '${TimeOfDay.fromDateTime(bill.createdAt).format(context)}'
            ' · ${entry.summary}',
            style: const TextStyle(fontSize: 15, color: AppColors.muted),
          ),

          if (entry.isCancelled) ...[
            const SizedBox(height: AppSpace.sm),
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: AppColors.dangerBg,
                borderRadius: BorderRadius.circular(AppRadius.medium),
              ),
              child: Text(
                'Cancelled: ${bill.cancelReason ?? ''}. '
                'The bill number stays in your records.',
                style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.dangerText,
                ),
              ),
            ),
          ],

          const SizedBox(height: AppSpace.md),
          Expanded(
            child: full.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('$e'),
              data: (loaded) {
                if (loaded == null) return const SizedBox.shrink();
                return ListView(
                  controller: scrollController,
                  children: [
                    for (final l in loaded.lines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${l.qty} × ${l.nameSnapshot}',
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                  if (l.nameTeSnapshot != null &&
                                      l.nameTeSnapshot!.isNotEmpty)
                                    Text(
                                      l.nameTeSnapshot!,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        color: AppColors.muted,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Text(
                              l.lineTotal.rupees,
                              style: const TextStyle(fontSize: 16),
                            ),
                          ],
                        ),
                      ),
                    const Divider(color: AppColors.borderSoft),
                    _row('Subtotal', bill.subtotal.rupees),
                    if (bill.discount.isPositive)
                      _row('Discount', '-${bill.discount.rupees}'),
                    if (bill.cgst.isPositive)
                      _row('CGST + SGST', (bill.cgst + bill.sgst).rupees),
                    if (!bill.roundOff.isZero)
                      _row(
                        'Round off',
                        '${bill.roundOff.isNegative ? '' : '+'}'
                            '${bill.roundOff.rupees}',
                      ),
                    const SizedBox(height: AppSpace.xs),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total',
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
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

                    if (history.isNotEmpty) ...[
                      const SizedBox(height: AppSpace.lg),
                      const Text(
                        'History',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: AppSpace.xs),
                      for (final h in history)
                        Text(
                          '${TimeOfDay.fromDateTime(h.at).format(context)}'
                          '  ${_actionLabel(h.action)}',
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppColors.muted,
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),

          const SizedBox(height: AppSpace.md),
          OutlinedButton(
            key: const Key('reprint'),
            onPressed: onReprint,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, AppTouch.large),
            ),
            child: const Text('Reprint (marked DUPLICATE)'),
          ),

          // Hidden for staff rather than shown and refused.
          if (mayCancel && !entry.isCancelled) ...[
            const SizedBox(height: AppSpace.sm),
            TextButton(
              key: const Key('cancel-bill'),
              onPressed: onCancel,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.danger,
                minimumSize: const Size(0, AppTouch.comfortable),
              ),
              child: const Text('Cancel this bill'),
            ),
          ],
        ],
      ),
    );
  }

  static Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 15)),
            Text(value, style: const TextStyle(fontSize: 15)),
          ],
        ),
      );

  static String _actionLabel(AuditAction a) => switch (a) {
        AuditAction.billCreated => 'Created',
        AuditAction.billReprinted => 'Reprinted (DUPLICATE)',
        AuditAction.billCancelled => 'Cancelled',
        _ => a.wireName,
      };
}

/// The business day the bills screen shows.
///
/// Uses the outlet's own cutoff, so at 1 AM the list still shows the night
/// that is still going on rather than an empty new day.
final todayProvider = FutureProvider<BusinessDate>((ref) async {
  final outlet = await ref.watch(outletProvider.future);
  final cutoff = Duration(minutes: outlet?.businessDayCutoffMinutes ?? 240);
  return BusinessDate.of(DateTime.now(), cutoff: cutoff);
});

final billsQueryProvider = Provider<BillsQuery>(
  (ref) => BillsQuery(ref.watch(databaseProvider)),
);

final billsForTodayProvider =
    FutureProvider<List<BillListEntry>>((ref) async {
  final day = await ref.watch(todayProvider.future);
  return ref.watch(billsQueryProvider).forDay(day);
});

final todaySummaryProvider = FutureProvider<DaySummary>((ref) async {
  final day = await ref.watch(todayProvider.future);
  return ref.watch(billsQueryProvider).summaryFor(day);
});

final fullBillProvider =
    FutureProvider.family<FullBill?, String>((ref, billId) =>
        ref.watch(billRepositoryProvider).loadBill(billId));

final billHistoryProvider =
    FutureProvider.family<List<AuditRow>, String>((ref, billId) =>
        ref.watch(billsQueryProvider).historyFor(billId));
