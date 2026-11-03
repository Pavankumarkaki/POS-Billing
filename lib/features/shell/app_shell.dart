/// The navigation shell: a rail on a tablet, a bottom bar on a phone.
///
/// From the canvas's shared Rail artboard. Destinations the signed-in user may
/// not reach are not shown at all, rather than shown and refused: staff have no
/// business seeing a Reports tab they cannot open.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/domain.dart';
import '../../providers.dart';
import '../../theme/app_theme.dart';
import '../billing/billing_screen.dart';
import '../menu/menu_screen.dart';

/// A place the shell can show, and who may go there.
enum Destination {
  billing('Billing', Icons.receipt_long_outlined, null),
  bills('Bills', Icons.list_alt_outlined, null),
  menu('Menu', Icons.restaurant_menu_outlined, Permission.editMenu),
  reports('Reports', Icons.bar_chart_outlined, Permission.viewReports),
  settings('Settings', Icons.tune_outlined, Permission.changeSettings);

  const Destination(this.label, this.icon, this.permission);

  final String label;
  final IconData icon;

  /// Null means everyone. Otherwise the permission needed to see the tab.
  final Permission? permission;

  bool visibleTo(UserRole role) =>
      permission == null || permission!.allows(role);
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  Destination _current = Destination.billing;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (session == null) return const SizedBox.shrink();

    final visible = Destination.values
        .where((d) => d.visibleTo(session.role))
        .toList(growable: false);

    // A role change, or landing on a tab that is no longer visible, must not
    // strand the user on a blank screen.
    if (!visible.contains(_current)) {
      _current = visible.first;
    }

    final body = switch (_current) {
      Destination.menu => const MenuScreen(),
      Destination.billing => const BillingScreen(),
      Destination.bills => const _Placeholder(
          title: 'Bills',
          note: 'Today\'s bills, cancel and reprint arrive in milestone 8.',
        ),
      Destination.reports => const _Placeholder(
          title: 'Reports',
          note: 'Day, week and month reports arrive in milestone 9.',
        ),
      Destination.settings => const _Placeholder(
          title: 'Settings',
          note: 'Printer and tax settings arrive alongside milestone 7.',
        ),
    };

    if (isTablet(context)) {
      return Scaffold(
        body: Row(
          children: [
            _Rail(
              destinations: visible,
              current: _current,
              onSelect: (d) => setState(() => _current = d),
              onLock: () => ref.read(sessionProvider.notifier).signOut(),
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      body: body,
      bottomNavigationBar: _BottomBar(
        destinations: visible,
        current: _current,
        onSelect: (d) => setState(() => _current = d),
        onLock: () => ref.read(sessionProvider.notifier).signOut(),
      ),
    );
  }
}

/// The 88px green rail from the canvas.
class _Rail extends StatelessWidget {
  const _Rail({
    required this.destinations,
    required this.current,
    required this.onSelect,
    required this.onLock,
  });

  final List<Destination> destinations;
  final Destination current;
  final ValueChanged<Destination> onSelect;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      color: AppColors.primary,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm,
        vertical: AppSpace.md,
      ),
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            for (final d in destinations) ...[
              _RailButton(
                destination: d,
                selected: d == current,
                onTap: () => onSelect(d),
              ),
              const SizedBox(height: 6),
            ],
            const Spacer(),
            _RailButton(
              destination: null,
              selected: false,
              onTap: onLock,
              label: 'Lock',
              icon: Icons.lock_outline,
            ),
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.destination,
    required this.selected,
    required this.onTap,
    this.label,
    this.icon,
  });

  final Destination? destination;
  final bool selected;
  final VoidCallback onTap;
  final String? label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final text = label ?? destination!.label;
    final glyph = icon ?? destination!.icon;

    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.medium),
        child: Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: AppTouch.large),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.medium),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                glyph,
                size: 24,
                color: selected ? AppColors.primary : Colors.white,
              ),
              const SizedBox(height: 3),
              Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? AppColors.primary : Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.destinations,
    required this.current,
    required this.onSelect,
    required this.onLock,
  });

  final List<Destination> destinations;
  final Destination current;
  final ValueChanged<Destination> onSelect;
  final VoidCallback onLock;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.primary,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: AppTouch.large,
          child: Row(
            children: [
              for (final d in destinations)
                Expanded(
                  child: _BottomButton(
                    label: d.label,
                    icon: d.icon,
                    selected: d == current,
                    onTap: () => onSelect(d),
                  ),
                ),
              Expanded(
                child: _BottomButton(
                  label: 'Lock',
                  icon: Icons.lock_outline,
                  selected: false,
                  onTap: onLock,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomButton extends StatelessWidget {
  const _BottomButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 22,
              color: selected ? AppColors.accent : Colors.white,
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? AppColors.accent : Colors.white,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends ConsumerWidget {
  const _Placeholder({required this.title, required this.note});

  final String title;
  final String note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outlet = ref.watch(outletProvider).value;
    final session = ref.watch(sessionProvider);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        title: Text(outlet?.name ?? title),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: AppSpace.sm),
              Text(
                note,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 17, color: AppColors.muted),
              ),
              const SizedBox(height: AppSpace.xl),
              Text(
                'Signed in as ${session?.name ?? ''}'
                ' · ${session?.role == UserRole.owner ? 'Owner' : 'Staff'}',
                style: const TextStyle(fontSize: 15, color: AppColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
