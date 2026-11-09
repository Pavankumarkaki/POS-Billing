/// Staff: who may sign in, with what role, and the way back when someone
/// forgets their PIN.
///
/// Phase 1 built every piece of this in the data layer and then never gave it
/// a screen, so a real install had exactly one user: the owner created during
/// first-run setup. That made the two roles and the audit log decorative,
/// because every bill on the device was rung up by "the owner" whoever was
/// actually standing at the counter.
///
/// Owner only, like the rest of Settings. The gate is the same one the printer
/// screen uses: the tab is not offered to staff at all, and this check is the
/// backstop for anyone who reaches the screen another way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/domain.dart';
import '../../core/pin.dart';
import '../../data/db.dart';
import '../../data/setup_repository.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';

class StaffScreen extends ConsumerStatefulWidget {
  const StaffScreen({super.key});

  @override
  ConsumerState<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends ConsumerState<StaffScreen> {
  String? _message;
  bool _messageIsBad = false;

  void _say(String message, {bool bad = false}) {
    if (!mounted) return;
    setState(() {
      _message = message;
      _messageIsBad = bad;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session == null || !session.can(Permission.manageUsers)) {
      return const _OwnerOnly();
    }

    final staff = ref.watch(staffProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: const Text('Staff'),
      ),
      body: staff.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xxl),
            child: Text('$e'),
          ),
        ),
        data: (users) {
          final active = users.where((u) => u.isActive).toList();
          final gone = users.where((u) => !u.isActive).toList();

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(AppSpace.lg),
                children: [
                  if (_message != null)
                    _Banner(message: _message!, bad: _messageIsBad),

                  _Card(
                    children: [
                      const _CardTitle('Who can sign in'),
                      const SizedBox(height: AppSpace.sm),
                      const Text(
                        'Each person needs their own PIN. Bills record who '
                        'rang them up, which only means something if the '
                        'cashier is not signing in as the owner.',
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.4,
                          color: AppColors.muted,
                        ),
                      ),
                      const SizedBox(height: AppSpace.lg),
                      for (final user in active)
                        _StaffTile(
                          user: user,
                          isSelf: user.id == session.userId,
                          onlyOwner: _onlyActiveOwner(users, user),
                          onResetPin: () => _resetPin(user),
                          onDeactivate: () => _deactivate(user),
                          onClearLockout: () => _clearLockout(user),
                        ),
                    ],
                  ),

                  _AddStaffCard(
                    onAdded: (name) => _say('$name can now sign in.'),
                    onFailed: (message) => _say(message, bad: true),
                  ),

                  if (gone.isNotEmpty)
                    _Card(
                      children: [
                        const _CardTitle('No longer working here'),
                        const SizedBox(height: AppSpace.sm),
                        const Text(
                          'Kept, never deleted, so the bills they rang up '
                          'still say who took the money.',
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.4,
                            color: AppColors.muted,
                          ),
                        ),
                        const SizedBox(height: AppSpace.lg),
                        for (final user in gone)
                          _GoneTile(
                            user: user,
                            onReactivate: () => _reactivate(user),
                          ),
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

  /// Whether [user] is the last active owner, who must not be deactivated.
  ///
  /// Checked here only to grey the button out and say why. The repository
  /// refuses it regardless, which is what actually protects the rule.
  bool _onlyActiveOwner(List<UserRow> users, UserRow user) {
    if (user.role != UserRole.owner) return false;
    return users.where((u) => u.isActive && u.role == UserRole.owner).length <=
        1;
  }

  Future<void> _resetPin(UserRow user) async {
    final session = ref.read(sessionProvider);
    final auth = await ref.read(authRepositoryProvider.future);
    if (session == null || auth == null || !mounted) return;

    final result = await showDialog<_ResetRequest>(
      context: context,
      builder: (_) => _ResetPinDialog(name: user.name),
    );
    if (result == null) return;

    try {
      // The owner's own PIN, first. Resetting someone else's is the one action
      // here that hands over the ability to sign in as them, so it is worth
      // the same re-entry the brief requires before cancelling a bill. This
      // counts towards the lockout, like every other PIN check.
      final ok = await auth.confirmPin(
        userId: session.userId,
        pin: result.ownerPin,
      );
      if (!ok) {
        _say('That is not your PIN. Nothing was changed.', bad: true);
        return;
      }

      await auth.resetPin(
        userId: user.id,
        newPin: result.newPin,
        byUserId: session.userId,
      );
      _say(
        '${user.name} can sign in with the new PIN. Ask them to change it '
        'to something only they know.',
      );
    } on PinError catch (e) {
      _say(e.message, bad: true);
    }
  }

  Future<void> _deactivate(UserRow user) async {
    final session = ref.read(sessionProvider);
    if (session == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDialog(
        title: 'Remove ${user.name}?',
        body: 'They will not appear on the sign-in screen. The bills they '
            'rang up keep their name. You can bring them back later.',
        confirmLabel: 'Remove',
        danger: true,
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(setupRepositoryProvider).deactivateUser(
            userId: user.id,
            byUserId: session.userId,
          );
      _say('${user.name} can no longer sign in.');
    } on SetupError catch (e) {
      _say(e.message, bad: true);
    }
  }

  Future<void> _reactivate(UserRow user) async {
    final session = ref.read(sessionProvider);
    if (session == null) return;

    try {
      await ref.read(setupRepositoryProvider).reactivateUser(
            userId: user.id,
            byUserId: session.userId,
          );
      _say('${user.name} can sign in again, with the PIN they had before.');
    } on SetupError catch (e) {
      _say(e.message, bad: true);
    }
  }

  Future<void> _clearLockout(UserRow user) async {
    final session = ref.read(sessionProvider);
    final auth = await ref.read(authRepositoryProvider.future);
    if (session == null || auth == null) return;

    try {
      await auth.clearLockout(userId: user.id, byUserId: session.userId);
      _say('${user.name} can try their PIN again.');
    } on PinError catch (e) {
      _say(e.message, bad: true);
    }
  }
}

// ---------------------------------------------------------------------------
// One person in the list.
// ---------------------------------------------------------------------------

class _StaffTile extends StatelessWidget {
  const _StaffTile({
    required this.user,
    required this.isSelf,
    required this.onlyOwner,
    required this.onResetPin,
    required this.onDeactivate,
    required this.onClearLockout,
  });

  final UserRow user;
  final bool isSelf;
  final bool onlyOwner;
  final VoidCallback onResetPin;
  final VoidCallback onDeactivate;
  final VoidCallback onClearLockout;

  @override
  Widget build(BuildContext context) {
    final locked = user.lockedUntil?.isAfter(DateTime.now()) ?? false;

    return Container(
      key: Key('staff-${user.id}'),
      margin: const EdgeInsets.only(bottom: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.medium),
        border: Border.all(color: AppColors.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  user.name,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AppColors.ink,
                  ),
                ),
              ),
              if (isSelf) const _Chip('You'),
              if (isSelf) const SizedBox(width: AppSpace.xs),
              _Chip(user.role == UserRole.owner ? 'Owner' : 'Cashier'),
            ],
          ),
          if (locked) ...[
            const SizedBox(height: AppSpace.sm),
            const Text(
              'Locked out after too many wrong PINs.',
              style: TextStyle(fontSize: 14, color: AppColors.dangerText),
            ),
          ],
          const SizedBox(height: AppSpace.sm),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: [
              if (locked)
                OutlinedButton(
                  key: Key('clear-lockout-${user.id}'),
                  onPressed: onClearLockout,
                  style: _tileButtonStyle,
                  child: const Text('Let them try again'),
                ),
              if (!isSelf)
                OutlinedButton(
                  key: Key('reset-pin-${user.id}'),
                  onPressed: onResetPin,
                  style: _tileButtonStyle,
                  child: const Text('Reset PIN'),
                ),
              if (!isSelf)
                OutlinedButton(
                  key: Key('deactivate-${user.id}'),
                  onPressed: onlyOwner ? null : onDeactivate,
                  style: _tileButtonStyle.copyWith(
                    foregroundColor: onlyOwner
                        ? null
                        : const WidgetStatePropertyAll(AppColors.danger),
                  ),
                  child: const Text('Remove'),
                ),
            ],
          ),
          if (isSelf) ...[
            const SizedBox(height: AppSpace.xs),
            const Text(
              'Your own PIN is changed with My PIN, which needs the PIN you '
              'have now.',
              style: TextStyle(fontSize: 14, color: AppColors.muted),
            ),
          ],
          if (onlyOwner && !isSelf) ...[
            const SizedBox(height: AppSpace.xs),
            const Text(
              'The last owner cannot be removed. Nobody would be able to '
              'reach settings or reports.',
              style: TextStyle(fontSize: 14, color: AppColors.muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _GoneTile extends StatelessWidget {
  const _GoneTile({required this.user, required this.onReactivate});

  final UserRow user;
  final VoidCallback onReactivate;

  @override
  Widget build(BuildContext context) => Container(
        key: Key('gone-${user.id}'),
        margin: const EdgeInsets.only(bottom: AppSpace.md),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(AppRadius.medium),
          border: Border.all(color: AppColors.borderSoft),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                user.name,
                style: const TextStyle(
                  fontSize: 17,
                  color: AppColors.muted,
                ),
              ),
            ),
            OutlinedButton(
              key: Key('reactivate-${user.id}'),
              onPressed: onReactivate,
              style: _tileButtonStyle,
              child: const Text('Bring back'),
            ),
          ],
        ),
      );
}

// ---------------------------------------------------------------------------
// Adding someone.
// ---------------------------------------------------------------------------

class _AddStaffCard extends ConsumerStatefulWidget {
  const _AddStaffCard({required this.onAdded, required this.onFailed});

  final void Function(String name) onAdded;
  final void Function(String message) onFailed;

  @override
  ConsumerState<_AddStaffCard> createState() => _AddStaffCardState();
}

class _AddStaffCardState extends ConsumerState<_AddStaffCard> {
  final _name = TextEditingController();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  UserRole _role = UserRole.staff;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final session = ref.read(sessionProvider);
    if (session == null) return;

    if (_pin.text != _confirm.text) {
      widget.onFailed('The two PINs do not match.');
      return;
    }

    setState(() => _busy = true);
    final name = _name.text.trim();

    try {
      await ref.read(setupRepositoryProvider).addUser(
            name: name,
            role: _role,
            pin: _pin.text,
            byUserId: session.userId,
          );
      if (!mounted) return;
      _name.clear();
      _pin.clear();
      _confirm.clear();
      setState(() {
        _role = UserRole.staff;
        _busy = false;
      });
      widget.onAdded(name);
    } on SetupError catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onFailed(e.message);
    }
  }

  @override
  Widget build(BuildContext context) => _Card(
        children: [
          const _CardTitle('Add someone'),
          const SizedBox(height: AppSpace.md),
          TextField(
            key: const Key('add-staff-name'),
            controller: _name,
            enabled: !_busy,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              Expanded(
                child: _RoleTile(
                  key: const Key('add-staff-role-staff'),
                  label: 'Cashier',
                  help: 'Bills and reprints',
                  selected: _role == UserRole.staff,
                  onTap: _busy
                      ? null
                      : () => setState(() => _role = UserRole.staff),
                ),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(
                child: _RoleTile(
                  key: const Key('add-staff-role-owner'),
                  label: 'Owner',
                  help: 'Everything, including reports',
                  selected: _role == UserRole.owner,
                  onTap: _busy
                      ? null
                      : () => setState(() => _role = UserRole.owner),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.md),
          _PinField(
            fieldKey: const Key('add-staff-pin'),
            controller: _pin,
            label: 'PIN',
            enabled: !_busy,
            helper: 'Four digits. Not 1111, not 1234.',
          ),
          const SizedBox(height: AppSpace.md),
          _PinField(
            fieldKey: const Key('add-staff-pin-confirm'),
            controller: _confirm,
            label: 'PIN again',
            enabled: !_busy,
          ),
          const SizedBox(height: AppSpace.md),
          FilledButton(
            key: const Key('add-staff-save'),
            onPressed: _busy ? null : _add,
            style: primaryActionStyle(),
            child: _busy
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Add to staff'),
          ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Dialogs.
// ---------------------------------------------------------------------------

/// What [_ResetPinDialog] collects: the new PIN, and the owner's own.
class _ResetRequest {
  const _ResetRequest({required this.newPin, required this.ownerPin});

  final String newPin;
  final String ownerPin;
}

class _ResetPinDialog extends StatefulWidget {
  const _ResetPinDialog({required this.name});

  final String name;

  @override
  State<_ResetPinDialog> createState() => _ResetPinDialogState();
}

class _ResetPinDialogState extends State<_ResetPinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  final _owner = TextEditingController();
  String? _problem;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    _owner.dispose();
    super.dispose();
  }

  void _submit() {
    if (_pin.text != _confirm.text) {
      setState(() => _problem = 'The two new PINs do not match.');
      return;
    }
    Navigator.of(context).pop(
      _ResetRequest(newPin: _pin.text, ownerPin: _owner.text),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Reset the PIN for ${widget.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Give ${widget.name} a PIN they can sign in with, then ask '
                'them to change it to something only they know.',
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: AppSpace.lg),
              _PinField(
                fieldKey: const Key('reset-pin-field'),
                controller: _pin,
                label: 'New PIN',
                helper: 'Four digits. Not 1111, not 1234.',
              ),
              const SizedBox(height: AppSpace.md),
              _PinField(
                fieldKey: const Key('reset-pin-confirm-field'),
                controller: _confirm,
                label: 'New PIN again',
              ),
              const Divider(height: AppSpace.xxl),
              _PinField(
                fieldKey: const Key('reset-pin-owner-field'),
                controller: _owner,
                label: 'Your own PIN',
                helper: 'So a till left unlocked cannot be used to take '
                    'over an account.',
              ),
              if (_problem != null) ...[
                const SizedBox(height: AppSpace.md),
                Text(
                  _problem!,
                  key: const Key('reset-pin-problem'),
                  style: const TextStyle(
                    fontSize: 15,
                    color: AppColors.dangerText,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('reset-pin-save'),
            onPressed: _submit,
            style: primaryActionStyle(),
            child: const Text('Reset PIN'),
          ),
        ],
      );
}

class _ConfirmDialog extends StatelessWidget {
  const _ConfirmDialog({
    required this.title,
    required this.body,
    required this.confirmLabel,
    this.danger = false,
  });

  final String title;
  final String body;
  final String confirmLabel;
  final bool danger;

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(title),
        content: Text(
          body,
          style: const TextStyle(
            fontSize: 15,
            height: 1.4,
            color: AppColors.muted,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            key: const Key('confirm-action'),
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: danger ? AppColors.danger : AppColors.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, AppTouch.comfortable),
            ),
            child: Text(confirmLabel),
          ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Small shared pieces.
// ---------------------------------------------------------------------------

class _PinField extends StatelessWidget {
  const _PinField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    this.helper,
    this.enabled = true,
  });

  /// On the TextField itself, not on this wrapper, so a test can read the
  /// controller off it the way the other settings tests do.
  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final String? helper;
  final bool enabled;

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

class _RoleTile extends StatelessWidget {
  const _RoleTile({
    super.key,
    required this.label,
    required this.help,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String help;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: selected ? AppColors.softGreen : AppColors.background,
        borderRadius: BorderRadius.circular(AppRadius.medium),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.medium),
          child: Container(
            constraints: const BoxConstraints(minHeight: AppTouch.comfortable),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.medium),
              border: Border.all(
                color: selected ? AppColors.primary : AppColors.borderSoft,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: selected ? AppColors.primary : AppColors.ink,
                  ),
                ),
                Text(
                  help,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.sm,
          vertical: AppSpace.xs,
        ),
        decoration: BoxDecoration(
          color: AppColors.softGreen,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.primary,
          ),
        ),
      );
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.bad});

  final String message;
  final bool bad;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('staff-message'),
        margin: const EdgeInsets.only(bottom: AppSpace.lg),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: bad ? AppColors.dangerBg : AppColors.softGreen,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Text(
          message,
          style: TextStyle(
            fontSize: 15,
            height: 1.4,
            color: bad ? AppColors.dangerText : AppColors.primary,
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

class _CardTitle extends StatelessWidget {
  const _CardTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.ink,
        ),
      );
}

class _OwnerOnly extends StatelessWidget {
  const _OwnerOnly();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          title: const Text('Staff'),
        ),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpace.xxl),
            child: Text(
              'Only the owner can manage staff.',
              style: TextStyle(fontSize: 17, color: AppColors.muted),
            ),
          ),
        ),
      );
}

final ButtonStyle _tileButtonStyle = OutlinedButton.styleFrom(
  minimumSize: const Size(0, AppTouch.min),
);
