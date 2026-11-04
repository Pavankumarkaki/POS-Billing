/// Cancelling a bill: a reason, then the owner's PIN.
///
/// The brief requires both. The PIN is asked for even though the owner is
/// already signed in, because a till sits unlocked on a counter all day and
/// "signed in" is not the same as "the owner is standing here". It is the only
/// thing standing between a staff member and voiding a bill they took money
/// for.
///
/// The re-entry counts towards the lockout exactly like a sign-in, or this
/// dialog would be a free way to guess the PIN.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/domain.dart';
import '../../data/db.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';
import '../auth/pin_keypad.dart';

/// The reasons offered. Free text is allowed as well, but a list means the
/// common cases are one tap and the wording stays consistent in the audit log.
const List<String> kCancelReasons = [
  'Wrong item entered',
  'Customer left',
  'Wrong payment mode',
  'Test bill',
];

/// Shows the dialog. Returns true if the bill was cancelled.
Future<bool> showCancelDialog(
  BuildContext context,
  WidgetRef ref,
  BillRow bill,
) async {
  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => CancelBillDialog(bill: bill),
  );
  return done ?? false;
}

class CancelBillDialog extends ConsumerStatefulWidget {
  const CancelBillDialog({super.key, required this.bill});

  final BillRow bill;

  @override
  ConsumerState<CancelBillDialog> createState() => _CancelBillDialogState();
}

class _CancelBillDialogState extends ConsumerState<CancelBillDialog> {
  String? _reason;
  final _otherReason = TextEditingController();
  bool _enteringPin = false;

  String _pin = '';
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _otherReason.dispose();
    super.dispose();
  }

  String get _chosenReason =>
      _reason == 'Other' ? _otherReason.text.trim() : (_reason ?? '');

  bool get _reasonReady => _chosenReason.isNotEmpty;

  void _digit(String d) {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += d;
      _error = null;
    });
    if (_pin.length == 4) _confirm();
  }

  Future<void> _confirm() async {
    if (_busy) return;
    final session = ref.read(sessionProvider);
    if (session == null) return;

    setState(() => _busy = true);

    final auth = await ref.read(authRepositoryProvider.future);
    if (auth == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    // Counts towards the lockout, like any other PIN entry.
    final ok = await auth.confirmPin(userId: session.userId, pin: _pin);
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _busy = false;
        _pin = '';
        _error = 'That PIN is not right.';
      });
      return;
    }

    try {
      final device = ref.read(deviceProvider).value;
      await ref.read(billRepositoryProvider).cancelBill(
            billId: widget.bill.id,
            reason: _chosenReason,
            userId: session.userId,
            deviceId: device!.id,
          );
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _pin = '';
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Text(
        _enteringPin
            ? 'Owner PIN to confirm'
            : 'Cancel ${widget.bill.invoiceNo}?',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      content: SizedBox(
        width: 460,
        child: _enteringPin ? _pinStep() : _reasonStep(),
      ),
      actions: _enteringPin
          ? [
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _enteringPin = false;
                          _pin = '';
                          _error = null;
                        }),
                child: const Text('Back'),
              ),
            ]
          : [
              TextButton(
                key: const Key('keep-bill'),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep bill'),
              ),
              FilledButton(
                key: const Key('cancel-continue'),
                onPressed: _reasonReady
                    ? () => setState(() => _enteringPin = true)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Continue'),
              ),
            ],
    );
  }

  Widget _reasonStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'The number and the amount stay in your records, marked as '
          'cancelled. This cannot be undone.',
          style: TextStyle(fontSize: 15, color: AppColors.muted),
        ),
        const SizedBox(height: AppSpace.md),
        const Text(
          'Why?',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpace.xs),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: [
            for (final r in [...kCancelReasons, 'Other'])
              _ReasonChip(
                label: r,
                selected: _reason == r,
                onTap: () => setState(() => _reason = r),
              ),
          ],
        ),
        if (_reason == 'Other') ...[
          const SizedBox(height: AppSpace.md),
          TextField(
            key: const Key('other-reason'),
            controller: _otherReason,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Reason'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    );
  }

  Widget _pinStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Cancelling ${widget.bill.invoiceNo} · $_chosenReason',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 15, color: AppColors.muted),
        ),
        const SizedBox(height: AppSpace.md),
        PinDots(entered: _pin.length),
        SizedBox(
          height: 32,
          child: Center(
            child: _error == null
                ? null
                : Text(
                    _error!,
                    style: const TextStyle(
                      color: AppColors.dangerText,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),
        PinKeypad(
          onDigit: _digit,
          onClear: () => setState(() {
            _pin = '';
            _error = null;
          }),
          onBackspace: () => setState(() {
            if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
          }),
          enabled: !_busy,
          rowHeight: 56,
        ),
      ],
    );
  }
}

class _ReasonChip extends StatelessWidget {
  const _ReasonChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor:
              selected ? AppColors.dangerBg : AppColors.surface,
          foregroundColor:
              selected ? AppColors.dangerText : AppColors.ink,
          side: BorderSide(
            color: selected ? AppColors.danger : AppColors.border,
            width: 2,
          ),
          minimumSize: const Size(0, AppTouch.comfortable),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      );
}

/// Whether the signed-in user may cancel. Used to hide the button entirely
/// rather than show one that will be refused.
bool canCancel(WidgetRef ref) {
  final session = ref.watch(sessionProvider);
  return session != null && session.can(Permission.cancelBill);
}
