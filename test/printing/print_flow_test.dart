/// Printing a saved bill, the queue, and the rule that a printer failure must
/// never lose a bill.
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/data/bill_repository.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/data/menu_repository.dart';
import 'package:restaurant_pos/data/setup_repository.dart';
import 'package:restaurant_pos/printing/fake_printer.dart';
import 'package:restaurant_pos/printing/print_queue.dart';
import 'package:restaurant_pos/printing/print_service.dart';
import 'package:restaurant_pos/core/receipt.dart';

void main() {
  late PosDatabase db;
  late Directory dir;
  late FakePrinter printer;
  late PrintService service;
  late String ownerId;
  late String deviceId;
  late String itemId;

  setUp(() async {
    db = PosDatabase.memory();
    dir = Directory.systemTemp.createTempSync('pos-print-flow');
    printer = FakePrinter(directory: dir);
    service = PrintService(db, printer: printer);

    final setup = SetupRepository(db);
    final r = await setup.completeSetup(const SetupDetails(
      outletName: 'Annapurna Mess',
      address: 'Main Road, Vijayawada',
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

    final menu = MenuRepository(db, deviceId: deviceId);
    final cat =
        await menu.createCategory(nameEn: 'Biryani', byUserId: ownerId);
    itemId = await menu.createItem(
      categoryId: cat,
      nameEn: 'Chicken Dum Biryani',
      nameTe: 'చికెన్ దమ్ బిర్యానీ',
      price: Paise.fromRupees(240),
      taxClass: TaxClass.gst5,
      byUserId: ownerId,
    );
  });

  tearDown(() async {
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<SavedBill> sell({int qty = 1}) async {
    final computed = computeBill(
      cart: [
        CartLine(
          itemId: itemId,
          nameSnapshot: 'Chicken Dum Biryani',
          nameTeSnapshot: 'చికెన్ దమ్ బిర్యానీ',
          unitPrice: Paise.fromRupees(240),
          qty: qty,
          taxClass: TaxClass.gst5,
        ),
      ],
      config: const TaxConfig(
        mode: TaxMode.regular5,
        pricesIncludeTax: false,
      ),
      orderType: OrderType.dine,
    );
    return BillRepository(db).commitSale(
      computed: computed,
      payments: [PaymentIntent(PaymentMode.cash, computed.total)],
      deviceId: deviceId,
      userId: ownerId,
    );
  }

  group('printing a saved bill', () {
    testWidgets('writes a receipt named after the invoice', (tester) async {
      final saved = await sell();
      final result =
          (await tester.runAsync(() => service.printBill(saved.id)))!;

      expect(result.ok, isTrue, reason: result.error);
      expect(
        File('${dir.path}/receipt-A_2627_000001.png').existsSync(),
        isTrue,
      );
    });

    testWidgets('the receipt is built from the stored snapshots',
        (tester) async {
      final saved = await sell(qty: 2);

      // Change the menu after the sale. The receipt must not follow it.
      final menu = MenuRepository(db, deviceId: deviceId);
      await menu.updateItem(
        id: itemId,
        nameEn: 'Renamed Entirely',
        price: Paise.fromRupees(999),
        byUserId: ownerId,
      );

      final doc =
          (await tester.runAsync(() => service.buildDocFor(saved.id)))!;

      final names = <String>[];
      for (final b in doc.blocks) {
        if (b is ItemRowBlock) names.add(b.name);
      }
      expect(names, contains('Chicken Dum Biryani'));
      expect(names, isNot(contains('Renamed Entirely')));
    });

    testWidgets('a reprint is marked DUPLICATE', (tester) async {
      final saved = await sell();
      final doc = (await tester.runAsync(
        () => service.buildDocFor(saved.id, duplicate: true),
      ))!;

      final first = doc.blocks.first;
      expect(first, isA<TextLine>());
      expect((first as TextLine).text, 'DUPLICATE');
    });

    testWidgets('a cancelled bill prints as cancelled, with its number',
        (tester) async {
      final saved = await sell();
      await BillRepository(db).cancelBill(
        billId: saved.id,
        reason: 'Wrong item entered',
        userId: ownerId,
        deviceId: deviceId,
      );

      final doc = (await tester.runAsync(
        () => service.buildDocFor(saved.id, duplicate: true),
      ))!;
      final texts = [
        for (final b in doc.blocks)
          if (b is TextLine) b.text,
      ];
      expect(texts, contains('CANCELLED'));
      expect(texts.join(), contains('Wrong item entered'));
    });

    testWidgets('an unknown bill fails cleanly', (tester) async {
      final result =
          (await tester.runAsync(() => service.printBill('nope')))!;
      expect(result.ok, isFalse);
      expect(result.error, contains('could not be found'));
    });
  });

  group('a printer failure never loses a bill', () {
    testWidgets('the bill survives, with its number and amounts',
        (tester) async {
      final saved = await sell();
      printer.failNext = true;

      final result =
          (await tester.runAsync(() => service.printBill(saved.id)))!;
      expect(result.ok, isFalse);

      final row = await db.select(db.bills).getSingle();
      expect(row.invoiceNo, 'A/2627/000001');
      expect(row.total.value, saved.computed.total.value);
      expect(row.status, BillStatus.paid);
      expect(await db.select(db.billLines).get(), hasLength(1));
      expect(await db.select(db.payments).get(), hasLength(1));
    });

    testWidgets('a retry then succeeds', (tester) async {
      final saved = await sell();
      printer.failNext = true;

      final first =
          (await tester.runAsync(() => service.printBill(saved.id)))!;
      expect(first.ok, isFalse);

      final retry =
          (await tester.runAsync(() => service.printBill(saved.id)))!;
      expect(retry.ok, isTrue, reason: 'the brief requires a retry to work');
      expect(
        File('${dir.path}/receipt-A_2627_000001.png').existsSync(),
        isTrue,
      );
    });

    testWidgets('the next sale is unaffected and takes the next number',
        (tester) async {
      final first = await sell();
      printer.failNext = true;
      await tester.runAsync(() => service.printBill(first.id));

      final second = await sell();
      expect(second.invoiceNo.formatted, 'A/2627/000002',
          reason: 'a printer problem must not disturb the series');

      final ok =
          (await tester.runAsync(() => service.printBill(second.id)))!;
      expect(ok.ok, isTrue);
    });
  });

  group('the queue', () {
    test('runs jobs one at a time, in order', () async {
      final queue = PrintQueue();
      final order = <int>[];
      var concurrent = 0;
      var maxConcurrent = 0;

      Future<void> job(int n, Duration d) => queue.add(() async {
            concurrent++;
            maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
            await Future<void>.delayed(d);
            order.add(n);
            concurrent--;
          });

      // Deliberately out of duration order: if they overlapped, the short one
      // would finish first and the order would be wrong.
      final futures = [
        job(1, const Duration(milliseconds: 30)),
        job(2, const Duration(milliseconds: 1)),
        job(3, const Duration(milliseconds: 10)),
      ];
      await Future.wait(futures);

      expect(order, [1, 2, 3]);
      expect(maxConcurrent, 1,
          reason: 'two writes to a thermal printer corrupt one receipt');
    });

    test('a failed job does not block the ones behind it', () async {
      final queue = PrintQueue();
      final done = <String>[];

      final bad = queue.add<void>(() async {
        throw StateError('printer on fire');
      });
      final good = queue.add<void>(() async => done.add('after'));

      await expectLater(bad, throwsA(isA<StateError>()));
      await good;

      expect(done, ['after'],
          reason: 'one bad receipt must not block the next sale');
    });

    test('reports whether it is busy', () async {
      final queue = PrintQueue();
      expect(queue.isBusy, isFalse);

      final job = queue.add(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      expect(queue.isBusy, isTrue);
      await job;
      await queue.drain();
      expect(queue.isBusy, isFalse);
    });
  });

  group('the test page', () {
    testWidgets('prints, and exercises Telugu and the rupee sign',
        (tester) async {
      final result =
          (await tester.runAsync(() => service.printTestPage()))!;
      expect(result.ok, isTrue, reason: result.error);
      expect(File('${dir.path}/receipt-test-page.png').existsSync(), isTrue);
    });
  });

  group('printer configuration', () {
    testWidgets('defaults apply when nothing is stored', (tester) async {
      final config = await service.printerConfig();
      expect(config.widthPx, 576);
      expect(config.autoCut, isTrue);
      expect(config.useEscStar, isFalse);
    });

    testWidgets('a stored config is read back', (tester) async {
      await (db.update(db.devices)..where((d) => d.id.equals(deviceId)))
          .write(const DevicesCompanion(
        printerCfg: Value(
          '{"kind":"fake","address":"","width_px":384,'
          '"auto_cut":false,"use_esc_star":true,"port":9100}',
        ),
      ));

      final config = await service.printerConfig();
      expect(config.widthPx, 384);
      expect(config.autoCut, isFalse);
      expect(config.useEscStar, isTrue);
    });

    testWidgets('a corrupt config falls back to defaults rather than failing',
        (tester) async {
      await (db.update(db.devices)..where((d) => d.id.equals(deviceId)))
          .write(const DevicesCompanion(
        printerCfg: Value('not json at all'),
      ));

      final config = await service.printerConfig();
      expect(config.widthPx, 576,
          reason: 'a bad setting must not stop the restaurant billing');
    });
  });
}
