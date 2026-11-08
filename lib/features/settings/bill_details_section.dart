/// The Bill details card in Settings: tax type, FSSAI licence, GSTIN.
///
/// From the design canvas's Settings artboard, which shows these three next to
/// the printer card. Until now they could only be set during first-run setup,
/// so a mistyped FSSAI number meant reinstalling, and reinstalling costs the
/// data and the backups with it.
///
/// A tax mode change asks for confirmation first. Not because it is dangerous
/// to the data, which it is not, but because it silently changes what every
/// future bill is: a tax invoice with CGST and SGST, a bill of supply, or a
/// plain bill. That is worth one deliberate tap, and the dialog says plainly
/// that bills already issued do not change.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/domain.dart';
import '../../core/tax.dart';
import '../../data/outlet_repository.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';

class BillDetailsSection extends ConsumerStatefulWidget {
  const BillDetailsSection({super.key});

  @override
  ConsumerState<BillDetailsSection> createState() =>
      _BillDetailsSectionState();
}

class _BillDetailsSectionState extends ConsumerState<BillDetailsSection> {
  final _fssai = TextEditingController();
  final _gstin = TextEditingController();

  /// Null until the stored details arrive, then the edited copy.
  BillDetails? _edited;

  /// What was loaded, to tell an edit from a no-op.
  BillDetails? _stored;

  bool _busy = false;
  String? _message;
  bool _messageIsBad = false;

  @override
  void dispose() {
    _fssai.dispose();
    _gstin.dispose();
    super.dispose();
  }

  void _adopt(BillDetails stored) {
    _stored = stored;
    _edited = stored;
    _fssai.text = stored.fssaiNo;
    _gstin.text = stored.gstin ?? '';
  }

  BillDetails get _draft => BillDetails(
        fssaiNo: _fssai.text.trim(),
        taxMode: _edited!.taxMode,
        gstin: _gstin.text.trim(),
      );

  bool get _dirty {
    final s = _stored;
    if (s == null) return false;
    final d = _draft;
    final storedGstin = s.gstin ?? '';
    final draftGstin =
        BillDetails.modeHasGstin(d.taxMode) ? (d.gstin ?? '') : '';
    return d.fssaiNo != s.fssaiNo ||
        d.taxMode != s.taxMode ||
        draftGstin.toUpperCase() != storedGstin.toUpperCase();
  }

  Future<void> _save() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;

    final draft = _draft;
    final problems = ref.read(outletRepositoryProvider).validate(draft);
    if (problems.isNotEmpty) {
      setState(() {
        _message = problems.join(' ');
        _messageIsBad = true;
      });
      return;
    }

    // Only a mode change is confirmed. Correcting a typo in the licence
    // number should not make the owner read a dialog about tax invoices.
    if (draft.taxMode != _stored!.taxMode) {
      final ok = await showTaxModeDialog(context, _stored!.taxMode, draft.taxMode);
      if (ok != true) return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      final changed = await ref
          .read(outletRepositoryProvider)
          .updateBillDetails(draft, byUserId: session.userId);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsBad = false;
        _message = changed ? 'Saved.' : 'Nothing to change.';
      });
    } on OutletError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _messageIsBad = true;
        _message = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final details = ref.watch(billDetailsProvider);

    return details.when(
      loading: () => const _Card(
        children: [Center(child: CircularProgressIndicator())],
      ),
      error: (e, _) => _Card(children: [Text('$e')]),
      data: (stored) {
        if (stored == null) {
          return const _Card(
            children: [Text('Finish first-run setup first.')],
          );
        }

        // Adopt the stored values the first time, and again whenever they
        // change underneath, for example after a restore. An edit in progress
        // is not clobbered, because _dirty is false when nothing was typed.
        if (_stored == null || (!_dirty && _stored != stored)) {
          _adopt(stored);
        }

        final mode = _edited!.taxMode;
        final showGstin = BillDetails.modeHasGstin(mode);

        return _Card(
          children: [
            const Text(
              'Bill details',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: AppSpace.md),
            const Text(
              'Tax type',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            for (final m in TaxMode.values) ...[
              _TaxTile(
                mode: m,
                selected: mode == m,
                onTap: _busy
                    ? null
                    : () => setState(() {
                          _edited = _edited!.copyWith(taxMode: m);
                          _message = null;
                        }),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
            const SizedBox(height: AppSpace.sm),
            TextField(
              key: const Key('fssai-field'),
              controller: _fssai,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(14),
              ],
              decoration: const InputDecoration(
                labelText: 'FSSAI licence number',
                helperText: 'Exactly 14 digits. Billing is blocked without it.',
                helperMaxLines: 2,
              ),
              onChanged: (_) => setState(() => _message = null),
            ),
            if (showGstin) ...[
              const SizedBox(height: AppSpace.md),
              TextField(
                key: const Key('gstin-field'),
                controller: _gstin,
                enabled: !_busy,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [LengthLimitingTextInputFormatter(15)],
                decoration: InputDecoration(
                  labelText: BillDetails.modeRequiresGstin(mode)
                      ? 'GSTIN'
                      : 'GSTIN (optional)',
                  helperText: '15 characters, for example 37ABCDE1234F1Z5',
                  helperMaxLines: 2,
                ),
                onChanged: (_) => setState(() => _message = null),
              ),
            ],
            if (!showGstin) ...[
              const SizedBox(height: AppSpace.md),
              const Text(
                // Said rather than left for the owner to discover on a bill.
                'An unregistered outlet has no GSTIN, so saving this removes '
                'it from future bills.',
                key: Key('gstin-cleared-note'),
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: AppColors.muted,
                ),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: AppSpace.md),
              Container(
                key: const Key('bill-details-message'),
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color:
                      _messageIsBad ? AppColors.dangerBg : AppColors.softGreen,
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                ),
                child: Text(
                  _message!,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    color: _messageIsBad
                        ? AppColors.dangerText
                        : AppColors.primary,
                  ),
                ),
              ),
            ],
            const SizedBox(height: AppSpace.md),
            FilledButton(
              key: const Key('save-bill-details'),
              onPressed: _busy || !_dirty ? null : _save,
              style: primaryActionStyle(),
              child: _busy
                  ? const SizedBox(
                      height: 24,
                      width: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save bill details'),
            ),
          ],
        );
      },
    );
  }
}

/// Confirms a tax mode change, saying what it does and what it does not do.
Future<bool?> showTaxModeDialog(
  BuildContext context,
  TaxMode from,
  TaxMode to,
) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Change the tax type?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From ${taxModeLabel(from)} to ${taxModeLabel(to)}.',
              style: const TextStyle(fontSize: 15, color: AppColors.muted),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              'Bills from now on will be ${_documentFor(to)}.',
              key: const Key('tax-mode-effect'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpace.sm),
            const Text(
              // The reassurance that matters: this is not retroactive.
              'Bills already issued do not change. Their amounts, their tax '
              'and their numbers stay exactly as they were printed.',
              style: TextStyle(fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: AppSpace.sm),
            const Text(
              'The change is recorded with today\'s date, so your accountant '
              'can see which bills were on which tax type.',
              style: TextStyle(fontSize: 15, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it as it is'),
          ),
          FilledButton(
            key: const Key('confirm-tax-mode'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Change it'),
          ),
        ],
      ),
    );

String taxModeLabel(TaxMode mode) => switch (mode) {
      TaxMode.unregistered => 'Not registered for GST',
      TaxMode.composition => 'Composition scheme',
      TaxMode.regular5 => 'Regular GST, 5%',
      TaxMode.regular18 => 'Regular GST, 18%',
    };

String taxModeHelp(TaxMode mode) => switch (mode) {
      TaxMode.unregistered => 'A plain bill with no tax lines',
      TaxMode.composition =>
        'A Bill of Supply with no tax shown, plus the declaration',
      TaxMode.regular5 =>
        'A tax invoice with CGST and SGST. New items default to 5%.',
      TaxMode.regular18 =>
        'A tax invoice with CGST and SGST. New items default to 18%.',
    };

String _documentFor(TaxMode mode) => switch (mode) {
      TaxMode.unregistered => 'plain bills with no tax on them',
      TaxMode.composition => 'bills of supply, with the composition declaration',
      TaxMode.regular5 || TaxMode.regular18 =>
        'tax invoices showing CGST and SGST',
    };

class _TaxTile extends StatelessWidget {
  const _TaxTile({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final TaxMode mode;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        key: Key('tax-${mode.wireName}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.medium),
        child: Container(
          constraints: const BoxConstraints(minHeight: AppTouch.large),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md,
            vertical: AppSpace.sm,
          ),
          decoration: BoxDecoration(
            color: selected ? AppColors.softGreen : AppColors.surface,
            border: Border.all(
              color: selected ? AppColors.primary : AppColors.borderSoft,
              width: 2,
            ),
            borderRadius: BorderRadius.circular(AppRadius.medium),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      taxModeLabel(mode),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink,
                      ),
                    ),
                    Text(
                      taxModeHelp(mode),
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.3,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected) ...[
                const SizedBox(width: AppSpace.sm),
                const Icon(Icons.check_circle, color: AppColors.primary),
              ],
            ],
          ),
        ),
      );
}

class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: AppSpace.lg),
        child: Material(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.large),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      );
}
