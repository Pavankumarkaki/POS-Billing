/// A printer that writes files instead of burning paper.
///
/// Required by the definition of done: the fake printer writes the receipt
/// bitmap to a file you can open and look at. It is also how the billing flow
/// is tested end to end without hardware, and how a receipt can be checked
/// before the real printer arrives.
///
/// Writes two files per job:
///   `receipt-A_2627_000123.png`  the bitmap, as you would see it on paper
///   `receipt-A_2627_000123.bin`  the exact bytes a real printer would receive
///
/// The `.bin` matters more than it looks. When a real printer misbehaves, the
/// question is always whether the app sent the wrong bytes or the printer
/// mishandled the right ones, and this answers it.
library;

import 'dart:io';
import 'dart:typed_data';

import 'esc_pos.dart';
import 'png.dart';
import 'printer.dart';

class FakePrinter implements Printer {
  FakePrinter({required this.directory, this.failNext = false});

  /// Where the files go. The app points this at its documents directory;
  /// tests point it at a temporary one.
  final Directory directory;

  /// Makes the next job fail, so the failure path can be exercised without
  /// unplugging anything. The brief requires a printer failure never to lose a
  /// bill, and that is hard to test with a printer that always works.
  bool failNext;

  @override
  PrinterKind get kind => PrinterKind.fake;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  /// Every job written so far, newest last. Tests assert on this.
  final List<String> written = [];

  @override
  Future<PrintResult> printBitmap(
    MonoBitmap bitmap, {
    required PrinterConfig config,
    String? jobName,
  }) async {
    if (failNext) {
      failNext = false;
      _connected = false;
      return const PrintResult.failure(
        'The printer did not respond.',
        detail: 'FakePrinter.failNext was set',
      );
    }

    try {
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }

      // Slashes in an invoice number are not valid in a file name.
      final safe = (jobName ?? 'receipt').replaceAll(RegExp(r'[^\w.-]'), '_');

      final png = File('${directory.path}/receipt-$safe.png');
      await png.writeAsBytes(encodeMonoPng(bitmap), flush: true);

      final bin = File('${directory.path}/receipt-$safe.bin');
      await bin.writeAsBytes(
        Uint8List.fromList(EscPos.job(bitmap, config)),
        flush: true,
      );

      _connected = true;
      written.add(png.path);
      return PrintResult.success(artefactPath: png.path);
    } on Object catch (e) {
      return PrintResult.failure(
        'Could not write the receipt file.',
        detail: '$e',
      );
    }
  }

  @override
  Future<void> disconnect() async => _connected = false;
}
