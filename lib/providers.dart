/// The object graph, wired with Riverpod.
///
/// Flutter note for a Go developer: this file is what you would write by hand
/// in a Go `main()` — construct the database, hand it to the repositories, hand
/// those to whatever needs them. Riverpod adds two things: each provider builds
/// its value lazily and once, and a test can override any provider with a fake
/// without touching the code that depends on it.
///
/// Deliberately written by hand rather than generated. The brief's reader is
/// new to Flutter, and one less code generator is one less thing to debug when
/// a build goes wrong.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/domain.dart';
import 'data/auth_repository.dart';
import 'data/bill_repository.dart';
import 'data/db.dart';
import 'data/setup_repository.dart';

/// The database. One per app run.
///
/// Overridden in tests with `PosDatabase.memory()`, which is why nothing below
/// constructs a database itself.
final databaseProvider = Provider<PosDatabase>((ref) {
  final db = PosDatabase.open();
  ref.onDispose(db.close);
  return db;
});

/// Setup can run before there is a device or an outlet, so it depends on
/// nothing but the database.
final setupRepositoryProvider = Provider<SetupRepository>(
  (ref) => SetupRepository(ref.watch(databaseProvider)),
);

/// Whether first-run setup has been completed. The app routes on this.
final isConfiguredProvider = FutureProvider<bool>(
  (ref) => ref.watch(setupRepositoryProvider).isConfigured(),
);

/// This device's row. Null before setup.
final deviceProvider = FutureProvider<DeviceRow?>(
  (ref) => ref.watch(databaseProvider).select(
        ref.watch(databaseProvider).devices,
      ).getSingleOrNull(),
);

/// The outlet. Null before setup.
final outletProvider = FutureProvider<OutletRow?>(
  (ref) => ref.watch(databaseProvider).select(
        ref.watch(databaseProvider).outlets,
      ).getSingleOrNull(),
);

/// Auth needs the device id, for the audit log.
///
/// Returns null before setup, because there is no device to attribute a
/// sign-in to and nobody to sign in as.
final authRepositoryProvider = FutureProvider<AuthRepository?>((ref) async {
  final device = await ref.watch(deviceProvider.future);
  if (device == null) return null;
  return AuthRepository(ref.watch(databaseProvider), deviceId: device.id);
});

final billRepositoryProvider = Provider<BillRepository>(
  (ref) => BillRepository(ref.watch(databaseProvider)),
);

/// Everyone who may be offered on the login screen.
final activeUsersProvider = FutureProvider<List<UserRow>>((ref) async {
  final auth = await ref.watch(authRepositoryProvider.future);
  if (auth == null) return const [];
  return auth.activeUsers();
});

/// Who is signed in, or null.
///
/// Memory only, on purpose: closing the app signs you out. A till left on a
/// counter should not stay signed in as the owner.
final sessionProvider = NotifierProvider<SessionNotifier, Session?>(
  SessionNotifier.new,
);

class SessionNotifier extends Notifier<Session?> {
  @override
  Session? build() => null;

  void signIn(Session session) => state = session;

  void signOut() => state = null;
}

/// Whether the signed-in user may do something.
///
/// Returns false when nobody is signed in, so a screen that forgets to check
/// for a session fails closed rather than open.
bool can(Ref ref, Permission permission) {
  final session = ref.watch(sessionProvider);
  if (session == null) return false;
  return session.can(permission);
}
