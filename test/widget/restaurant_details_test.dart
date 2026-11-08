/// The Restaurant card in Settings.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/auth_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/outlet_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/features/settings/restaurant_details_section.dart';
import 'package:restaurant_pos/providers.dart';

import 'harness.dart';

void main() {
  late PosDatabase db;
  late String ownerId;
  late String staffId;

  setUp(() async {
    db = PosDatabase.memory();
    final setup = SetupRepository(db);
    final r = await setup.completeSetup(
      const SetupDetails(
        outletName: 'Annapurna Mess',
        address: 'Main Road',
        phone: '9000000000',
        fssaiNo: '12345678901234',
        taxMode: TaxMode.regular5,
        gstin: '37ABCDE1234F1Z5',
        ownerName: 'Ravi',
        ownerPin: '1357',
        devicePrefix: 'A',
      ),
      at: DateTime(2026, 4, 1, 10),
    );
    ownerId = r.ownerId;
    staffId = await setup.addUser(
      name: 'Kiran',
      role: UserRole.staff,
      pin: '2468',
      byUserId: ownerId,
    );
  });

  tearDown(() => db.close());

  Future<ProviderContainer> show(
    WidgetTester tester, {
    UserRole role = UserRole.owner,
    Size? size,
  }) async {
    final container = await pumpScreen(
      tester,
      db: db,
      size: size,
      child: const Scaffold(
        body: SingleChildScrollView(child: RestaurantDetailsSection()),
      ),
      before: (c) => c.read(sessionProvider.notifier).signIn(Session(
            userId: role == UserRole.owner ? ownerId : staffId,
            name: role == UserRole.owner ? 'Ravi' : 'Kiran',
            role: role,
            startedAt: DateTime(2026, 11, 8),
          )),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<OutletRow> outlet() => db.select(db.outlets).getSingle();

  String fieldText(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

  group('what it shows', () {
    testWidgets('the stored name, address and phone', (tester) async {
      await show(tester);
      expect(fieldText(tester, 'outlet-name-field'), 'Annapurna Mess');
      expect(fieldText(tester, 'outlet-address-field'), 'Main Road');
      expect(fieldText(tester, 'outlet-phone-field'), '9000000000');
    });

    testWidgets('Save is off until something is edited', (tester) async {
      await show(tester);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('save-restaurant')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('it says printed bills are not rewritten', (tester) async {
      // The thing an owner fixing a typo would otherwise worry about.
      await show(tester);
      expect(
        find.textContaining('keep the details they were printed with'),
        findsOneWidget,
      );
    });
  });

  group('saving', () {
    testWidgets('a corrected name', (tester) async {
      await show(tester);

      await tester.enterText(
        find.byKey(const Key('outlet-name-field')),
        'Annapurna Mess & Tiffins',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-restaurant')));
      await tester.pumpAndSettle();

      expect((await outlet()).name, 'Annapurna Mess & Tiffins');
      expect(find.text('Saved.'), findsOneWidget);
    });

    testWidgets('a new address and phone together', (tester) async {
      await show(tester);

      await tester.enterText(
        find.byKey(const Key('outlet-address-field')),
        'Shop 4, Main Road, Guntur',
      );
      await tester.enterText(
        find.byKey(const Key('outlet-phone-field')),
        '9888877777',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-restaurant')));
      await tester.pumpAndSettle();

      final o = await outlet();
      expect(o.address, 'Shop 4, Main Road, Guntur');
      expect(o.phone, '9888877777');
    });

    testWidgets('no confirmation dialog: this is not a tax change',
        (tester) async {
      await show(tester);
      await tester.enterText(
        find.byKey(const Key('outlet-name-field')),
        'Annapurna Mess & Tiffins',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-restaurant')));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('an empty name is refused and the stored one survives',
        (tester) async {
      await show(tester);

      await tester.enterText(find.byKey(const Key('outlet-name-field')), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-restaurant')));
      await tester.pumpAndSettle();

      expect(find.textContaining('needs a name'), findsOneWidget);
      expect((await outlet()).name, 'Annapurna Mess');
    });

    testWidgets('an empty address is refused', (tester) async {
      await show(tester);
      await tester.enterText(
        find.byKey(const Key('outlet-address-field')),
        '',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-restaurant')));
      await tester.pumpAndSettle();

      expect(find.textContaining('printed on every bill'), findsWidgets);
      expect((await outlet()).address, 'Main Road');
    });

    testWidgets('an over-long name is refused in words, not a crash',
        (tester) async {
      await show(tester);
      await tester.enterText(
        find.byKey(const Key('outlet-name-field')),
        'A' * (kOutletNameMaxLength + 5),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-restaurant')));
      await tester.pumpAndSettle();

      expect(find.textContaining('too long'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect((await outlet()).name, 'Annapurna Mess');
    });
  });

  group('permissions', () {
    testWidgets('staff cannot save', (tester) async {
      await show(tester, role: UserRole.staff);

      await tester.enterText(
        find.byKey(const Key('outlet-name-field')),
        'Not Annapurna',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-restaurant')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Only the owner'), findsOneWidget);
      expect((await outlet()).name, 'Annapurna Mess');
    });
  });

  group('the rest of the app notices', () {
    testWidgets('the outlet provider carries the new name', (tester) async {
      final container = await show(tester);
      container.listen(outletProvider, (_, _) {}, fireImmediately: true);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('outlet-name-field')),
        'Annapurna Mess & Tiffins',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('save-restaurant')));
      await tester.pumpAndSettle();

      expect(
        container.read(outletProvider).value!.name,
        'Annapurna Mess & Tiffins',
        reason: 'without a restart',
      );
    });
  });

  group('layout', () {
    testWidgets('a phone does not overflow', (tester) async {
      await show(tester, size: const Size(390, 3000));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow phone does not overflow', (tester) async {
      await show(tester, size: const Size(320, 3000));
      expect(tester.takeException(), isNull);
    });
  });
}
