/// The root widget and the only routing decision in the app so far.
///
/// Three states, decided by data rather than by navigation history:
///   not set up      -> setup
///   set up, no user -> login
///   signed in       -> home
///
/// Deliberately not a router. There are no URLs, no deep links and no back
/// stack worth preserving: the app is a till. Routing on state means signing
/// out cannot leave a billing screen behind on the stack.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/auth/login_screen.dart';
import 'features/setup/setup_screen.dart';
import 'features/shell/app_shell.dart';
import 'providers.dart';
import 'theme/app_theme.dart';

class PosApp extends StatelessWidget {
  const PosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Billing',
      theme: buildAppTheme(),
      debugShowCheckedModeBanner: false,
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = ref.watch(isConfiguredProvider);

    return configured.when(
      loading: () => const _Splash(),
      error: (e, _) => _Fatal(error: e),
      data: (isConfigured) {
        if (!isConfigured) return const SetupScreen();
        final session = ref.watch(sessionProvider);
        if (session == null) return const LoginScreen();
        return const AppShell();
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) => const Scaffold(
        backgroundColor: AppColors.primary,
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
}

/// The database could not be opened. Shown rather than crashing, because a
/// crash at the till tells the owner nothing they can act on.
class _Fatal extends StatelessWidget {
  const _Fatal({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 48,
                  color: AppColors.danger,
                ),
                const SizedBox(height: AppSpace.md),
                Text(
                  'The app could not open its records.',
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppSpace.sm),
                const Text(
                  'Nothing has been lost. Restart the app, and if this keeps '
                  'happening, restore from your most recent backup.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: AppColors.muted),
                ),
                const SizedBox(height: AppSpace.lg),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: AppColors.muted),
                ),
              ],
            ),
          ),
        ),
      );
}
