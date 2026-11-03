/// Rendering a receipt to a bitmap, and the fake printer.
///
/// These need a Flutter binding because the renderer uses dart:ui, which is
/// the whole point: Telugu shaping and the rupee sign come from the real text
/// engine, not from a printer font.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader;

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/core/business_date.dart';
import 'package:restaurant_pos/core/domain.dart';
import 'package:restaurant_pos/core/invoice_no.dart';
import 'package:restaurant_pos/core/money.dart';
import 'package:restaurant_pos/core/receipt.dart';
import 'package:restaurant_pos/core/tax.dart';
import 'package:restaurant_pos/printing/esc_pos.dart';
import 'package:restaurant_pos/printing/fake_printer.dart';
import 'package:restaurant_pos/printing/png.dart';
import 'package:restaurant_pos/printing/printer.dart';
import 'package:restaurant_pos/printing/qr.dart';
import 'package:restaurant_pos/printing/receipt_renderer.dart';
import 'package:restaurant_pos/theme/app_theme.dart';

/// Renders inside [WidgetTester.runAsync].
///
/// `Picture.toImage` and `Image.toByteData` do real asynchronous work on the
/// engine. A widget test runs on a fake clock that never pumps it, so calling
/// them directly hangs forever rather than failing. This is the one place that
/// matters, so it is wrapped once here.
Future<MonoBitmap> render(
  WidgetTester tester,
  ReceiptDoc doc, {
  int width = 576,
}) async {
  final bmp = await tester.runAsync(() => renderReceipt(doc, width: width));
  expect(bmp, isNotNull, reason: 'renderReceipt returned nothing');
  return bmp!;
}

ReceiptDoc sampleDoc({
  TaxMode mode = TaxMode.regular5,
  bool duplicate = false,
  bool telugu = true,
  String longName = 'Chicken Dum Biryani',
  String? upi,
}) {
  final bill = computeBill(
    cart: [
      CartLine(
        itemId: 'a',
        nameSnapshot: longName,
        nameTeSnapshot: 'చికెన్ దమ్ బిర్యానీ',
        unitPrice: Paise.fromRupees(240),
        qty: 2,
        taxClass: TaxClass.gst5,
      ),
      CartLine(
        itemId: 'b',
        nameSnapshot: 'Buttermilk',
        nameTeSnapshot: 'మజ్జిగ',
        unitPrice: Paise.fromRupees(30),
        qty: 1,
        taxClass: TaxClass.gst5,
      ),
    ],
    config: TaxConfig(mode: mode, pricesIncludeTax: false),
    orderType: OrderType.dine,
  );

  return buildReceipt(
    outlet: ReceiptOutlet(
      name: 'Annapurna Mess',
      address: 'Main Road, Vijayawada, Andhra Pradesh 520001',
      phone: '9000000000',
      fssaiNo: '12345678901234',
      taxMode: mode,
      gstin: mode == TaxMode.regular5 ? '37ABCDE1234F1Z5' : null,
      billFooter: 'Thank you, come again',
      upiVpa: upi,
    ),
    bill: bill,
    invoiceNo: InvoiceNo.build(
      devicePrefix: 'A',
      fy: const FinancialYear(2026),
      seq: 123,
    ),
    at: DateTime(2026, 11, 2, 14, 35),
    businessDate: const BusinessDate(2026, 11, 2),
    lines: [
      ReceiptLine(
        name: longName,
        nameTe: telugu ? 'చికెన్ దమ్ బిర్యానీ' : null,
        qty: 2,
        unitPrice: const Paise(24000),
        lineTotal: const Paise(48000),
      ),
      ReceiptLine(
        name: 'Buttermilk',
        nameTe: telugu ? 'మజ్జిగ' : null,
        qty: 1,
        unitPrice: const Paise(3000),
        lineTotal: const Paise(3000),
      ),
    ],
    payments: [(mode: PaymentMode.cash, amount: bill.total)],
    cashierName: 'Ravi',
    duplicate: duplicate,
    showTelugu: telugu,
  );
}

void main() {
  // flutter test does NOT load fonts from pubspec. Without this, Telugu falls
  // back to a test font that draws every glyph as an identical box: the
  // receipt renders, but what it proves about Telugu is nothing.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final bytes = File('assets/fonts/AnekTelugu-Variable.ttf').readAsBytesSync();
    final loader = FontLoader(kFontFamily)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  });

  group('rendering', () {
    testWidgets('produces a bitmap of the requested width', (tester) async {
      final bmp = await render(tester, sampleDoc(), width: 576);
      expect(bmp.width, 576);
      expect(bmp.height, greaterThan(200));
      expect(bmp.bytesPerRow, 72, reason: '576 dots is 72 whole bytes');
      expect(bmp.bits.length, bmp.bytesPerRow * bmp.height);
    });

    testWidgets('actually has ink on it', (tester) async {
      final bmp = await render(tester, sampleDoc(), width: 576);
      // A blank receipt is the failure this catches: everything else can look
      // right while the canvas never got drawn.
      expect(bmp.inkCoverage, greaterThan(0.01));
      expect(bmp.inkCoverage, lessThan(0.5),
          reason: 'a mostly black receipt means the threshold is inverted');
    });

    testWidgets('a 58 mm printer gets a narrower receipt, not a clipped one',
        (tester) async {
      final wide = await render(tester, sampleDoc(), width: 576);
      final narrow = await render(tester, sampleDoc(), width: 384);

      expect(narrow.width, 384);
      expect(narrow.inkCoverage, greaterThan(0.01));
      // Text scales down, so the receipt stays a similar shape rather than
      // getting much taller from wrapping.
      expect(narrow.height, lessThan(wide.height * 1.6));
    });

    testWidgets('a very long item name wraps instead of being cut off',
        (tester) async {
      final normal = await render(tester, sampleDoc(), width: 576);
      final long = await render(tester, sampleDoc(
          longName: 'Special Hyderabadi Gongura Mutton Dum Biryani Family '
              'Pack With Extra Raita And Mirchi Ka Salan',
        ), width: 576);
      expect(
        long.height,
        greaterThan(normal.height),
        reason: 'a name that does not fit must wrap, not vanish',
      );
    });

    testWidgets('Telugu adds height, which means it rendered', (tester) async {
      final withTe = await render(tester, sampleDoc(telugu: true), width: 576);
      final without = await render(tester, sampleDoc(telugu: false), width: 576);
      expect(withTe.height, greaterThan(without.height));
      expect(withTe.inkCoverage, greaterThan(without.inkCoverage));
    });

    testWidgets('a reprint is taller, because DUPLICATE is on it',
        (tester) async {
      final original = await render(tester, sampleDoc(), width: 576);
      final copy = await render(tester, sampleDoc(duplicate: true), width: 576);
      expect(copy.height, greaterThan(original.height));
    });

    testWidgets('a UPI QR renders as a dense square', (tester) async {
      final without = await render(tester, sampleDoc(), width: 576);
      final withQr = await render(tester, sampleDoc(upi: 'annapurna@okaxis'), width: 576);
      expect(withQr.height, greaterThan(without.height + 150));
      expect(
        withQr.blackPixels,
        greaterThan(without.blackPixels),
        reason: 'compare dots, not coverage: a QR adds more quiet zone than '
            'ink, so the RATIO falls even though the dot count rises',
      );
    });

    testWidgets('every tax mode renders without error', (tester) async {
      for (final mode in TaxMode.values) {
        final bmp = await render(tester, sampleDoc(mode: mode), width: 576);
        expect(bmp.inkCoverage, greaterThan(0.01), reason: '$mode');
      }
    });
  });

  group('the QR matrix', () {
    test('includes a quiet zone on every side', () {
      final m = QrMatrix.encode('upi://pay?pa=x@y&am=252.00');
      expect(m.size, greaterThan(QrMatrix.quietZone * 2));
      for (var i = 0; i < m.size; i++) {
        expect(m.isDark(0, i), isFalse, reason: 'top row must be light');
        expect(m.isDark(i, 0), isFalse, reason: 'left column must be light');
        expect(m.isDark(m.size - 1, i), isFalse);
      }
    });

    test('has the finder patterns, so it is a real QR', () {
      final m = QrMatrix.encode('hello');
      const q = QrMatrix.quietZone;
      // The top-left finder is a 7x7 ring: dark border, light inner ring.
      expect(m.isDark(q, q), isTrue);
      expect(m.isDark(q + 1, q + 1), isFalse);
      expect(m.isDark(q + 3, q + 3), isTrue, reason: 'the 3x3 centre');
    });

    test('longer data needs a bigger matrix', () {
      final small = QrMatrix.encode('x');
      final big = QrMatrix.encode('x' * 200);
      expect(big.size, greaterThan(small.size));
    });
  });

  group('ESC/POS bytes', () {
    late MonoBitmap bmp;

    setUpAll(() {
      bmp = MonoBitmap(
        width: 16,
        height: 8,
        bits: Uint8List.fromList([for (var i = 0; i < 16; i++) 0xFF]),
      );
    });

    test('a job starts with the reset command', () {
      final bytes = EscPos.job(bmp, const PrinterConfig());
      expect(bytes[0], 0x1B);
      expect(bytes[1], 0x40, reason: 'ESC @ puts the printer in a known state');
    });

    test('GS v 0 carries the right dimensions', () {
      final bytes = EscPos.rasterGsV0(bmp);
      expect(bytes[0], 0x1D);
      expect(bytes[1], 0x76);
      expect(bytes[2], 0x30);
      expect(bytes[4], 2, reason: '16 dots is 2 bytes per row');
      expect(bytes[6], 8, reason: '8 rows');
    });

    test('a tall bitmap is sent in strips, not one huge command', () {
      final tall = MonoBitmap(
        width: 16,
        height: 400,
        bits: Uint8List.fromList(List.filled(2 * 400, 0xFF)),
      );
      final bytes = EscPos.rasterGsV0(tall, stripHeight: 128);
      // Four GS v 0 headers for 400 rows at 128 per strip.
      var headers = 0;
      for (var i = 0; i + 2 < bytes.length; i++) {
        if (bytes[i] == 0x1D && bytes[i + 1] == 0x76 && bytes[i + 2] == 0x30) {
          headers++;
        }
      }
      expect(headers, greaterThanOrEqualTo(4),
          reason: 'one command for a long receipt overflows cheap printers');
    });

    test('auto-cut appends the cut command', () {
      final cut = EscPos.job(bmp, const PrinterConfig());
      final noCut =
          EscPos.job(bmp, const PrinterConfig(autoCut: false));
      expect(cut.sublist(cut.length - 4), containsAllInOrder([0x1D, 0x56]));
      expect(noCut.sublist(noCut.length - 3), containsAllInOrder([0x1B, 0x64]),
          reason: 'without a cutter it must still feed clear of the tear bar');
    });

    test('the ESC * fallback produces different bytes', () {
      final modern = EscPos.job(bmp, const PrinterConfig());
      final legacy =
          EscPos.job(bmp, const PrinterConfig(useEscStar: true));
      expect(legacy, isNot(modern));
      expect(legacy.sublist(2, 5), containsAllInOrder([0x1B, 0x33, 24]));
    });
  });

  group('the fake printer', () {
    late Directory dir;
    late FakePrinter printer;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('pos-receipts');
      printer = FakePrinter(directory: dir);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    testWidgets('writes a PNG you can open', (tester) async {
      final bmp = await render(tester, sampleDoc(), width: 576);
      final result = (await tester.runAsync(() => printer.printBitmap(
            bmp,
            config: const PrinterConfig(),
            jobName: 'A/2627/000123',
          )))!;

      expect(result.ok, isTrue);
      expect(result.artefactPath, isNotNull);

      final png = File(result.artefactPath!);
      expect(png.existsSync(), isTrue);
      expect(png.path, endsWith('receipt-A_2627_000123.png'),
          reason: 'slashes are not valid in a file name');

      final bytes = png.readAsBytesSync();
      expect(bytes.sublist(0, 8),
          containsAllInOrder([137, 80, 78, 71, 13, 10, 26, 10]),
          reason: 'a real PNG signature');
      expect(bytes.length, greaterThan(1000));
    });

    testWidgets('writes the raw printer bytes alongside it', (tester) async {
      final bmp = await render(tester, sampleDoc(), width: 576);
      await tester.runAsync(() => printer.printBitmap(
            bmp,
            config: const PrinterConfig(),
            jobName: 'A/2627/000123',
          ));

      final bin = File('${dir.path}/receipt-A_2627_000123.bin');
      expect(bin.existsSync(), isTrue);
      final bytes = bin.readAsBytesSync();
      expect(bytes[0], 0x1B);
      expect(bytes[1], 0x40);
    });

    testWidgets('a forced failure reports it and writes nothing',
        (tester) async {
      final bmp = await render(tester, sampleDoc(), width: 576);
      printer.failNext = true;

      final result = (await tester.runAsync(() => printer.printBitmap(
            bmp,
            config: const PrinterConfig(),
            jobName: 'A/2627/000999',
          )))!;

      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
      expect(File('${dir.path}/receipt-A_2627_000999.png').existsSync(),
          isFalse);
    });

    testWidgets('and the next job after a failure still works', (tester) async {
      final bmp = await render(tester, sampleDoc(), width: 576);
      printer.failNext = true;
      await tester.runAsync(
        () => printer.printBitmap(bmp, config: const PrinterConfig()),
      );

      final retry = (await tester.runAsync(() => printer.printBitmap(
            bmp,
            config: const PrinterConfig(),
            jobName: 'retry',
          )))!;
      expect(retry.ok, isTrue,
          reason: 'the brief requires a retry to be possible');
    });
  });

  group('the PNG encoder', () {
    test('round trips a known pattern', () {
      // A 8x2 bitmap: first row all black, second all white.
      final bmp = MonoBitmap(
        width: 8,
        height: 2,
        bits: Uint8List.fromList([0xFF, 0x00]),
      );
      final png = encodeMonoPng(bmp);

      expect(png.sublist(0, 8),
          containsAllInOrder([137, 80, 78, 71, 13, 10, 26, 10]));
      // IHDR says 8 wide, 2 tall, bit depth 1, colour type 0.
      expect(png[16], 0);
      expect(png[19], 8, reason: 'width');
      expect(png[23], 2, reason: 'height');
      expect(png[24], 1, reason: 'bit depth');
      expect(png[25], 0, reason: 'greyscale');
    });

    test('ends with IEND', () {
      final bmp =
          MonoBitmap(width: 8, height: 1, bits: Uint8List.fromList([0xAA]));
      final png = encodeMonoPng(bmp);
      // An IEND chunk is length(4) + type(4) + CRC(4), so the type sits 8
      // bytes from the end, not 4.
      final tail = png.sublist(png.length - 12);
      expect(tail.sublist(4, 8), [73, 69, 78, 68], reason: 'IEND');
    });
  });
}
