/// Taking payment, and committing the sale.
///
/// Supports a split: several tenders against one bill. The Charge button stays
/// disabled until they add up exactly, because `commitSale` refuses anything
/// else and a till that lets you confirm an unbalanced bill is worse than one
/// that does not.
///
/// The save happens here. Printing does not: the brief requires the bill to be
/// saved first, so a printer failure can never lose it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/domain.dart';
import '../../core/money.dart';
import '../../core/tax.dart';
import '../../data/bill_repository.dart';
import '../../printing/printer.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';
import 'cart.dart';

Future<void> showPaymentSheet(
  BuildContext context,
  WidgetRef ref,
  ComputedBill bill,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(AppRadius.sheet),
      ),
    ),
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      builder: (context, controller) =>
          PaymentSheet(bill: bill, scrollController: controller),
    ),
  );
}

class PaymentSheet extends ConsumerStatefulWidget {
  const PaymentSheet({super.key, required this.bill, this.scrollController});

  final ComputedBill bill;
  final ScrollController? scrollController;

  @override
  ConsumerState<PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<PaymentSheet> {
  /// Tenders taken so far. A single-mode payment is just one entry.
  final List<PaymentIntent> _taken = [];

  PaymentMode _mode = PaymentMode.cash;
  final _amountController = TextEditingController();

  bool _busy = false;
  String? _error;
  SavedBill? _saved;

  /// The result of the print attempt that follows the save. Null while it is
  /// still running.
  PrintResult? _print;
  bool _printing = false;

  Paise get _total => widget.bill.total;

  Paise get _paid => _taken.fold(Paise.zero, (Paise s, p) => s + p.amount);

  Paise get _due => _total - _paid;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  void _addTender(Paise amount) {
    if (amount.isZero || amount.isNegative) return;
    // Never take more than is owed: the excess is change, not a payment, and
    // recording it would make the bill total disagree with its payments.
    final capped = amount > _due ? _due : amount;
    setState(() {
      _taken.add(PaymentIntent(_mode, capped));
      _amountController.clear();
      _error = null;
    });
  }

  void _addRemainder() => _addTender(_due);

  void _undoLast() {
    if (_taken.isEmpty) return;
    setState(() {
      _taken.removeLast();
      _error = null;
    });
  }

  Future<void> _confirm() async {
    if (_busy || _due.value != 0) return;

    final session = ref.read(sessionProvider);
    final device = ref.read(deviceProvider).value;
    if (session == null || device == null) {
      setState(() => _error = 'Not signed in.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final saved = await ref
          .read(billRepositoryProvider)
          .commitSale(
            computed: widget.bill,
            payments: List.of(_taken),
            deviceId: device.id,
            userId: session.userId,
          );

      // Saved. Only now is the cart safe to clear.
      ref.read(cartProvider.notifier).clear();
      if (mounted) {
        setState(() {
          _busy = false;
          _saved = saved;
        });
      }

      // Printing happens AFTER the commit, in its own step, and its result is
      // reported separately. The bill exists whatever happens next.
      await _attemptPrint(saved.id);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is SaleError ? e.message : '$e';
        });
      }
    }
  }

  /// Tries to print a bill that is already saved.
  ///
  /// Never throws and never touches the bill. The brief: a printer failure
  /// must not lose a bill, change its number, or block the next sale.
  Future<void> _attemptPrint(String billId) async {
    if (mounted) setState(() => _printing = true);

    final result = await ref.read(printServiceProvider).printBill(billId);

    if (mounted) {
      setState(() {
        _printing = false;
        _print = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_saved != null) {
      return _Saved(
        saved: _saved!,
        print: _print,
        printing: _printing,
        onRetry: () => _attemptPrint(_saved!.id),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: AppSpace.lg,
        right: AppSpace.lg,
        top: AppSpace.lg,
        // Lifts the sheet above the keyboard when the amount field is focused.
        bottom: AppSpace.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ListView(
        controller: widget.scrollController,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Collect payment',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'Back to bill',
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),

          _AmountRow(label: 'Total', amount: _total, strong: true),
          if (_taken.isNotEmpty) ...[
            _AmountRow(label: 'Received', amount: _paid),
            _AmountRow(
              label: _due.isZero ? 'Settled' : 'Still due',
              amount: _due,
              highlight: !_due.isZero,
            ),
          ],
          const SizedBox(height: AppSpace.md),

          if (_taken.isNotEmpty) ...[
            for (final t in _taken)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _modeLabel(t.mode),
                      style: const TextStyle(fontSize: 15),
                    ),
                    Text(t.amount.rupees, style: const TextStyle(fontSize: 15)),
                  ],
                ),
              ),
            TextButton(
              onPressed: _busy ? null : _undoLast,
              child: const Text('Undo last'),
            ),
            const SizedBox(height: AppSpace.sm),
          ],

          const Text(
            'How are they paying?',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpace.xs),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              for (final m in PaymentMode.values)
                _ModeChip(
                  mode: m,
                  selected: _mode == m,
                  onTap: () => setState(() => _mode = m),
                ),
            ],
          ),
          const SizedBox(height: AppSpace.md),

          if (!_due.isZero) ...[
            FilledButton(
              key: const Key('pay-full'),
              onPressed: _busy ? null : _addRemainder,
              child: Text(
                _taken.isEmpty
                    ? 'Full amount · ${_due.rupeesWhole}'
                    : 'Rest of it · ${_due.rupeesWhole}',
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('part-amount'),
                    controller: _amountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Part amount (₹)',
                    ),
                    style: const TextStyle(fontSize: 18),
                  ),
                ),
                const SizedBox(width: AppSpace.sm),
                OutlinedButton(
                  key: const Key('add-part'),
                  onPressed: _busy
                      ? null
                      : () {
                          final amount = Paise.tryParse(_amountController.text);
                          if (amount == null) {
                            setState(() => _error = 'Enter an amount.');
                            return;
                          }
                          _addTender(amount);
                        },
                  child: const Text('Add part'),
                ),
              ],
            ),
          ],

          if (_error != null) ...[
            const SizedBox(height: AppSpace.md),
            Container(
              padding: const EdgeInsets.all(AppSpace.md),
              decoration: BoxDecoration(
                color: AppColors.dangerBg,
                borderRadius: BorderRadius.circular(AppRadius.medium),
              ),
              child: Text(
                _error!,
                style: const TextStyle(
                  color: AppColors.dangerText,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],

          const SizedBox(height: AppSpace.lg),
          FilledButton(
            key: const Key('confirm-sale'),
            // Disabled until the tenders balance exactly. commitSale refuses
            // anything else, so enabling it would only produce an error.
            onPressed: (_due.isZero && !_busy) ? _confirm : null,
            style: primaryActionStyle(),
            child: _busy
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _due.isZero
                        ? 'Save bill · ${_total.rupeesWhole}'
                        : '${_due.rupeesWhole} still to collect',
                  ),
          ),
        ],
      ),
    );
  }

  static String _modeLabel(PaymentMode m) => switch (m) {
    PaymentMode.cash => 'Cash',
    PaymentMode.upi => 'UPI',
    PaymentMode.card => 'Card',
    PaymentMode.aggregator => 'Aggregator',
    PaymentMode.credit => 'Credit',
  };
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final PaymentMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      backgroundColor: selected ? AppColors.primary : AppColors.surface,
      foregroundColor: selected ? Colors.white : AppColors.ink,
      side: BorderSide(color: selected ? AppColors.primary : AppColors.border),
      minimumSize: const Size(96, AppTouch.comfortable),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
    ),
    child: Text(
      _PaymentSheetState._modeLabel(mode),
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  );
}

class _AmountRow extends StatelessWidget {
  const _AmountRow({
    required this.label,
    required this.amount,
    this.strong = false,
    this.highlight = false,
  });

  final String label;
  final Paise amount;
  final bool strong;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: strong ? 22 : 17,
      fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
      color: highlight ? AppColors.dangerText : AppColors.ink,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(amount.rupees, style: style),
        ],
      ),
    );
  }
}

/// Shown once the bill is written. Printing comes in milestone 7; until then
/// this is where the invoice number appears.
class _Saved extends StatelessWidget {
  const _Saved({
    required this.saved,
    required this.print,
    required this.printing,
    required this.onRetry,
  });

  final SavedBill saved;
  final PrintResult? print;
  final bool printing;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = print != null && !print!.ok;

    // SizedBox, because the sheet lays its child out with a LOOSE width and a
    // Column with mainAxisSize.min then takes the width of its widest child.
    // On a 411pt phone that made this panel 204pt wide: a narrow white column
    // down the middle with the billing grid showing either side of it. The
    // payment step above never showed it because a ListView always expands.
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                // Green even when the print failed: the bill IS saved, and that
                // is the thing that matters. The printer gets its own line.
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, color: Colors.white, size: 34),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              'Bill saved',
              style: Theme.of(context).textTheme.displayMedium,
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              saved.invoiceNo.formatted,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              saved.computed.total.rupees,
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: AppSpace.lg),

            if (printing)
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: AppSpace.sm),
                  Text('Printing...', style: TextStyle(fontSize: 15)),
                ],
              )
            else if (failed)
              Container(
                key: const Key('print-failed'),
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: AppColors.dangerBg,
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                ),
                child: Column(
                  children: [
                    Text(
                      print!.error ?? 'The receipt did not print.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.dangerText,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    const Text(
                      'The bill is saved and keeps this number. You can try '
                      'again, or carry on and reprint it later from Bills.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.dangerText,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    OutlinedButton(
                      key: const Key('retry-print'),
                      onPressed: onRetry,
                      child: const Text('Try printing again'),
                    ),
                  ],
                ),
              )
            else if (print != null)
              const Text(
                'Receipt printed',
                style: TextStyle(fontSize: 15, color: AppColors.muted),
              ),

            const SizedBox(height: AppSpace.xl),
            FilledButton(
              key: const Key('next-bill'),
              // Enabled even when printing failed: the brief requires that a
              // printer problem never blocks the next sale.
              onPressed: () => Navigator.of(context).pop(),
              style: primaryActionStyle(),
              child: const Text('Next bill'),
            ),
          ],
        ),
      ),
    );
  }
}
