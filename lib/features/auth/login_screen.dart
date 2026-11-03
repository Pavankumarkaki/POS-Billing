/// PIN login. Two layouts from the design canvas: a phone with the keypad on a
/// white sheet over green, and a tablet with the users on the left and the
/// keypad in a panel on the right.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/domain.dart';
import '../../data/auth_repository.dart';
import '../../data/db.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';
import 'pin_keypad.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  String? _selectedUserId;
  String _pin = '';
  String? _message;
  bool _busy = false;

  void _digit(String d) {
    if (_pin.length >= 4) return;
    setState(() {
      _pin += d;
      _message = null;
    });
    // Four digits in: submit without making them reach for another button.
    if (_pin.length == 4) _submit();
  }

  /// Picking a user clears whatever was half-typed for the previous one.
  void selectUser(String userId) => setState(() {
        _selectedUserId = userId;
        _pin = '';
        _message = null;
      });

  void _clear() => setState(() {
        _pin = '';
        _message = null;
      });

  void _backspace() {
    if (_pin.isEmpty) return;
    setState(() {
      _pin = _pin.substring(0, _pin.length - 1);
      _message = null;
    });
  }

  Future<void> _submit() async {
    final userId = _selectedUserId;
    if (userId == null || _pin.length != 4 || _busy) return;

    setState(() => _busy = true);

    final auth = await ref.read(authRepositoryProvider.future);
    if (auth == null) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'This device is not set up yet.';
        });
      }
      return;
    }

    final result = await auth.signIn(userId: userId, pin: _pin);
    if (!mounted) return;

    if (result.ok) {
      ref.read(sessionProvider.notifier).signIn(Session(
            userId: result.userId!,
            name: result.name!,
            role: result.role!,
            startedAt: DateTime.now(),
          ));
      return;
    }

    setState(() {
      _busy = false;
      _pin = '';
      _message = switch (result.failure!) {
        LoginFailure.wrongPin =>
          'Wrong PIN. ${result.attemptsRemaining} ${result.attemptsRemaining == 1 ? 'try' : 'tries'} left.',
        LoginFailure.lockedOut => 'Locked for ${_humanise(result.lockedFor!)}.',
        LoginFailure.unknownUser => 'That user cannot sign in.',
      };
    });
  }

  static String _humanise(Duration d) {
    if (d.inMinutes >= 1) {
      final m = d.inMinutes + (d.inSeconds % 60 > 0 ? 1 : 0);
      return '$m ${m == 1 ? 'minute' : 'minutes'}';
    }
    final s = d.inSeconds < 1 ? 1 : d.inSeconds;
    return '$s ${s == 1 ? 'second' : 'seconds'}';
  }

  @override
  Widget build(BuildContext context) {
    final usersAsync = ref.watch(activeUsersProvider);
    final outletAsync = ref.watch(outletProvider);
    final outletName = outletAsync.value?.name ?? '';

    return Scaffold(
      backgroundColor: AppColors.primary,
      body: usersAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
        error: (e, _) => _Message(text: 'Could not load users.\n$e'),
        data: (users) {
          if (users.isEmpty) {
            return const _Message(
              text: 'No active users. Set the app up again to add an owner.',
            );
          }
          // Preselect when there is only one person who could be billing.
          _selectedUserId ??= users.length == 1 ? users.first.id : null;

          return SafeArea(
            child: isTablet(context)
                ? _TabletLayout(
                    outletName: outletName,
                    users: users,
                    state: this,
                  )
                : _PhoneLayout(
                    outletName: outletName,
                    users: users,
                    state: this,
                  ),
          );
        },
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
        ),
      );
}

/// Phone: green header with the user picker, white sheet with the keypad.
class _PhoneLayout extends StatelessWidget {
  const _PhoneLayout({
    required this.outletName,
    required this.users,
    required this.state,
  });

  final String outletName;
  final List<UserRow> users;
  final _LoginScreenState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.xl,
            AppSpace.xxl,
            AppSpace.xl,
            AppSpace.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                outletName.isEmpty ? 'Billing' : outletName,
                style: Theme.of(context)
                    .textTheme
                    .displaySmall
                    ?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: AppSpace.sm),
              const Text(
                'Who is billing? · ఎవరు బిల్లింగ్ చేస్తున్నారు?',
                style: TextStyle(color: Colors.white, fontSize: 17),
              ),
              const SizedBox(height: AppSpace.md),
              _UserPicker(users: users, state: state, columns: 2),
            ],
          ),
        ),
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(AppRadius.sheet),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(
              AppSpace.xl,
              AppSpace.xxl,
              AppSpace.xl,
              AppSpace.xl,
            ),
            child: _PinPanel(state: state, compact: true),
          ),
        ),
      ],
    );
  }
}

/// Tablet: users on the green left, keypad in a white panel on the right.
class _TabletLayout extends StatelessWidget {
  const _TabletLayout({
    required this.outletName,
    required this.users,
    required this.state,
  });

  final String outletName;
  final List<UserRow> users;
  final _LoginScreenState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(64),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  outletName.isEmpty ? 'Billing' : outletName,
                  style: Theme.of(context)
                      .textTheme
                      .displayLarge
                      ?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: AppSpace.md),
                const Text(
                  'Who is billing today?',
                  style: TextStyle(color: Colors.white, fontSize: 22),
                ),
                const Text(
                  'ఈ రోజు బిల్లింగ్ ఎవరు చేస్తున్నారు?',
                  style: TextStyle(color: Colors.white, fontSize: 22),
                ),
                const SizedBox(height: AppSpace.xxl),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: _UserPicker(users: users, state: state, columns: 1),
                ),
              ],
            ),
          ),
        ),
        Container(
          width: 520,
          color: AppColors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 56, vertical: 40),
          child: _PinPanel(state: state, compact: false),
        ),
      ],
    );
  }
}

/// The list of people who could be billing.
class _UserPicker extends StatelessWidget {
  const _UserPicker({
    required this.users,
    required this.state,
    required this.columns,
  });

  final List<UserRow> users;
  final _LoginScreenState state;
  final int columns;

  @override
  Widget build(BuildContext context) {
    Widget tile(UserRow u) {
      final selected = state._selectedUserId == u.id;
      return OutlinedButton(
        onPressed: () => state.selectUser(u.id),
        style: OutlinedButton.styleFrom(
          backgroundColor: selected ? Colors.white : AppColors.primary,
          foregroundColor: selected ? AppColors.primary : Colors.white,
          side: const BorderSide(color: Colors.white, width: 2),
          minimumSize: Size(0, columns == 1 ? AppTouch.primary : 72),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.large),
          ),
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
        ),
        child: columns == 1
            ? Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    u.name,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    _roleLabel(u.role),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    u.name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _roleLabel(u.role),
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
      );
    }

    if (columns == 1) {
      return Column(
        children: [
          for (final u in users) ...[
            if (u != users.first) const SizedBox(height: AppSpace.sm),
            SizedBox(width: double.infinity, child: tile(u)),
          ],
        ],
      );
    }

    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: [
        for (final u in users)
          SizedBox(
            width: (MediaQuery.sizeOf(context).width - AppSpace.xl * 2 - AppSpace.sm) / 2,
            child: tile(u),
          ),
      ],
    );
  }

  static String _roleLabel(UserRole role) =>
      role == UserRole.owner ? 'Owner' : 'Staff';
}

/// The prompt, the dots, the keypad and the status message.
class _PinPanel extends StatelessWidget {
  const _PinPanel({required this.state, required this.compact});

  final _LoginScreenState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ready = state._selectedUserId != null;

    return Column(
      children: [
        Text(
          ready ? 'Enter your 4-digit PIN' : 'Choose who is billing',
          style: TextStyle(
            fontSize: compact ? 18 : 20,
            fontWeight: FontWeight.w600,
            color: AppColors.ink,
          ),
        ),
        const SizedBox(height: AppSpace.md),
        PinDots(entered: state._pin.length, size: compact ? 18 : 20),
        const SizedBox(height: AppSpace.md),

        // Reserve the row whether or not there is a message, so the keypad
        // does not jump when one appears. A keypad that moves under a thumb
        // mid-entry is how wrong PINs get typed.
        SizedBox(
          height: 40,
          child: Center(
            child: state._message == null
                ? const SizedBox.shrink()
                : Text(
                    state._message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.dangerText,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ),

        if (compact)
          Expanded(
            child: PinKeypad(
              onDigit: state._digit,
              onClear: state._clear,
              onBackspace: state._backspace,
              enabled: ready && !state._busy,
            ),
          )
        else
          PinKeypad(
            onDigit: state._digit,
            onClear: state._clear,
            onBackspace: state._backspace,
            enabled: ready && !state._busy,
            fontSize: 30,
            spacing: 10,
            rowHeight: 84,
          ),

        const SizedBox(height: AppSpace.lg),
        const Text(
          'Works without internet',
          style: TextStyle(fontSize: 15, color: AppColors.muted),
        ),
      ],
    );
  }
}
