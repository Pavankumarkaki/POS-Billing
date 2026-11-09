/// "My PIN": the dialog any signed-in user opens to change their own PIN.
///
/// Separate from the owner's Staff screen on purpose, and reachable by both
/// roles, because a cashier must be able to change the PIN the owner gave
/// them. Without that, the owner knows every cashier's PIN and can ring up
/// sales as them, which quietly undoes the point of recording who took the
/// money on each bill.
///
/// The current PIN is required. That is `AuthRepository.changePin`'s rule, not
/// this screen's: a till left unlocked on the counter must not be usable to
/// lock its owner out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pin.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';

Future<void> showChangePinDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const ChangePinDialog(),
    );

class ChangePinDialog extends ConsumerStatefulWidget {
  const ChangePinDialog({super.key});

  @override
  ConsumerState<ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends ConsumerState<ChangePinDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  bool _done = false;
  String? _problem;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final session = ref.read(sessionProvider);
    final auth = await ref.read(authRepositoryProvider.future);
    if (session == null || auth == null) return;

    if (_next.text != _confirm.text) {
      setState(() => _problem = 'The two new PINs do not match.');
      return;
    }

    setState(() {
      _busy = true;
      _problem = null;
    });

    try {
      await auth.changePin(
        userId: session.userId,
        currentPin: _current.text,
        newPin: _next.text,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
    } on PinError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_done) {
      return AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('PIN changed'),
        content: const Text(
          'Use the new PIN next time you sign in.',
          key: Key('change-pin-done'),
          style: TextStyle(fontSize: 15, color: AppColors.muted),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            style: primaryActionStyle(),
            child: const Text('Done'),
          ),
        ],
      );
    }

    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('My PIN'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Field(
              fieldKey: const Key('current-pin-field'),
              controller: _current,
              label: 'The PIN you use now',
              enabled: !_busy,
            ),
            const SizedBox(height: AppSpace.md),
            _Field(
              fieldKey: const Key('new-pin-field'),
              controller: _next,
              label: 'New PIN',
              enabled: !_busy,
              helper: 'Four digits. Not 1111, not 1234.',
            ),
            const SizedBox(height: AppSpace.md),
            _Field(
              fieldKey: const Key('new-pin-confirm-field'),
              controller: _confirm,
              label: 'New PIN again',
              enabled: !_busy,
            ),
            if (_problem != null) ...[
              const SizedBox(height: AppSpace.md),
              Container(
                key: const Key('change-pin-problem'),
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: AppColors.dangerBg,
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                ),
                child: Text(
                  _problem!,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    color: AppColors.dangerText,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('change-pin-save'),
          onPressed: _busy ? null : _save,
          style: primaryActionStyle(),
          child: _busy
              ? const SizedBox(
                  height: 24,
                  width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Change my PIN'),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.enabled,
    this.helper,
  });

  /// On the TextField itself, so a test finds a TextField by this key.
  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final String? helper;

  @override
  Widget build(BuildContext context) => TextField(
        key: fieldKey,
        controller: controller,
        enabled: enabled,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 4,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          helperMaxLines: 2,
          counterText: '',
        ),
      );
}
