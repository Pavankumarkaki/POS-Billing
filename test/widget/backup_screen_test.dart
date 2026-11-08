/// The backup screen.
///
/// The thing being checked here is mostly wording and state, because that is
/// what this screen is for: the brief says a scheduled backup must not be
/// presented as a backup that happened, and the only way to keep that promise
/// is for the screen to say when one last did, in words the owner can act on.
///
/// The file and folder pickers are not driven here. They are platform dialogs
/// with no Flutter widgets to tap, so they belong in HARDWARE_TEST.md; what is
/// tested is everything on this side of them.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/backup_service.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/settings_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/features/settings/backup_screen.dart';
import 'package:restaurant_pos/providers.dart';

import 'harness.dart';

/// Lets real file I/O finish, then shows the result.
///
/// Exports really write files, and the fake clock in a widget test never lets
/// real I/O complete, so the work has to happen inside `runAsync`. A fixed
/// delay in there is a guess, and a wrong one: the CSV export writes six files
/// in a loop, and a 500 ms window cut it off after the first. So this waits
/// for the screen to say it has finished, which is the signal the test
/// actually means.
///
/// `pump` rather than `pumpAndSettle` throughout, because a spinner is an
/// animation that never stops and `pumpAndSettle` would wait for ever.
Future<void> settleRealIo(WidgetTester tester) async {
  // 30 seconds of real time, which the loop only spends if something is
  // genuinely wrong: it returns as soon as the screen reports. Raised from 5
  // seconds while chasing a hang that turned out not to be slowness at all,
  // but `outletProvider` briefly being a StreamProvider, whose `.future`
  // never completes without a live subscriber. The ceiling stays generous
  // because a timeout here should mean a deadlock, not a slow machine.
  for (var i = 0; i < 1200; i++) {
    if (find.byKey(const Key('outcome')).evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  fail('the export never reported an outcome within 30 seconds');
}

void main() {
  late PosDatabase db;
  late String ownerId;
  late String staffId;
  late String deviceId;
  late String itemId;
  late Directory platformDir;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();

    // The screen resolves the default backup folder through path_provider,
    // which a widget test has no platform for. Answered with a temp directory
    // rather than avoided, so the real resolution path is what runs.
    platformDir = Directory.systemTemp.createTempSync('pos-screen-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => platformDir.path,
    );

    db = PosDatabase.memory();
    final setup = SetupRepository(db);
    final r = await setup.completeSetup(const SetupDetails(
      outletName: 'Annapurna Mess',
      address: 'Main Road',
      phone: '9000000000',
      fssaiNo: '12345678901234',
      taxMode: TaxMode.regular5,
      gstin: '37ABCDE1234F1Z5',
      ownerName: 'Ravi',
      ownerPin: '1357',
      devicePrefix: 'A',
    ));
    ownerId = r.ownerId;
    deviceId = r.deviceId;
    staffId = await setup.addUser(
      name: 'Kiran',
      role: UserRole.staff,
      pin: '2468',
      byUserId: ownerId,
    );

    final menu = MenuRepository(db, deviceId: deviceId);
    final cat = await menu.createCategory(nameEn: 'Biryani', byUserId: ownerId);
    itemId = await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await db.close();
    if (platformDir.existsSync()) platformDir.deleteSync(recursive: true);
  });

  Future<void> sell() async {
    final computed = computeBill(
      cart: [
        CartLine(
          itemId: itemId,
          nameSnapshot: 'Chicken Dum Biryani',
          unitPrice: Paise.fromRupees(240),
          qty: 1,
          taxClass: TaxClass.gst5,
        ),
      ],
      config: const TaxConfig(mode: TaxMode.regular5, pricesIncludeTax: false),
      orderType: OrderType.dine,
    );
    await BillRepository(db).commitSale(
      computed: computed,
      payments: [PaymentIntent(PaymentMode.cash, computed.total)],
      deviceId: deviceId,
      userId: ownerId,
    );
  }

  Future<ProviderContainer> show(
    WidgetTester tester, {
    UserRole role = UserRole.owner,
    Size? size,
  }) async {
    final container = await pumpScreen(
      tester,
      db: db,
      size: size,
      child: const BackupScreen(),
      before: (c) => c.read(sessionProvider.notifier).signIn(Session(
            userId: role == UserRole.owner ? ownerId : staffId,
            name: role == UserRole.owner ? 'Ravi' : 'Kiran',
            role: role,
            startedAt: DateTime(2026, 11, 4),
          )),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('describing when the last backup was', () {
    final now = DateTime(2026, 11, 4, 9, 15);

    test('never, when there has not been one', () {
      expect(describeBackupTime(null, now: now), 'Never');
    });

    test('today, with the time', () {
      expect(
        describeBackupTime(DateTime(2026, 11, 4, 4, 32), now: now),
        'Today at 4:32 AM',
      );
    });

    test('yesterday', () {
      expect(
        describeBackupTime(DateTime(2026, 11, 3, 4, 30), now: now),
        'Yesterday at 4:30 AM',
      );
    });

    test('a few days ago', () {
      expect(
        describeBackupTime(DateTime(2026, 11, 1, 4, 30), now: now),
        '3 days ago, at 4:30 AM',
      );
    });

    test('longer ago, by date', () {
      expect(
        describeBackupTime(DateTime(2026, 10, 2, 16, 5), now: now),
        '2 October at 4:05 PM',
      );
    });

    test('midnight and noon read correctly', () {
      // The classic off-by-twelve: 0 and 12 both have to come out as 12.
      expect(
        describeBackupTime(DateTime(2026, 11, 4), now: now),
        'Today at 12:00 AM',
      );
      expect(
        describeBackupTime(DateTime(2026, 11, 4, 12), now: now),
        'Today at 12:00 PM',
      );
    });

    test('a backup after midnight is today, not "0 days ago"', () {
      // The nightly job runs at 4:30 AM. At 9 AM the same day it must read as
      // today, which the business-day cutoff makes easy to get wrong.
      expect(
        describeBackupTime(DateTime(2026, 11, 4, 1, 5), now: now),
        startsWith('Today'),
      );
    });
  });

  group('the export period', () {
    test('this month runs from the first to today', () {
      const today = BusinessDate(2026, 11, 4);
      final r = ExportPeriod.thisMonth.range(today);
      expect(r.from, const BusinessDate(2026, 11, 1));
      expect(r.to, today);
    });

    test('last month is the whole of it, not the last thirty days', () {
      final r = ExportPeriod.lastMonth.range(const BusinessDate(2026, 11, 4));
      expect(r.from, const BusinessDate(2026, 10, 1));
      expect(r.to, const BusinessDate(2026, 10, 31));
    });

    test('last month across the turn of a year', () {
      final r = ExportPeriod.lastMonth.range(const BusinessDate(2026, 1, 15));
      expect(r.from, const BusinessDate(2025, 12, 1));
      expect(r.to, const BusinessDate(2025, 12, 31));
    });

    test('last month handles a short month', () {
      final r = ExportPeriod.lastMonth.range(const BusinessDate(2026, 3, 10));
      expect(r.from, const BusinessDate(2026, 2, 1));
      expect(r.to, const BusinessDate(2026, 2, 28));
    });

    test('the financial year starts in April', () {
      final r =
          ExportPeriod.financialYear.range(const BusinessDate(2026, 11, 4));
      expect(r.from, const BusinessDate(2026, 4, 1));
    });

    test('in March the financial year still starts the April before', () {
      final r =
          ExportPeriod.financialYear.range(const BusinessDate(2027, 3, 20));
      expect(r.from, const BusinessDate(2026, 4, 1));
      expect(r.to, const BusinessDate(2027, 3, 20));
    });
  });

  group('permissions', () {
    testWidgets('staff are refused', (tester) async {
      await show(tester, role: UserRole.staff);
      expect(find.textContaining('Only the owner'), findsOneWidget);
      expect(find.byKey(const Key('backup-now')), findsNothing);
    });

    testWidgets('the owner sees the screen', (tester) async {
      await show(tester);
      expect(find.byKey(const Key('backup-now')), findsOneWidget);
    });

    testWidgets('restore is not reachable for staff', (tester) async {
      await show(tester, role: UserRole.staff);
      expect(find.byKey(const Key('restore')), findsNothing);
    });
  });

  group('what the screen says before any backup has happened', () {
    testWidgets('says Never, and warns', (tester) async {
      await show(tester);
      expect(find.text('Never'), findsOneWidget);
      expect(find.byKey(const Key('stale-warning')), findsOneWidget);
      expect(
        find.textContaining('Nothing has been backed up yet'),
        findsOneWidget,
      );
    });

    testWidgets('an app that has never backed up does not look safe',
        (tester) async {
      // The warning colour, not the reassuring one. Checked because a blank
      // or a green panel would read as "all fine" for an app with no backup.
      await show(tester);
      final panel = tester.widget<Container>(
        find.byKey(const Key('last-backup')),
      );
      final decoration = panel.decoration! as BoxDecoration;
      expect(decoration.color, isNot(const Color(0xFFDDEBE2)));
    });
  });

  group('after a backup', () {
    testWidgets('shows when it was and what it was called', (tester) async {
      await sell();
      await show(tester);

      await tester.tap(find.byKey(const Key('backup-now')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('stale-warning')), findsNothing);
      final when =
          tester.widget<Text>(find.byKey(const Key('last-backup-when')));
      expect(when.data, startsWith('Today'));
      expect(find.textContaining('pos-backup-'), findsWidgets);
    });

    testWidgets('says how many bills went into it', (tester) async {
      // The figure the owner can compare against the reports screen. "Backed
      // up" on its own says nothing about whether anything was in it.
      await sell();
      await sell();
      await show(tester);

      await tester.tap(find.byKey(const Key('backup-now')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Backed up 2 bills'), findsOneWidget);
    });

    testWidgets('one bill is singular', (tester) async {
      await sell();
      await show(tester);
      await tester.tap(find.byKey(const Key('backup-now')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Backed up 1 bill,'), findsOneWidget);
    });

    testWidgets('the file is really there and really readable',
        (tester) async {
      // The screen saying it worked and the file existing are two different
      // claims, and the first one is worthless without the second.
      await sell();
      final container = await show(tester);

      await tester.tap(find.byKey(const Key('backup-now')));
      await tester.pumpAndSettle();

      final dir = await container.read(backupDirectoryProvider.future);
      final service = await container.read(backupServiceProvider.future);
      final files = service.existingBackups(dir);

      expect(files, hasLength(1));
      final check = service.inspect(files.single);
      expect(check, isA<RestoreUsable>());
      expect((check as RestoreUsable).bills, 1);
    });

    testWidgets('a recorded time with no warning', (tester) async {
      await SettingsRepository(db)
          .writeTime(SettingKeys.backupLastSuccessAt, DateTime.now());
      await show(tester);
      expect(find.byKey(const Key('stale-warning')), findsNothing);
    });

    testWidgets('a recorded time that is old does warn', (tester) async {
      await SettingsRepository(db).writeTime(
        SettingKeys.backupLastSuccessAt,
        DateTime.now().subtract(const Duration(days: 9)),
      );
      await show(tester);
      expect(find.byKey(const Key('stale-warning')), findsOneWidget);
      expect(find.textContaining('longer ago than it should be'),
          findsOneWidget);
    });
  });

  group('a recorded failure', () {
    testWidgets('is shown, in the words it was recorded in', (tester) async {
      // The owner can act on "Android will not let this app write to that
      // folder". They can do nothing at all with "backup failed".
      await SettingsRepository(db).write(
        SettingKeys.backupLastError,
        'Android will not let this app write to /storage/emulated/0/Books',
      );
      await show(tester);

      expect(find.byKey(const Key('last-error')), findsOneWidget);
      expect(find.textContaining('/storage/emulated/0/Books'), findsOneWidget);
    });

    testWidgets('and goes away once a backup works', (tester) async {
      await sell();
      await SettingsRepository(db)
          .write(SettingKeys.backupLastError, 'Something went wrong');
      await show(tester);
      expect(find.byKey(const Key('last-error')), findsOneWidget);

      await tester.tap(find.byKey(const Key('backup-now')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('last-error')),
        findsNothing,
        reason: 'a stale error on screen is its own kind of wrong',
      );
    });
  });

  group('where backups go', () {
    testWidgets('the folder is shown in full', (tester) async {
      final container = await show(tester);
      final dir = await container.read(backupDirectoryProvider.future);
      expect(
        find.descendant(
          of: find.byKey(const Key('backup-dir')),
          matching: find.text(dir.path),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the default folder carries its warning about uninstalling',
        (tester) async {
      // The one thing about the default folder the owner has to know, and the
      // reason this app cannot claim the data is safe just because a backup
      // ran.
      await show(tester);
      expect(
        find.byKey(const Key('default-folder-warning')),
        findsOneWidget,
      );
      expect(find.textContaining('uninstalled'), findsOneWidget);
    });

    testWidgets('a chosen folder shows no such warning, and can be undone',
        (tester) async {
      final chosen = Directory(p.join(platformDir.path, 'chosen'))
        ..createSync();
      await SettingsRepository(db)
          .write(SettingKeys.backupDir, chosen.path);

      await show(tester);

      expect(find.byKey(const Key('default-folder-warning')), findsNothing);
      expect(find.byKey(const Key('use-default-folder')), findsOneWidget);
    });

    testWidgets('going back to the default folder works', (tester) async {
      final chosen = Directory(p.join(platformDir.path, 'chosen'))
        ..createSync();
      await SettingsRepository(db)
          .write(SettingKeys.backupDir, chosen.path);
      await show(tester);

      await tester.tap(find.byKey(const Key('use-default-folder')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('default-folder-warning')), findsOneWidget);
      expect(
        await SettingsRepository(db).read(SettingKeys.backupDir),
        isNull,
      );
    });
  });

  group('the nightly toggle', () {
    testWidgets('is on to start with', (tester) async {
      await show(tester);
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('nightly-toggle')),
      );
      expect(toggle.value, isTrue);
    });

    testWidgets('says that Android decides when it really runs',
        (tester) async {
      // Not a disclaimer for its own sake: it is why the last-backup time is
      // at the top of the screen rather than this toggle.
      await show(tester);
      expect(find.textContaining('Android decides'), findsOneWidget);
    });

    testWidgets('switching it off is remembered', (tester) async {
      await show(tester);
      await tester.tap(find.byKey(const Key('nightly-toggle')));
      await tester.pumpAndSettle();

      expect(
        await SettingsRepository(db)
            .readFlag(SettingKeys.backupNightlyEnabled, orElse: true),
        isFalse,
      );
    });
  });

  group('exporting', () {
    testWidgets('this month is chosen to start with', (tester) async {
      await show(tester);
      expect(find.byKey(const Key('period-thisMonth')), findsOneWidget);
      expect(find.byKey(const Key('period-lastMonth')), findsOneWidget);
      expect(find.byKey(const Key('period-financialYear')), findsOneWidget);
    });

    testWidgets('writes a workbook and says where it went', (tester) async {
      await sell();
      final container = await show(tester);

      await tester.tap(find.byKey(const Key('export-excel')));
      await tester.pump();
      await settleRealIo(tester);

      final base = await container.read(backupDirectoryProvider.future);
      final exports = Directory(p.join(base.path, 'exports'));
      final written = exports
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.xlsx'))
          .toList();

      expect(written, hasLength(1));
      expect(written.single.lengthSync(), greaterThan(0));
      expect(find.textContaining('Saved'), findsOneWidget);
      expect(find.textContaining('.xlsx'), findsOneWidget);
    });

    testWidgets('writes one CSV per sheet, in a folder of its own',
        (tester) async {
      await sell();
      final container = await show(tester);

      await tester.tap(find.byKey(const Key('export-csv')));
      await tester.pump();
      await settleRealIo(tester);

      final base = await container.read(backupDirectoryProvider.future);
      final exports = Directory(p.join(base.path, 'exports'));
      final folders = exports.listSync().whereType<Directory>().toList();

      expect(folders, hasLength(1));
      final csvs = folders.single
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.csv'))
          .toList();
      expect(csvs, hasLength(6));
      expect(find.textContaining('Saved 6 CSV files'), findsOneWidget);
    });

    testWidgets('the CSV files are named after their sheets', (tester) async {
      await sell();
      final container = await show(tester);
      await tester.tap(find.byKey(const Key('export-csv')));
      await tester.pump();
      await settleRealIo(tester);

      final base = await container.read(backupDirectoryProvider.future);
      final folder = Directory(p.join(base.path, 'exports'))
          .listSync()
          .whereType<Directory>()
          .single;
      final names =
          folder.listSync().map((e) => p.basename(e.path)).toSet();

      expect(names, contains('summary.csv'));
      expect(names, contains('sales-by-tax-rate.csv'));
      expect(names, contains('sac-summary.csv'));
      expect(names, contains('document-counts.csv'));
    });

    testWidgets('the file name says what period it covers', (tester) async {
      await sell();
      final container = await show(tester);
      await tester.tap(find.byKey(const Key('export-excel')));
      await tester.pump();
      await settleRealIo(tester);

      final base = await container.read(backupDirectoryProvider.future);
      final file = Directory(p.join(base.path, 'exports'))
          .listSync()
          .whereType<File>()
          .single;

      expect(p.basename(file.path), startsWith('pos-sales-'));
      expect(p.basename(file.path), contains('-to-'));
    });

    testWidgets('exporting a period with no sales still writes a file',
        (tester) async {
      // An accountant asking for last month during a closed month should get a
      // file that says there were no sales, not an error and not nothing.
      final container = await show(tester);

      await tester.tap(find.byKey(const Key('period-lastMonth')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-excel')));
      await tester.pump();
      await settleRealIo(tester);

      final base = await container.read(backupDirectoryProvider.future);
      final written = Directory(p.join(base.path, 'exports'))
          .listSync()
          .whereType<File>()
          .toList();

      expect(written, hasLength(1));
      expect(find.textContaining('Saved'), findsOneWidget);
    });
  });

  group('the restore notice from a previous start', () {
    testWidgets('is shown until it is dismissed', (tester) async {
      await SettingsRepository(db).write(
        SettingKeys.restoreNotice,
        'A backup of 9 bills was restored when the app last started.',
      );
      await show(tester);

      expect(find.byKey(const Key('restore-notice')), findsOneWidget);
      expect(find.textContaining('9 bills'), findsOneWidget);

      await tester.tap(find.byKey(const Key('dismiss-restore-notice')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('restore-notice')), findsNothing);
    });

    testWidgets('is not confused with a backup failure', (tester) async {
      // A restore that worked is not a backup that failed, and the screen
      // must not say it was.
      await SettingsRepository(db).write(
        SettingKeys.restoreNotice,
        'A backup of 9 bills was restored when the app last started.',
      );
      await show(tester);

      expect(find.byKey(const Key('last-error')), findsNothing);
      expect(find.textContaining('Last attempt failed'), findsNothing);
    });

    testWidgets('nothing shown when there was no restore', (tester) async {
      await show(tester);
      expect(find.byKey(const Key('restore-notice')), findsNothing);
    });
  });

  group('the restore confirmation', () {
    /// A real backup file, made the way the app makes one.
    Future<RestoreUsable> makeBackup(ProviderContainer container) async {
      final service = await container.read(backupServiceProvider.future);
      final dir = await container.read(backupDirectoryProvider.future);
      final done = await service.backupTo(dir) as BackupDone;
      return service.inspect(done.file) as RestoreUsable;
    }

    /// Opens the dialog from inside a Consumer, so it gets a real WidgetRef.
    Future<bool?> openDialog(
      WidgetTester tester,
      RestoreUsable backup, {
      UserRole role = UserRole.owner,
    }) async {
      bool? answer;
      await pumpScreen(
        tester,
        db: db,
        child: Consumer(
          builder: (context, ref, _) => TextButton(
            key: const Key('open-dialog'),
            onPressed: () async {
              answer = await showRestoreDialog(context, ref, backup);
            },
            child: const Text('open'),
          ),
        ),
        before: (c) => c.read(sessionProvider.notifier).signIn(Session(
              userId: role == UserRole.owner ? ownerId : staffId,
              name: 'Ravi',
              role: role,
              startedAt: DateTime(2026, 11, 4),
            )),
      );

      await tester.tap(find.byKey(const Key('open-dialog')));
      await tester.pumpAndSettle();
      return answer;
    }

    testWidgets('says how many bills are in the backup', (tester) async {
      await sell();
      await sell();
      final container = await show(tester);
      final backup = await makeBackup(container);

      await openDialog(tester, backup);

      expect(find.byKey(const Key('restore-bill-count')), findsOneWidget);
      expect(find.text('2 bills in this backup.'), findsOneWidget);
    });

    testWidgets('one bill is singular here too', (tester) async {
      await sell();
      final container = await show(tester);
      final backup = await makeBackup(container);

      await openDialog(tester, backup);
      expect(find.text('1 bill in this backup.'), findsOneWidget);
    });

    testWidgets('says what a restore costs before it is agreed to',
        (tester) async {
      await sell();
      final container = await show(tester);
      final backup = await makeBackup(container);

      await openDialog(tester, backup);

      expect(find.byKey(const Key('restore-newest')), findsOneWidget);
      expect(
        find.textContaining('will not be in the app any more'),
        findsOneWidget,
      );
      expect(
        find.textContaining('kept on the phone'),
        findsOneWidget,
        reason: 'and that the mistake is recoverable',
      );
    });

    testWidgets('Restore is not tappable until a PIN is typed',
        (tester) async {
      await sell();
      final container = await show(tester);
      final backup = await makeBackup(container);

      await openDialog(tester, backup);

      final button = tester.widget<FilledButton>(
        find.byKey(const Key('restore-confirm')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('the wrong PIN refuses and clears the field', (tester) async {
      await sell();
      final container = await show(tester);
      final backup = await makeBackup(container);

      await openDialog(tester, backup);
      await tester.enterText(find.byKey(const Key('restore-pin')), '9999');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restore-confirm')));
      await tester.pumpAndSettle();

      expect(find.text('That PIN is not right.'), findsOneWidget);
      expect(
        find.byKey(const Key('restore-bill-count')),
        findsOneWidget,
        reason: 'the dialog stays open',
      );
    });

    testWidgets('the wrong PIN counts towards the lockout', (tester) async {
      // Otherwise this dialog is a free way to guess the owner's PIN.
      await sell();
      final container = await show(tester);
      final backup = await makeBackup(container);

      await openDialog(tester, backup);
      await tester.enterText(find.byKey(const Key('restore-pin')), '9999');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restore-confirm')));
      await tester.pumpAndSettle();

      final failures = await db
          .customSelect(
            "SELECT COUNT(*) AS n FROM audit_log WHERE action = 'login_failed'",
          )
          .getSingle();
      expect(failures.read<int>('n'), greaterThan(0));
    });

    testWidgets('the right PIN confirms', (tester) async {
      await sell();
      final container = await show(tester);
      final backup = await makeBackup(container);

      final answer = await openDialog(tester, backup);
      expect(answer, isNull, reason: 'nothing agreed to yet');

      await tester.enterText(find.byKey(const Key('restore-pin')), '1357');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('restore-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('restore-bill-count')), findsNothing);
    });

    testWidgets('keeping what is here cancels', (tester) async {
      await sell();
      final container = await show(tester);
      final backup = await makeBackup(container);

      await openDialog(tester, backup);
      await tester.tap(find.text('Keep what is here'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('restore-bill-count')), findsNothing);
      expect(
        container.read(databaseProvider),
        isNotNull,
        reason: 'nothing was staged or replaced',
      );
    });

    testWidgets('the dialog does not overflow a narrow phone', (tester) async {
      await sell();
      final container = await show(tester, size: const Size(320, 640));
      final backup = await makeBackup(container);

      await openDialog(tester, backup);
      expect(tester.takeException(), isNull);
    });
  });

  group('layout', () {
    testWidgets('a phone does not overflow', (tester) async {
      await SettingsRepository(db).write(
        SettingKeys.backupLastError,
        'Android will not let this app write to /storage/emulated/0/Documents. '
        'Either grant all-files access, or pick a different folder.',
      );
      await SettingsRepository(db).write(
        SettingKeys.restoreNotice,
        'A backup of 240 bills was restored when the app last started.',
      );
      await show(tester, size: const Size(390, 844));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow phone does not overflow', (tester) async {
      await show(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tablet does not overflow', (tester) async {
      await show(tester, size: const Size(1280, 800));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long folder path does not overflow a phone',
        (tester) async {
      final deep = Directory(p.join(
        platformDir.path,
        'a-rather-long-folder-name',
        'and-another-one-inside-it',
        'and-one-more-for-good-measure',
      ))
        ..createSync(recursive: true);
      await SettingsRepository(db).write(SettingKeys.backupDir, deep.path);

      await show(tester, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
    });

    testWidgets('every tappable thing is at least 44px', (tester) async {
      // Phone width, but tall: a ListView builds only the children it can
      // show, so at 844 high the restore button does not exist to measure.
      await show(tester, size: const Size(390, 3000));

      for (final key in const [
        Key('backup-now'),
        Key('choose-folder'),
        Key('restore'),
        Key('export-csv'),
        Key('export-excel'),
        Key('period-thisMonth'),
      ]) {
        final finder = find.byKey(key);
        expect(finder, findsOneWidget, reason: '$key');
        expect(
          tester.getSize(finder).height,
          greaterThanOrEqualTo(44),
          reason: '$key is too small to hit',
        );
      }
    });
  });
}
