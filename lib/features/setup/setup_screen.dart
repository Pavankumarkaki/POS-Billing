/// First-run setup. Runs once, then never again.
///
/// One scrolling form rather than a wizard, because `SetupRepository.validate`
/// returns every problem at once and a form can show them all at once. A wizard
/// would hide the FSSAI problem behind two more taps.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tax.dart';
import '../../data/setup_repository.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';

class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _fssai = TextEditingController();
  final _gstin = TextEditingController();
  final _ownerName = TextEditingController();
  final _pin = TextEditingController();
  final _confirmPin = TextEditingController();
  final _devicePrefix = TextEditingController(text: 'A');

  TaxMode _taxMode = TaxMode.unregistered;
  bool _pricesIncludeTax = false;
  bool _busy = false;
  List<String> _problems = const [];

  @override
  void dispose() {
    for (final c in [
      _name,
      _address,
      _phone,
      _fssai,
      _gstin,
      _ownerName,
      _pin,
      _confirmPin,
      _devicePrefix,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  SetupDetails _collect() => SetupDetails(
        outletName: _name.text,
        address: _address.text,
        phone: _phone.text,
        fssaiNo: _fssai.text,
        taxMode: _taxMode,
        gstin: _gstin.text.trim().isEmpty ? null : _gstin.text,
        pricesIncludeTax: _pricesIncludeTax,
        ownerName: _ownerName.text,
        ownerPin: _pin.text,
        devicePrefix: _devicePrefix.text,
      );

  Future<void> _finish() async {
    if (_busy) return;

    final problems = <String>[
      ...ref.read(setupRepositoryProvider).validate(_collect()),
      if (_pin.text != _confirmPin.text) 'The two PINs do not match.',
    ];

    if (problems.isNotEmpty) {
      setState(() => _problems = problems);
      return;
    }

    setState(() {
      _busy = true;
      _problems = const [];
    });

    try {
      await ref.read(setupRepositoryProvider).completeSetup(_collect());
      // Everything downstream reads these, so they must be re-fetched before
      // the app routes on isConfigured.
      ref.invalidate(isConfiguredProvider);
      ref.invalidate(outletProvider);
      ref.invalidate(deviceProvider);
      ref.invalidate(authRepositoryProvider);
      ref.invalidate(activeUsersProvider);
    } on SetupError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _problems = [e.message];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final needsGstin =
        _taxMode == TaxMode.regular5 || _taxMode == TaxMode.regular18;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(AppSpace.xl),
              children: [
                Text(
                  'Set up your restaurant',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: AppSpace.xs),
                const Text(
                  'This runs once. Everything here prints on your bills.',
                  style: TextStyle(fontSize: 15, color: AppColors.muted),
                ),
                const SizedBox(height: AppSpace.xl),

                if (_problems.isNotEmpty) _ProblemList(problems: _problems),

                _Section(
                  title: 'Restaurant',
                  children: [
                    _Field(
                      controller: _name,
                      label: 'Restaurant name',
                      hint: 'Printed at the top of every bill',
                    ),
                    _Field(
                      controller: _address,
                      label: 'Address',
                      maxLines: 2,
                    ),
                    _Field(
                      controller: _phone,
                      label: 'Phone number',
                      keyboardType: TextInputType.phone,
                    ),
                  ],
                ),

                _Section(
                  title: 'Licence and tax',
                  children: [
                    _Field(
                      controller: _fssai,
                      label: 'FSSAI licence number',
                      hint: 'Exactly 14 digits. Billing is blocked without it.',
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(14),
                      ],
                    ),
                    const SizedBox(height: AppSpace.sm),
                    const Text(
                      'Tax type',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    for (final mode in TaxMode.values)
                      _TaxModeTile(
                        mode: mode,
                        selected: _taxMode == mode,
                        onTap: () => setState(() => _taxMode = mode),
                      ),
                    if (needsGstin) ...[
                      const SizedBox(height: AppSpace.md),
                      _Field(
                        controller: _gstin,
                        label: 'GSTIN',
                        hint: '15 characters, for example 37ABCDE1234F1Z5',
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          LengthLimitingTextInputFormatter(15),
                        ],
                      ),
                    ],
                    const SizedBox(height: AppSpace.sm),
                    _Toggle(
                      label: 'Menu prices already include tax',
                      value: _pricesIncludeTax,
                      onChanged: (v) => setState(() => _pricesIncludeTax = v),
                    ),
                  ],
                ),

                _Section(
                  title: 'Owner',
                  children: [
                    _Field(controller: _ownerName, label: 'Owner name'),
                    _Field(
                      controller: _pin,
                      label: '4-digit PIN',
                      hint: 'Not 1111 or 1234. Only you should know this.',
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                    ),
                    _Field(
                      controller: _confirmPin,
                      label: 'Confirm PIN',
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                    ),
                  ],
                ),

                _Section(
                  title: 'This device',
                  children: [
                    _Field(
                      controller: _devicePrefix,
                      label: 'Device letter',
                      hint: 'Appears in every bill number, as in A/2627/000123',
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp('[A-Za-z]')),
                        LengthLimitingTextInputFormatter(1),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: AppSpace.xl),
                FilledButton(
                  onPressed: _busy ? null : _finish,
                  style: primaryActionStyle(),
                  child: _busy
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Finish setup'),
                ),
                const SizedBox(height: AppSpace.md),
                const Text(
                  'Works without internet',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProblemList extends StatelessWidget {
  const _ProblemList({required this.problems});
  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.lg),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.dangerBg,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            problems.length == 1
                ? 'One thing to fix'
                : '${problems.length} things to fix',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: AppColors.dangerText,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          for (final p in problems)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '• $p',
                style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.dangerText,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.lg),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpace.md),
          ...children,
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.hint,
    this.keyboardType,
    this.inputFormatters,
    this.obscureText = false,
    this.maxLines = 1,
    this.textCapitalization = TextCapitalization.sentences,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final bool obscureText;
  final int maxLines;
  final TextCapitalization textCapitalization;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.md),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        obscureText: obscureText,
        maxLines: obscureText ? 1 : maxLines,
        textCapitalization: textCapitalization,
        style: const TextStyle(fontSize: 17),
        decoration: InputDecoration(
          labelText: label,
          helperText: hint,
          helperMaxLines: 2,
        ),
      ),
    );
  }
}

class _TaxModeTile extends StatelessWidget {
  const _TaxModeTile({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final TaxMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (title, help) = switch (mode) {
      TaxMode.unregistered => (
          'Not registered for GST',
          'A plain bill with no tax lines',
        ),
      TaxMode.composition => (
          'Composition scheme',
          'A Bill of Supply with no tax shown, plus the declaration',
        ),
      TaxMode.regular5 => (
          'Regular GST, 5%',
          'A tax invoice with CGST and SGST. New items default to 5%.',
        ),
      TaxMode.regular18 => (
          'Regular GST, 18%',
          'A tax invoice with CGST and SGST. New items default to 18%.',
        ),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.medium),
        child: Semantics(
          selected: selected,
          button: true,
          child: Container(
            constraints: const BoxConstraints(minHeight: AppTouch.large),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
            decoration: BoxDecoration(
              color: selected ? AppColors.softGreen : AppColors.surface,
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
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        help,
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  const Icon(Icons.check_circle, color: AppColors.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(AppRadius.medium),
      child: Container(
        constraints: const BoxConstraints(minHeight: AppTouch.comfortable),
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeTrackColor: AppColors.primary,
            ),
          ],
        ),
      ),
    );
  }
}
