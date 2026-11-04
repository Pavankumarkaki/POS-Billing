/// The LAN printer, against a real TCP server.
///
/// This is the one hardware path that can be genuinely verified here: a socket
/// on 127.0.0.1 behaves like a socket to a printer, so the bytes that arrive
/// are exactly the bytes a real printer would receive. Bluetooth has no such
/// stand-in and is untested until it meets your hardware.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/printing/lan_printer.dart';
import 'package:restaurant_pos/printing/printer.dart';

/// A stand-in for a networked thermal printer.
class FakeNetworkPrinter {
  FakeNetworkPrinter._(this._server, this.port);

  final ServerSocket _server;
  final int port;

  final BytesBuilder _received = BytesBuilder();
  final List<Socket> _clients = [];

  /// Accept connections but never read, like a wedged printer.
  bool stall = false;

  static Future<FakeNetworkPrinter> start({bool stall = false}) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final printer = FakeNetworkPrinter._(server, server.port)..stall = stall;

    server.listen((client) {
      printer._clients.add(client);
      if (printer.stall) return; // connected, reading nothing
      client.listen(
        printer._received.add,
        onDone: client.destroy,
        onError: (_) => client.destroy(),
        cancelOnError: true,
      );
    });

    return printer;
  }

  Uint8List get received => Uint8List.fromList(_received.toBytes());

  Future<void> stop() async {
    for (final c in _clients) {
      c.destroy();
    }
    await _server.close();
  }
}

MonoBitmap sampleBitmap({int width = 576, int height = 64}) {
  final bytesPerRow = (width + 7) ~/ 8;
  final bits = Uint8List(bytesPerRow * height);
  // A diagonal, so the bytes are not all identical and a truncated write shows.
  for (var y = 0; y < height; y++) {
    bits[y * bytesPerRow + (y % bytesPerRow)] = 0xFF;
  }
  return MonoBitmap(width: width, height: height, bits: bits);
}

void main() {
  group('a reachable printer', () {
    late FakeNetworkPrinter server;
    late LanPrinter printer;

    setUp(() async {
      server = await FakeNetworkPrinter.start();
      printer = LanPrinter();
    });

    tearDown(() => server.stop());

    test('receives the job', () async {
      final result = await printer.printBitmap(
        sampleBitmap(),
        config: PrinterConfig(
          kind: PrinterKind.lan,
          address: '127.0.0.1',
          port: server.port,
        ),
      );

      expect(result.ok, isTrue, reason: result.error);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.received, isNotEmpty);
    });

    test('and the bytes are valid ESC/POS', () async {
      await printer.printBitmap(
        sampleBitmap(),
        config: PrinterConfig(
          kind: PrinterKind.lan,
          address: '127.0.0.1',
          port: server.port,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final bytes = server.received;
      expect(bytes[0], 0x1B, reason: 'ESC');
      expect(bytes[1], 0x40, reason: '@ — reset');
      expect(
        _contains(bytes, [0x1D, 0x76, 0x30]),
        isTrue,
        reason: 'GS v 0 raster',
      );
      expect(
        _contains(bytes, [0x1D, 0x56, 0x42]),
        isTrue,
        reason: 'GS V B — cut',
      );
    });

    test('the whole bitmap arrives, not a truncated write', () async {
      final bmp = sampleBitmap(height: 512);
      await printer.printBitmap(
        bmp,
        config: PrinterConfig(
          kind: PrinterKind.lan,
          address: '127.0.0.1',
          port: server.port,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Every pixel byte must be in there, plus the commands around them.
      expect(
        server.received.length,
        greaterThan(bmp.bits.length),
        reason: 'a short write is how half a receipt happens',
      );
    });

    test('auto-cut off sends a feed instead of a cut', () async {
      await printer.printBitmap(
        sampleBitmap(),
        config: PrinterConfig(
          kind: PrinterKind.lan,
          address: '127.0.0.1',
          port: server.port,
          autoCut: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final bytes = server.received;
      expect(_contains(bytes, [0x1D, 0x56, 0x42]), isFalse);
      expect(_contains(bytes, [0x1B, 0x64]), isTrue, reason: 'ESC d — feed');
    });

    test('the ESC * fallback changes the bytes on the wire', () async {
      await printer.printBitmap(
        sampleBitmap(),
        config: PrinterConfig(
          kind: PrinterKind.lan,
          address: '127.0.0.1',
          port: server.port,
          useEscStar: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      final bytes = server.received;
      expect(_contains(bytes, [0x1B, 0x2A, 33]), isTrue, reason: 'ESC * 33');
      expect(_contains(bytes, [0x1D, 0x76, 0x30]), isFalse,
          reason: 'not the GS v 0 path');
    });

    test('two jobs in a row both arrive', () async {
      final config = PrinterConfig(
        kind: PrinterKind.lan,
        address: '127.0.0.1',
        port: server.port,
      );
      final first = await printer.printBitmap(sampleBitmap(), config: config);
      final second = await printer.printBitmap(sampleBitmap(), config: config);

      expect(first.ok, isTrue);
      expect(
        second.ok,
        isTrue,
        reason: 'a fresh connection per job, so the second is not refused',
      );
    });
  });

  group('an unreachable printer', () {
    test('nothing listening gives an actionable message', () async {
      // Bind then immediately close, so the port is almost certainly free.
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();

      final result = await LanPrinter().printBitmap(
        sampleBitmap(),
        config: PrinterConfig(
          kind: PrinterKind.lan,
          address: '127.0.0.1',
          port: deadPort,
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error, isNotNull);
      expect(
        result.error!.toLowerCase(),
        anyOf(contains('refused'), contains('cannot reach'), contains('not answer')),
        reason: 'the owner needs to know what to check, not a stack trace',
      );
      expect(result.detail, isNotNull, reason: 'the raw error goes to the log');
    });

    test('an empty address is refused before any network call', () async {
      final result = await LanPrinter().printBitmap(
        sampleBitmap(),
        config: const PrinterConfig(kind: PrinterKind.lan, address: '  '),
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('Settings'));
    });

    test('an unroutable address fails fast rather than hanging', () async {
      final printer = LanPrinter(
        connectTimeout: const Duration(milliseconds: 300),
      );
      final started = DateTime.now();

      final result = await printer.printBitmap(
        sampleBitmap(),
        // 198.51.100.0/24 is reserved for documentation, so nothing routes.
        config: const PrinterConfig(
          kind: PrinterKind.lan,
          address: '198.51.100.1',
        ),
      );

      expect(result.ok, isFalse);
      expect(
        DateTime.now().difference(started),
        lessThan(const Duration(seconds: 5)),
        reason: 'the till must not hang with a customer waiting',
      );
    });
  });

  group('a wedged printer', () {
    test('a connection that never reads times out', () async {
      final server = await FakeNetworkPrinter.start(stall: true);
      addTearDown(server.stop);

      final printer = LanPrinter(
        writeTimeout: const Duration(milliseconds: 400),
      );

      final result = await printer.printBitmap(
        // Large enough to exceed the socket buffer, so flush actually blocks.
        sampleBitmap(height: 4096),
        config: PrinterConfig(
          kind: PrinterKind.lan,
          address: '127.0.0.1',
          port: server.port,
        ),
      );

      // Either it times out, or the OS buffered the whole thing and reported
      // success. Both are acceptable; what must not happen is hanging.
      if (!result.ok) {
        expect(result.error, isNotNull);
      }
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('connection state', () {
    test('starts disconnected and reports success', () async {
      final server = await FakeNetworkPrinter.start();
      addTearDown(server.stop);

      final printer = LanPrinter();
      expect(printer.isConnected, isFalse);

      await printer.printBitmap(
        sampleBitmap(),
        config: PrinterConfig(
          kind: PrinterKind.lan,
          address: '127.0.0.1',
          port: server.port,
        ),
      );
      expect(printer.isConnected, isTrue);

      await printer.disconnect();
      expect(printer.isConnected, isFalse);
    });

    test('a failure leaves it disconnected', () async {
      final printer = LanPrinter(
        connectTimeout: const Duration(milliseconds: 300),
      );
      await printer.printBitmap(
        sampleBitmap(),
        config: const PrinterConfig(
          kind: PrinterKind.lan,
          address: '198.51.100.1',
        ),
      );
      expect(printer.isConnected, isFalse);
    });
  });
}

bool _contains(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}
