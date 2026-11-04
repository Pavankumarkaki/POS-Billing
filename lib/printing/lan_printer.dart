/// A network printer, reached over raw TCP.
///
/// Port 9100 is the convention ("JetDirect"): the printer listens, you open a
/// socket, you write ESC/POS bytes, it prints. There is no protocol on top, no
/// handshake and no acknowledgement, which has two consequences worth knowing:
///
///   - A successful write means the bytes left this device. It does NOT mean
///     paper came out. Out of paper, cover open and jammed all look identical
///     from here.
///   - Everything needs a timeout. A printer that is powered on but wedged
///     will accept a connection and then never read, and without a timeout the
///     till hangs at the counter with a customer waiting.
///
/// So this is deliberately pessimistic: short timeouts, a fresh connection per
/// job, and an error message the owner can act on rather than a stack trace.
library;

import 'dart:async';
import 'dart:io';

import 'esc_pos.dart';
import 'printer.dart';

class LanPrinter implements Printer {
  LanPrinter({
    this.connectTimeout = const Duration(seconds: 5),
    this.writeTimeout = const Duration(seconds: 15),
  });

  /// How long to wait for the printer to accept a connection.
  ///
  /// Five seconds: on a restaurant's own Wi-Fi a reachable printer answers in
  /// milliseconds, so a longer wait only delays telling the owner it is off.
  final Duration connectTimeout;

  /// How long to wait for the whole job to go out.
  ///
  /// Longer, because a big receipt over slow Wi-Fi legitimately takes a while.
  final Duration writeTimeout;

  bool _connected = false;

  @override
  PrinterKind get kind => PrinterKind.lan;

  @override
  bool get isConnected => _connected;

  @override
  Future<PrintResult> printBitmap(
    MonoBitmap bitmap, {
    required PrinterConfig config,
    String? jobName,
  }) async {
    if (config.address.trim().isEmpty) {
      return const PrintResult.failure(
        'No printer address set. Add it in Settings.',
      );
    }

    Socket? socket;
    try {
      // A fresh connection per job, rather than holding one open.
      //
      // Thermal printers drop idle sockets without telling anyone, so a held
      // connection is usually dead by the next sale and fails in a way that
      // looks like the printer is broken. Reconnecting costs milliseconds on
      // a LAN and removes a whole class of confusing failure.
      socket = await Socket.connect(
        config.address.trim(),
        config.port,
        timeout: connectTimeout,
      );

      final bytes = EscPos.job(bitmap, config);
      socket.add(bytes);
      await socket.flush().timeout(writeTimeout);

      _connected = true;
      return const PrintResult.success();
    } on SocketException catch (e) {
      _connected = false;
      return PrintResult.failure(
        _friendly(e, config),
        detail: '$e',
      );
    } on TimeoutException catch (e) {
      _connected = false;
      return PrintResult.failure(
        'The printer accepted the connection but stopped responding. '
        'Check for a paper jam or an open cover.',
        detail: '$e',
      );
    } on Object catch (e) {
      _connected = false;
      return PrintResult.failure(
        'Could not send the receipt to the printer.',
        detail: '$e',
      );
    } finally {
      // Always close, even after a failure: a half-open socket on the printer
      // can block the next job until it times out at its end.
      try {
        await socket?.close();
      } on Object {
        // Nothing useful to do, and the job result is already decided.
      }
      socket?.destroy();
    }
  }

  @override
  Future<void> disconnect() async => _connected = false;

  /// Turns a socket error into something an owner can act on.
  ///
  /// "Connection refused" and "No route to host" mean different things in the
  /// restaurant: one is the printer being off, the other is it being on a
  /// different network. Saying which saves a phone call.
  static String _friendly(SocketException e, PrinterConfig config) {
    final address = '${config.address}:${config.port}';
    final os = e.osError?.message.toLowerCase() ?? '';

    if (os.contains('refused')) {
      return 'The printer at $address refused the connection. '
          'It may be switched off, or printing from another device.';
    }
    if (os.contains('no route') || os.contains('unreachable')) {
      return 'Cannot reach $address. Check the printer is on the same '
          'Wi-Fi as this device.';
    }
    if (e.message.toLowerCase().contains('timed out') ||
        os.contains('timed out')) {
      return 'The printer at $address did not answer. '
          'Check it is switched on.';
    }
    return 'Could not reach the printer at $address.';
  }
}
