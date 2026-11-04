/// Printer settings. Owner only.
///
/// The screen the brief's hardware checklist is run from: choose Bluetooth,
/// LAN or the file-writing fake, pick a paired printer or type an address, set
/// the paper width, and print a test page.
library;

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/domain.dart';
import '../../data/db.dart';
import '../../printing/printer.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';

class PrinterSettingsScreen extends ConsumerStatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  ConsumerState<PrinterSettingsScreen> createState() =>
      _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState
    extends ConsumerState<PrinterSettingsScreen> {
  PrinterConfig? _config;
  final _address = TextEditingController();

  bool _testing = false;
  PrintResult? _testResult;

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _save(PrinterConfig next) async {
    setState(() {
      _config = next;
      _testResult = null;
    });

    final db = ref.read(databaseProvider);
    final device = await db.select(db.devices).getSingleOrNull();
    final session = ref.read(sessionProvider);
    if (device == null || session == null) return;

    final before = device.printerCfg;

    await db.transaction(() async {
      await (db.update(db.devices)..where((d) => d.id.equals(device.id)))
          .write(DevicesCompanion(
        printerCfg: Value(jsonEncode(next.toJson())),
      ));

      // The brief: every setting change is audited, with before and after.
      await db.into(db.auditLog).insert(AuditLogCompanion.insert(
            id: const Uuid().v7(),
            at: DateTime.now(),
            userId: Value(session.userId),
            deviceId: device.id,
            action: AuditAction.settingChanged,
            entity: AuditEntity.device,
            entityId: device.id,
            before: Value(before),
            after: Value(jsonEncode(next.toJson())),
          ));
    });

    // The printer itself is rebuilt from the config, so both must refresh.
    ref.invalidate(printerConfigProvider);
    ref.invalidate(deviceProvider);
  }

  Future<void> _printTest() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final result = await ref.read(printServiceProvider).printTestPage();
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session == null || !session.can(Permission.changeSettings)) {
      return const _OwnerOnly();
    }

    final stored = ref.watch(printerConfigProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Printer'),
      ),
      body: stored.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (saved) {
          final config = _config ??= saved;
          if (_address.text.isEmpty && config.address.isNotEmpty) {
            _address.text = config.address;
          }

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  _Section(
                    title: 'Connection',
                    children: [
                      for (final kind in PrinterKind.values)
                        _KindTile(
                          kind: kind,
                          selected: config.kind == kind,
                          onTap: () => _save(config.copyWith(kind: kind)),
                        ),
                    ],
                  ),

                  if (config.kind == PrinterKind.bluetooth)
                    _BluetoothPicker(
                      selected: config.address,
                      onPick: (address) =>
                          _save(config.copyWith(address: address)),
                    ),

                  if (config.kind == PrinterKind.lan)
                    _Section(
                      title: 'Network address',
                      children: [
                        TextField(
                          key: const Key('lan-address'),
                          controller: _address,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'Printer IP address',
                            helperText: 'For example 192.168.1.50. The '
                                'printer must be on the same Wi-Fi.',
                            helperMaxLines: 2,
                          ),
                          onSubmitted: (v) =>
                              _save(config.copyWith(address: v.trim())),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        OutlinedButton(
                          key: const Key('save-address'),
                          onPressed: () => _save(
                            config.copyWith(address: _address.text.trim()),
                          ),
                          child: const Text('Save address'),
                        ),
                      ],
                    ),

                  _Section(
                    title: 'Paper',
                    children: [
                      _WidthPicker(
                        current: config.widthPx,
                        onPick: (w) => _save(config.copyWith(widthPx: w)),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      _Toggle(
                        label: 'Cut paper after each bill',
                        value: config.autoCut,
                        onChanged: (v) =>
                            _save(config.copyWith(autoCut: v)),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      _Toggle(
                        label: 'Older printer mode (ESC *)',
                        help: 'Only if the test page prints blank or '
                            'garbled. Most printers do not need this.',
                        value: config.useEscStar,
                        onChanged: (v) =>
                            _save(config.copyWith(useEscStar: v)),
                      ),
                    ],
                  ),

                  _Section(
                    title: 'Check it works',
                    children: [
                      const Text(
                        'The test page prints Telugu text, the rupee sign '
                        'and a full-width ruler. If all three look right, '
                        'the printer is set up correctly.',
                        style: TextStyle(
                          fontSize: 15,
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: AppSpace.md),
                      FilledButton(
                        key: const Key('print-test'),
                        onPressed: _testing ? null : _printTest,
                        style: primaryActionStyle(),
                        child: _testing
                            ? const SizedBox(
                                height: 24,
                                width: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Print a test page'),
                      ),
                      if (_testResult != null) ...[
                        const SizedBox(height: AppSpace.md),
                        _TestOutcome(result: _testResult!),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          );
        },
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
          title: const Text('Printer'),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpace.xxl),
            child: Text(
              'Only the owner can change settings.',
              style: TextStyle(fontSize: 17, color: AppColors.muted),
            ),
          ),
        ),
      );
}

class _KindTile extends StatelessWidget {
  const _KindTile({
    required this.kind,
    required this.selected,
    required this.onTap,
  });

  final PrinterKind kind;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (title, help) = switch (kind) {
      PrinterKind.bluetooth => (
          'Bluetooth',
          'Best for one device at the counter',
        ),
      PrinterKind.lan => (
          'Wi-Fi (LAN)',
          'Use this if two devices share the printer',
        ),
      PrinterKind.fake => (
          'Save to a file',
          'No printer. Receipts are written as images you can open.',
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

class _BluetoothPicker extends ConsumerWidget {
  const _BluetoothPicker({required this.selected, required this.onPick});

  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paired = ref.watch(pairedPrintersProvider);

    return _Section(
      title: 'Paired printer',
      children: [
        paired.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(AppSpace.md),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('Could not list printers.\n$e'),
          data: (printers) {
            if (printers.isEmpty) {
              return const Text(
                'No paired printers found.\n\n'
                'Pair the printer in Android Settings first, then come back. '
                'If you have already paired it, check Bluetooth is on and '
                'that this app has Bluetooth permission.',
                style: TextStyle(fontSize: 15, color: AppColors.muted),
              );
            }
            return Column(
              children: [
                for (final p in printers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpace.sm),
                    child: InkWell(
                      onTap: () => onPick(p.address),
                      borderRadius: BorderRadius.circular(AppRadius.medium),
                      child: Container(
                        constraints: const BoxConstraints(
                          minHeight: AppTouch.comfortable,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.md,
                        ),
                        decoration: BoxDecoration(
                          color: selected == p.address
                              ? AppColors.softGreen
                              : AppColors.surface,
                          borderRadius:
                              BorderRadius.circular(AppRadius.medium),
                          border: Border.all(
                            color: selected == p.address
                                ? AppColors.primary
                                : AppColors.borderSoft,
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
                                    p.name.isEmpty ? 'Unnamed printer' : p.name,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    p.address,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: AppColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (selected == p.address)
                              const Icon(
                                Icons.check_circle,
                                color: AppColors.primary,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpace.sm),
        OutlinedButton(
          onPressed: () => ref.invalidate(pairedPrintersProvider),
          child: const Text('Look again'),
        ),
      ],
    );
  }
}

class _WidthPicker extends StatelessWidget {
  const _WidthPicker({required this.current, required this.onPick});

  final int current;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    const widths = {
      576: '80 mm (576 dots)',
      384: '58 mm (384 dots)',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Paper width',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpace.xs),
        Row(
          children: [
            for (final entry in widths.entries) ...[
              if (entry.key != widths.keys.first)
                const SizedBox(width: AppSpace.sm),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => onPick(entry.key),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: current == entry.key
                        ? AppColors.primary
                        : AppColors.surface,
                    foregroundColor: current == entry.key
                        ? Colors.white
                        : AppColors.ink,
                    minimumSize: const Size(0, AppTouch.comfortable),
                  ),
                  child: Text(
                    entry.value,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
  });

  final String label;
  final String? help;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(AppRadius.medium),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.md,
          vertical: AppSpace.sm,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.border),
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
                    label,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (help != null)
                    Text(
                      help!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.muted,
                      ),
                    ),
                ],
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

class _TestOutcome extends StatelessWidget {
  const _TestOutcome({required this.result});
  final PrintResult result;

  @override
  Widget build(BuildContext context) {
    final ok = result.ok;
    return Container(
      key: const Key('test-outcome'),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: ok ? AppColors.softGreen : AppColors.dangerBg,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ok ? 'Test page sent' : (result.error ?? 'It did not print.'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: ok ? AppColors.primary : AppColors.dangerText,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            ok
                // Worth saying: a successful send is not a successful print.
                // Out of paper and a jam both look like success from here.
                ? 'If nothing came out, check the paper roll and the cover. '
                    'The app can only tell that the printer accepted it.'
                : 'Nothing has been lost. Fix the problem and try again.',
            style: TextStyle(
              fontSize: 14,
              color: ok ? AppColors.primary : AppColors.dangerText,
            ),
          ),
          if (ok && result.artefactPath != null) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              'Written to ${result.artefactPath}',
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ],
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
  Widget build(BuildContext context) => Container(
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
