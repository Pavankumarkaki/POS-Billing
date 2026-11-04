/// Backup, restore, and the accountant's copy. Owner only.
///
/// The design canvas has no artboard for this screen, so it follows the
/// Settings artboard's rules instead: the same ground and card colours, 14 px
/// card corners, 18 px padding, and nothing tappable under 52 px.
///
/// The ordering is deliberate. The brief says not to assume a background
/// backup succeeded, so the first thing on the screen is when the last one
/// actually did, and the most destructive thing on it, restore, is last and
/// behind a PIN.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/business_date.dart';
import '../../core/domain.dart';
import '../../data/backup_service.dart';
import '../../data/backup_worker.dart';
import '../../data/export_service.dart';
import '../../data/settings_repository.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';
import '../bills/bills_screen.dart' show todayProvider;

/// What period the accountant's copy covers.
///
/// Months and financial years, not the reports screen's today-week-month: an
/// accountant files by month and by year, and "today" is not a thing anyone
/// asks a bookkeeper for.
enum ExportPeriod {
  thisMonth('This month'),
  lastMonth('Last month'),
  financialYear('This financial year');

  const ExportPeriod(this.label);
  final String label;

  ({BusinessDate from, BusinessDate to}) range(BusinessDate today) =>
      switch (this) {
        ExportPeriod.thisMonth => (from: today.monthStart, to: today),
        ExportPeriod.lastMonth => _lastMonth(today),
        // To today, not to 31 March: a year-to-date figure is what is wanted
        // in December, and the full year gives the same answer in April.
        ExportPeriod.financialYear => (
            from: today.financialYear.firstDay,
            to: today,
          ),
      };

  static ({BusinessDate from, BusinessDate to}) _lastMonth(BusinessDate today) {
    final start = today.monthStart;
    final end = start.addDays(-1);
    return (from: BusinessDate(end.year, end.month, 1), to: end);
  }
}

/// "Today at 4:32 AM", or "3 days ago". Plain language, no clock arithmetic
/// for the reader to do.
///
/// Top-level and pure so it can be tested without pumping a widget, because
/// this string is the whole point of the screen.
String describeBackupTime(DateTime? at, {required DateTime now}) {
  if (at == null) return 'Never';

  final onDay = BusinessDate(at.year, at.month, at.day);
  final today = BusinessDate(now.year, now.month, now.day);
  final time = _clock(at);

  if (onDay == today) return 'Today at $time';
  if (onDay == today.addDays(-1)) return 'Yesterday at $time';

  final days = now.difference(at).inDays;
  if (days < 7) return '$days days ago, at $time';
  return '${at.day} ${_monthNames[at.month - 1]} at $time';
}

const List<String> _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _clock(DateTime at) {
  final hour12 = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final minute = at.minute.toString().padLeft(2, '0');
  return '$hour12:$minute ${at.hour < 12 ? 'AM' : 'PM'}';
}

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

/// Which long-running thing is going on, or null.
///
/// Tracked rather than a single `_busy` flag so the spinner appears on the
/// button that was actually pressed. One shared flag put it on Back up now
/// whenever anything at all was running, which reads as the wrong thing
/// happening.
enum _Running { backup, folder, export, restore }

class _BackupScreenState extends ConsumerState<BackupScreen> {
  _Running? _running;

  bool get _busy => _running != null;

  /// The last thing that happened, shown until something else does. Kept in
  /// the screen rather than in a snack bar: an owner who taps Back up now and
  /// looks away should still find out what happened.
  String? _message;
  bool _messageIsBad = false;

  ExportPeriod _period = ExportPeriod.thisMonth;

  void _report(String message, {bool bad = false}) {
    if (!mounted) return;
    setState(() {
      _running = null;
      _message = message;
      _messageIsBad = bad;
    });
  }

  Future<void> _backupNow() async {
    setState(() {
      _running = _Running.backup;
      _message = null;
    });

    final file = await ref.read(databaseFileProvider.future);
    final attempt = await runBackupNow(
      ref.read(databaseProvider),
      databaseFile: file,
    );

    switch (attempt.result) {
      case BackupDone(:final bills, :final bytes, file: final written):
        _report('Backed up $bills ${bills == 1 ? 'bill' : 'bills'}, '
            '${_size(bytes)}, to ${p.basename(written.path)}');
      case BackupFailed(:final message):
        _report(message, bad: true);
    }
  }

  Future<void> _chooseFolder() async {
    setState(() {
      _running = _Running.folder;
      _message = null;
    });

    String? picked;
    try {
      picked = await FilePicker.getDirectoryPath();
    } on Object catch (e) {
      _report('The folder picker could not be opened: $e', bad: true);
      return;
    }

    if (picked == null || picked.isEmpty) {
      // Cancelled. Not an error, and not worth a message.
      if (mounted) setState(() => _running = null);
      return;
    }

    // Probed by writing, not assumed. Android hands out paths under /storage
    // that look ordinary and cannot be written without all-files access, and
    // a destination that fails silently every night is worse than refusing it
    // here while the owner is standing in front of the screen.
    final service = await ref.read(backupServiceProvider.future);
    final reason = await service.probeWritable(Directory(picked));
    if (reason != null) {
      _report('$reason\n\nStill backing up to the folder shown above.',
          bad: true);
      return;
    }

    await ref
        .read(settingsRepositoryProvider)
        .write(SettingKeys.backupDir, picked);
    ref.invalidate(backupDirectoryProvider);
    _report('Backups will go to $picked');
  }

  Future<void> _useDefaultFolder() async {
    setState(() => _running = _Running.folder);
    await ref.read(settingsRepositoryProvider).remove(SettingKeys.backupDir);
    ref.invalidate(backupDirectoryProvider);
    _report('Back to the app\'s own folder.');
  }

  Future<void> _setNightly(bool on) async {
    await ref
        .read(settingsRepositoryProvider)
        .writeFlag(SettingKeys.backupNightlyEnabled, on);
    try {
      if (on) {
        await scheduleNightlyBackup();
      } else {
        await cancelNightlyBackup();
      }
    } on Object catch (e) {
      // The setting is already saved, and the startup catch-up path in
      // backupIfStale does not depend on WorkManager at all, so a scheduling
      // failure is worth reporting but not worth refusing the change.
      _report('Saved, but Android would not take the schedule: $e', bad: true);
    }
  }

  Future<void> _export({required bool asExcel}) async {
    setState(() {
      _running = _Running.export;
      _message = null;
    });

    try {
      final today = await ref.read(todayProvider.future);
      final range = _period.range(today);
      final sheets =
          await ref.read(exportServiceProvider).build(range.from, range.to);

      final base = await ref.read(backupDirectoryProvider.future);
      final into = Directory(p.join(base.path, 'exports'));
      if (!into.existsSync()) into.createSync(recursive: true);

      final stem = 'pos-sales-${range.from.iso}-to-${range.to.iso}';

      if (asExcel) {
        final file = File(p.join(into.path, '$stem.xlsx'));
        await file.writeAsBytes(toXlsx(sheets), flush: true);
        _report('Saved ${p.basename(file.path)} in ${into.path}');
      } else {
        // One CSV per sheet, in a folder of its own, because six files loose
        // in a shared folder is how an accountant loses one.
        final folder = Directory(p.join(into.path, stem));
        if (!folder.existsSync()) folder.createSync(recursive: true);
        for (final sheet in sheets) {
          final file =
              File(p.join(folder.path, '${_fileSafe(sheet.name)}.csv'));
          await file.writeAsBytes(csvBytes(toCsv(sheet)), flush: true);
        }
        _report('Saved ${sheets.length} CSV files in ${folder.path}');
      }
    } on FileSystemException catch (e) {
      _report('The export could not be written: ${e.osError?.message ?? e.message}',
          bad: true);
    } on Object catch (e) {
      _report('The export could not be built: $e', bad: true);
    }
  }

  Future<void> _restore() async {
    setState(() {
      _running = _Running.restore;
      _message = null;
    });

    String? path;
    try {
      // No extension filter. Android's document picker handles custom
      // extensions inconsistently, and the file is validated by opening it
      // and reading its schema anyway, which is a stronger check than a name.
      final picked = await FilePicker.pickFile();
      path = picked?.path;
    } on Object catch (e) {
      _report('The file picker could not be opened: $e', bad: true);
      return;
    }

    if (path == null) {
      if (mounted) setState(() => _running = null);
      return;
    }

    final service = await ref.read(backupServiceProvider.future);
    final check = service.inspect(File(path));

    if (check is RestoreRefused) {
      _report(check.reason, bad: true);
      return;
    }
    final usable = check as RestoreUsable;

    if (!mounted) return;
    setState(() => _running = null);

    final confirmed = await showRestoreDialog(context, ref, usable);
    if (confirmed != true) return;

    setState(() => _running = _Running.restore);
    final reason = await service.stageRestore(usable.file);
    if (reason != null) {
      _report(reason, bad: true);
      return;
    }

    _report('Ready to restore. Close the app completely and open it again: '
        'the backup is put in place at the next start.');
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session == null || !session.can(Permission.changeSettings)) {
      return const _OwnerOnly();
    }

    final status = ref.watch(backupStatusProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Backup and export'),
      ),
      body: status.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xxl),
            child: Text('$e'),
          ),
        ),
        data: (s) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(AppSpace.lg),
              children: [
                if (s.restoreNotice != null) ...[
                  _RestoreNotice(
                    text: s.restoreNotice!,
                    onDismiss: () async {
                      await ref
                          .read(settingsRepositoryProvider)
                          .remove(SettingKeys.restoreNotice);
                    },
                  ),
                  const SizedBox(height: AppSpace.lg),
                ],
                _LastBackup(status: s),
                if (_message != null) ...[
                  const SizedBox(height: AppSpace.md),
                  _Message(text: _message!, bad: _messageIsBad),
                ],
                const SizedBox(height: AppSpace.lg),
                FilledButton(
                  key: const Key('backup-now'),
                  onPressed: _busy ? null : _backupNow,
                  style: primaryActionStyle(),
                  child: _running == _Running.backup
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Back up now'),
                ),
                const SizedBox(height: AppSpace.lg),
                _Section(
                  title: 'Where backups go',
                  children: [
                    SelectableText(
                      s.directory.path,
                      key: const Key('backup-dir'),
                      style: const TextStyle(fontSize: 15, height: 1.4),
                    ),
                    if (s.usingDefaultDirectory) ...[
                      const SizedBox(height: AppSpace.md),
                      // The one thing about the default folder that the owner
                      // has to know, said plainly rather than buried.
                      const _Note(
                        key: Key('default-folder-warning'),
                        text: 'This is the app\'s own folder. Android deletes '
                            'it if the app is uninstalled, so copy a backup '
                            'onto a computer or an SD card now and then.',
                      ),
                    ],
                    const SizedBox(height: AppSpace.md),
                    OutlinedButton(
                      key: const Key('choose-folder'),
                      onPressed: _busy ? null : _chooseFolder,
                      child: const Text('Choose a folder'),
                    ),
                    if (!s.usingDefaultDirectory) ...[
                      const SizedBox(height: AppSpace.sm),
                      TextButton(
                        key: const Key('use-default-folder'),
                        onPressed: _busy ? null : _useDefaultFolder,
                        child: const Text('Use the app\'s own folder'),
                      ),
                    ],
                  ],
                ),
                _Section(
                  title: 'Every night',
                  children: [
                    _Toggle(
                      label: 'Back up automatically',
                      help: 'Around 4:30 AM, after the day closes. Android '
                          'decides when background work actually runs, so '
                          'check the time above now and then.',
                      value: s.nightlyEnabled,
                      onChanged: _busy ? null : _setNightly,
                    ),
                  ],
                ),
                _Section(
                  title: 'A copy for the accountant',
                  children: [
                    const Text(
                      'Sales by tax rate, the SAC summary, document counts, '
                      'and a line for every bill.',
                      style: TextStyle(fontSize: 15, color: AppColors.muted),
                    ),
                    const SizedBox(height: AppSpace.md),
                    for (final period in ExportPeriod.values) ...[
                      _PeriodTile(
                        period: period,
                        selected: _period == period,
                        onTap: () => setState(() => _period = period),
                      ),
                      const SizedBox(height: AppSpace.sm),
                    ],
                    const SizedBox(height: AppSpace.sm),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('export-excel'),
                            onPressed:
                                _busy ? null : () => _export(asExcel: true),
                            child: const Text('Excel'),
                          ),
                        ),
                        const SizedBox(width: AppSpace.md),
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('export-csv'),
                            onPressed:
                                _busy ? null : () => _export(asExcel: false),
                            child: const Text('CSV'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                _Section(
                  title: 'Restore',
                  children: [
                    const Text(
                      'Replaces everything in the app with what is in a '
                      'backup file. Bills taken since that backup will not be '
                      'in the app any more. The database being replaced is '
                      'kept on the phone, so a mistake here can be undone.',
                      style: TextStyle(fontSize: 15, height: 1.4),
                    ),
                    const SizedBox(height: AppSpace.md),
                    OutlinedButton(
                      key: const Key('restore'),
                      onPressed: _busy ? null : _restore,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.dangerText,
                        side: const BorderSide(color: AppColors.danger),
                        minimumSize: const Size.fromHeight(AppTouch.large),
                      ),
                      child: const Text('Restore from a backup'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// When the last backup actually succeeded. The first thing on the screen,
/// because the brief says a scheduled backup is not a backup that happened.
class _LastBackup extends StatelessWidget {
  const _LastBackup({required this.status});

  final BackupStatus status;

  @override
  Widget build(BuildContext context) {
    final warn = status.needsAttention;
    final when = describeBackupTime(status.lastSuccessAt, now: status.now);

    return Container(
      key: const Key('last-backup'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: warn ? AppColors.warnBg : AppColors.softGreen,
        borderRadius: BorderRadius.circular(AppRadius.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Last backup',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: warn ? AppColors.warnText : AppColors.primary,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          Text(
            when,
            key: const Key('last-backup-when'),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: warn ? AppColors.warnText : AppColors.primary,
            ),
          ),
          if (status.lastFile != null) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              status.lastFile!,
              style: const TextStyle(fontSize: 14, color: AppColors.muted),
            ),
          ],
          if (warn) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              status.everSucceeded
                  ? 'That is longer ago than it should be. Back up now.'
                  : 'Nothing has been backed up yet. Back up now.',
              key: const Key('stale-warning'),
              style: const TextStyle(
                fontSize: 15,
                height: 1.4,
                color: AppColors.warnText,
              ),
            ),
          ],
          if (status.lastError != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              // The failure, in the words the service put it in. The owner can
              // act on "Android will not let this app write to that folder";
              // they cannot act on "backup failed".
              'Last attempt failed: ${status.lastError}',
              key: const Key('last-error'),
              style: const TextStyle(
                fontSize: 15,
                height: 1.4,
                color: AppColors.dangerText,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What a staged restore did at the last app start.
///
/// Shown until the owner dismisses it, rather than for a few seconds. Someone
/// who restores a backup in the evening and reopens the app the next morning
/// needs to find out that it happened.
class _RestoreNotice extends StatelessWidget {
  const _RestoreNotice({required this.text, required this.onDismiss});

  final String text;
  final Future<void> Function() onDismiss;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('restore-notice'),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.neutral,
          borderRadius: BorderRadius.circular(AppRadius.large),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Restore',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              text,
              style: const TextStyle(
                fontSize: 16,
                height: 1.4,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
            TextButton(
              key: const Key('dismiss-restore-notice'),
              onPressed: onDismiss,
              child: const Text('Got it'),
            ),
          ],
        ),
      );
}

/// Confirms a restore: what is in the backup, what it costs, then the PIN.
///
/// The PIN is asked for even though the owner is signed in, for the same
/// reason cancelling a bill asks: a till sits unlocked on a counter all day,
/// and this is the most destructive thing in the app.
Future<bool?> showRestoreDialog(
  BuildContext context,
  WidgetRef ref,
  RestoreUsable backup,
) =>
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _RestoreDialog(backup: backup),
    );

class _RestoreDialog extends ConsumerStatefulWidget {
  const _RestoreDialog({required this.backup});

  final RestoreUsable backup;

  @override
  ConsumerState<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends ConsumerState<_RestoreDialog> {
  final _pin = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    final session = ref.read(sessionProvider);
    final auth = await ref.read(authRepositoryProvider.future);
    if (session == null || auth == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    // Counts towards the lockout, like any other PIN entry, or this dialog
    // would be a free way to guess the owner's PIN.
    final ok = await auth.confirmPin(userId: session.userId, pin: _pin.text);
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _busy = false;
        _pin.clear();
        _error = 'That PIN is not right.';
      });
      return;
    }

    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.backup;
    final newest = b.newestBillAt;

    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: const Text('Restore this backup?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p.basename(b.file.path),
            style: const TextStyle(fontSize: 15, color: AppColors.muted),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            '${b.bills} ${b.bills == 1 ? 'bill' : 'bills'} in this backup.',
            key: const Key('restore-bill-count'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          if (newest != null) ...[
            const SizedBox(height: AppSpace.xs),
            Text(
              // What a restore costs, before it is agreed to rather than
              // after: everything since this moment goes.
              'The newest bill in it is from '
              '${describeBackupTime(newest, now: DateTime.now())}.',
              key: const Key('restore-newest'),
              style: const TextStyle(fontSize: 15, height: 1.4),
            ),
          ],
          const SizedBox(height: AppSpace.md),
          const Text(
            'Anything billed after that will not be in the app any more. '
            'The database being replaced is kept on the phone.',
            style: TextStyle(fontSize: 15, height: 1.4),
          ),
          const SizedBox(height: AppSpace.lg),
          TextField(
            key: const Key('restore-pin'),
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Your PIN',
              helperText: 'Confirms it is you and not someone at the counter.',
              helperMaxLines: 2,
            ),
            // Without this the Restore button below never enables: a
            // controller change rebuilds the TextField but not this dialog,
            // so `_pin.text.isEmpty` would stay true from the first build.
            onChanged: (_) => setState(() {}),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              _error!,
              style: const TextStyle(
                fontSize: 15,
                color: AppColors.dangerText,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Keep what is here'),
        ),
        FilledButton(
          key: const Key('restore-confirm'),
          onPressed: _busy || _pin.text.isEmpty ? null : _confirm,
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  // A Material rather than a coloured Container: a ListTile paints its
  // background and ink splash on the nearest Material ancestor, so a
  // DecoratedBox in between hides them, and Flutter asserts about it.
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
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(height: AppSpace.md),
                ...children,
              ],
            ),
          ),
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: AppColors.warnBg,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 15,
            height: 1.4,
            color: AppColors.warnText,
          ),
        ),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.bad});

  final String text;
  final bool bad;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('outcome'),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: bad ? AppColors.dangerBg : AppColors.softGreen,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 15,
            height: 1.4,
            color: bad ? AppColors.dangerText : AppColors.primary,
          ),
        ),
      );
}

class _PeriodTile extends StatelessWidget {
  const _PeriodTile({
    required this.period,
    required this.selected,
    required this.onTap,
  });

  final ExportPeriod period;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        key: Key('period-${period.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.medium),
        child: Container(
          constraints:
              const BoxConstraints(minHeight: AppTouch.comfortable),
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
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 22,
                color: selected ? AppColors.primary : AppColors.border,
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  period.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
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
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const Key('nightly-toggle'),
            contentPadding: EdgeInsets.zero,
            title: Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.ink,
              ),
            ),
            value: value,
            // A white thumb on a dark track, the same as the printer screen's
            // toggle. The default pale track with a dark thumb reads as
            // ambiguous on the device: on and off are told apart only by which
            // side the thumb is on.
            activeThumbColor: Colors.white,
            activeTrackColor: AppColors.primary,
            onChanged: onChanged,
          ),
          if (help != null)
            Text(
              help!,
              style: const TextStyle(
                fontSize: 14,
                height: 1.4,
                color: AppColors.muted,
              ),
            ),
        ],
      );
}

class _OwnerOnly extends StatelessWidget {
  const _OwnerOnly();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          title: const Text('Backup and export'),
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

/// A sheet name as a file name: spaces to dashes, lower case.
String _fileSafe(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

String _size(int bytes) {
  if (bytes < 1024) return '$bytes bytes';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
