/// Reports. Owner only.
///
/// Day, week and month, from local data. Nothing here reaches a network, and
/// every figure comes from `ReportsQuery`, which excludes cancelled bills and
/// groups by business day.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/business_date.dart';
import '../../core/domain.dart';
import '../../core/money.dart';
import '../../core/tax.dart';
import '../../core/turnover.dart';
import '../../data/reports_query.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';
import '../bills/bills_screen.dart'
    show billsForTodayProvider, todayProvider;

enum ReportPeriod {
  today('Today'),
  week('Week'),
  month('Month');

  const ReportPeriod(this.label);
  final String label;
}

final reportPeriodProvider =
    NotifierProvider<ReportPeriodNotifier, ReportPeriod>(
  ReportPeriodNotifier.new,
);

class ReportPeriodNotifier extends Notifier<ReportPeriod> {
  @override
  ReportPeriod build() => ReportPeriod.today;
  void set(ReportPeriod p) => state = p;
}

final reportsQueryProvider = Provider<ReportsQuery>(
  (ref) => ReportsQuery(ref.watch(databaseProvider)),
);

/// The range the chosen period covers, in business days.
final reportRangeProvider =
    FutureProvider<({BusinessDate from, BusinessDate to})>((ref) async {
  final today = await ref.watch(todayProvider.future);
  return switch (ref.watch(reportPeriodProvider)) {
    ReportPeriod.today => (from: today, to: today),
    // The owner's week starts on Monday, so "this week" means the week in
    // progress, not the last seven days.
    ReportPeriod.week => (from: today.weekStart, to: today),
    ReportPeriod.month => (from: today.monthStart, to: today),
  };
});

final salesReportProvider = FutureProvider<SalesReport>((ref) async {
  final range = await ref.watch(reportRangeProvider.future);
  // Depends on the bills stream, so a sale or a cancellation refreshes the
  // report without the owner having to leave the tab and come back.
  ref.watch(billsForTodayProvider);
  return ref.watch(reportsQueryProvider).forRange(range.from, range.to);
});

final turnoverWarningProvider =
    FutureProvider<TurnoverWarning?>((ref) async {
  final outlet = await ref.watch(outletProvider.future);
  final today = await ref.watch(todayProvider.future);
  if (outlet == null) return null;

  ref.watch(billsForTodayProvider);
  final fy = today.financialYear;
  final turnover = await ref.watch(reportsQueryProvider).turnoverForYear(fy);

  return turnoverWarning(
    mode: outlet.taxMode,
    turnoverThisYear: turnover,
    fy: fy,
  );
});

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (session == null || !session.can(Permission.viewReports)) {
      return const _OwnerOnly();
    }

    final period = ref.watch(reportPeriodProvider);
    final reportAsync = ref.watch(salesReportProvider);
    final warning = ref.watch(turnoverWarningProvider).value;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Reports'),
      ),
      body: reportAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not build the report.\n$e')),
        data: (report) => ListView(
          padding: const EdgeInsets.all(AppSpace.md),
          children: [
            if (warning != null) _TurnoverBanner(warning: warning),

            _PeriodPicker(
              current: period,
              onChange: ref.read(reportPeriodProvider.notifier).set,
            ),
            const SizedBox(height: AppSpace.md),

            _Kpis(report: report),
            const SizedBox(height: AppSpace.md),

            if (report.billCount == 0 && report.cancelledCount == 0)
              const _NothingYet()
            else ...[
              _Card(
                title: switch (period) {
                  ReportPeriod.today => 'Sales today',
                  ReportPeriod.week => 'Sales by day this week',
                  ReportPeriod.month => 'Sales by day this month',
                },
                child: _BarChart(points: report.byDay),
              ),
              _Card(
                title: 'How customers paid',
                child: _ModeBars(modes: report.byMode, total: report.total),
              ),
              _Card(
                title: 'Top items',
                child: _TopItems(items: report.byItem),
              ),
              if (report.byRate.isNotEmpty)
                _Card(
                  title: 'Tax summary',
                  child: _TaxSummary(report: report),
                ),
              if (report.cancelledCount > 0)
                _Card(
                  title: 'Cancelled',
                  child: _Cancelled(report: report),
                ),
              _Card(
                title: 'For your accountant',
                child: _DocCounts(report: report),
              ),
            ],

            const SizedBox(height: AppSpace.sm),
            const Text(
              'Days run to 4 AM, so a bill at 1 AM counts toward the night '
              'before. Cancelled bills are left out of every sales figure.',
              style: TextStyle(fontSize: 14, color: AppColors.muted),
            ),
            const SizedBox(height: AppSpace.xl),
          ],
        ),
      ),
    );
  }
}

class _OwnerOnly extends StatelessWidget {
  const _OwnerOnly();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          title: const Text('Reports'),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpace.xxl),
            child: Text(
              'Only the owner can see reports.',
              style: TextStyle(fontSize: 17, color: AppColors.muted),
            ),
          ),
        ),
      );
}

class _NothingYet extends StatelessWidget {
  const _NothingYet();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpace.xxl),
        child: Center(
          child: Text(
            'No sales in this period yet.',
            style: TextStyle(fontSize: 17, color: AppColors.muted),
          ),
        ),
      );
}

class _TurnoverBanner extends StatelessWidget {
  const _TurnoverBanner({required this.warning});
  final TurnoverWarning warning;

  @override
  Widget build(BuildContext context) {
    final severe = warning.level == TurnoverLevel.exceeded;
    return Container(
      key: const Key('turnover-warning'),
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: severe ? AppColors.dangerBg : AppColors.warnBg,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            warning.headline,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: severe ? AppColors.dangerText : AppColors.warnText,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            warning.detail,
            style: TextStyle(
              fontSize: 14,
              color: severe ? AppColors.dangerText : AppColors.warnText,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: warning.fraction,
              minHeight: 8,
              backgroundColor: Colors.white,
              valueColor: AlwaysStoppedAnimation(
                severe ? AppColors.danger : AppColors.warnText,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PeriodPicker extends StatelessWidget {
  const _PeriodPicker({required this.current, required this.onChange});

  final ReportPeriod current;
  final ValueChanged<ReportPeriod> onChange;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpace.xs),
        decoration: BoxDecoration(
          color: AppColors.neutral,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Row(
          children: [
            for (final p in ReportPeriod.values)
              Expanded(
                child: InkWell(
                  key: Key('period-${p.name}'),
                  onTap: () => onChange(p),
                  borderRadius: BorderRadius.circular(AppRadius.small),
                  child: Container(
                    height: AppTouch.min,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: current == p
                          ? AppColors.surface
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadius.small),
                    ),
                    child: Text(
                      p.label,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: current == p
                            ? AppColors.primary
                            : AppColors.ink,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
}

class _Kpis extends StatelessWidget {
  const _Kpis({required this.report});
  final SalesReport report;

  @override
  Widget build(BuildContext context) {
    final tiles = [
      ('Total sales', report.total.rupeesWhole),
      ('Bills', '${report.billCount}'),
      ('Average bill', report.averageBill.rupeesWhole),
      ('GST you owe', report.gstPayable.rupeesWhole),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Four across on a tablet, two on a phone. A fixed count would either
        // waste a tablet or squeeze a phone into unreadable columns.
        final columns = constraints.maxWidth >= 720 ? 4 : 2;
        final width =
            (constraints.maxWidth - (columns - 1) * AppSpace.sm) / columns;

        return Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            for (final (label, value) in tiles)
              SizedBox(
                width: width,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.md,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadius.medium),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 15,
                          color: AppColors.muted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          value,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: AppSpace.md),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpace.sm),
            child,
          ],
        ),
      );
}

class _BarChart extends StatelessWidget {
  const _BarChart({required this.points});
  final List<DayPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) return const SizedBox.shrink();

    final peak = points
        .map((p) => p.total.value)
        .fold<int>(0, (a, b) => a > b ? a : b);

    return SizedBox(
      height: 180,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final p in points)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (p.total.isPositive)
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _short(p.total),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    const SizedBox(height: 2),
                    Container(
                      height: peak == 0
                          ? 2
                          // A day with sales always draws at least a sliver,
                          // so a quiet day is visibly different from a closed
                          // one.
                          : (p.total.value / peak * 120).clamp(
                              p.total.isPositive ? 3.0 : 0.0,
                              120.0,
                            ),
                      decoration: const BoxDecoration(
                        color: AppColors.primary,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _label(p.day, points.length),
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// `₹1.2k` / `₹3.4L`. A full rupee figure under every bar is unreadable at
  /// phone width.
  static String _short(Paise p) {
    final rupees = p.value / 100;
    if (rupees >= 100000) return '₹${(rupees / 100000).toStringAsFixed(1)}L';
    if (rupees >= 1000) return '₹${(rupees / 1000).toStringAsFixed(1)}k';
    return '₹${rupees.round()}';
  }

  static String _label(BusinessDate d, int count) {
    if (count <= 1) return d.iso.substring(8);
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    if (count <= 7) {
      return names[DateTime(d.year, d.month, d.day).weekday - 1];
    }
    // A month of day names is noise; the date is what you look for.
    return d.day.toString();
  }
}

class _ModeBars extends StatelessWidget {
  const _ModeBars({required this.modes, required this.total});
  final List<ModeTotal> modes;
  final Paise total;

  @override
  Widget build(BuildContext context) {
    if (modes.isEmpty) {
      return const Text(
        'Nothing taken yet.',
        style: TextStyle(fontSize: 15, color: AppColors.muted),
      );
    }

    return Column(
      children: [
        for (final m in modes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  child: Text(
                    _label(m.mode),
                    style: const TextStyle(fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: total.value == 0
                          ? 0
                          : m.total.value / total.value,
                      minHeight: 12,
                      backgroundColor: AppColors.neutral,
                      valueColor: const AlwaysStoppedAnimation(
                        AppColors.primary,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: Text(
                    m.total.rupeesWhole,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _label(PaymentMode m) => switch (m) {
        PaymentMode.cash => 'Cash',
        PaymentMode.upi => 'UPI',
        PaymentMode.card => 'Card',
        PaymentMode.aggregator => 'Online',
        PaymentMode.credit => 'Credit',
      };
}

class _TopItems extends StatelessWidget {
  const _TopItems({required this.items});
  final List<ItemTotal> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Text(
        'Nothing sold yet.',
        style: TextStyle(fontSize: 15, color: AppColors.muted),
      );
    }

    return Column(
      children: [
        for (final i in items.take(10))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    i.name,
                    style: const TextStyle(fontSize: 15),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                Text(
                  '${i.qty} sold',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(
                  width: 92,
                  child: Text(
                    i.total.rupeesWhole,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TaxSummary extends StatelessWidget {
  const _TaxSummary({required this.report});
  final SalesReport report;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final r in report.byRate)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Taxable at ${r.label}',
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
                Text(r.taxable.rupees, style: const TextStyle(fontSize: 15)),
                SizedBox(
                  width: 110,
                  child: Text(
                    'tax ${r.tax.rupees}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (report.aggregatorTotal.isPositive) ...[
          const Divider(color: AppColors.borderSoft),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Through aggregators',
                  style: TextStyle(fontSize: 15),
                ),
              ),
              Text(
                report.aggregatorTotal.rupeesWhole,
                style: const TextStyle(fontSize: 15),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
              'The aggregator pays the GST on those, so it is not in the '
              'figure above. Confirm with your CA.',
              style: TextStyle(fontSize: 13, color: AppColors.muted),
            ),
          ),
        ],
        if (report.compositionTurnover.isPositive) ...[
          const Divider(color: AppColors.borderSoft),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Composition tax on turnover (5%)',
                  style: TextStyle(fontSize: 15),
                ),
              ),
              Text(
                report.compositionTurnover.rupees,
                style: const TextStyle(fontSize: 15),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text(
              'Not charged to customers. For your own returns.',
              style: TextStyle(fontSize: 13, color: AppColors.muted),
            ),
          ),
        ],
      ],
    );
  }
}

class _Cancelled extends StatelessWidget {
  const _Cancelled({required this.report});
  final SalesReport report;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Text(
              '${report.cancelledCount} '
              'bill${report.cancelledCount == 1 ? '' : 's'} cancelled',
              style: const TextStyle(fontSize: 15),
            ),
          ),
          Text(
            report.cancelledTotal.rupeesWhole,
            style: const TextStyle(
              fontSize: 15,
              color: AppColors.muted,
              decoration: TextDecoration.lineThrough,
            ),
          ),
        ],
      );
}

class _DocCounts extends StatelessWidget {
  const _DocCounts({required this.report});
  final SalesReport report;

  @override
  Widget build(BuildContext context) {
    final labels = {
      DocType.invoice: 'Tax invoices',
      DocType.billOfSupply: 'Bills of supply',
      DocType.creditNote: 'Credit notes',
    };

    return Column(
      children: [
        for (final entry in labels.entries)
          if ((report.docCounts[entry.key] ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.value,
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  Text(
                    '${report.docCounts[entry.key]}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
        const SizedBox(height: AppSpace.xs),
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Exporting these as CSV and Excel arrives in milestone 10.',
            style: TextStyle(fontSize: 13, color: AppColors.muted),
          ),
        ),
      ],
    );
  }
}
