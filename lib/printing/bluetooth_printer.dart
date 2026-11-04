/// A Bluetooth Classic (SPP) thermal printer.
///
/// **This file is not verified.** There is no Bluetooth adapter and no printer
/// on the machine it was written on, so what is proven is that it compiles,
/// honours the [Printer] interface, and sends the same bytes the LAN printer
/// sends (which ARE verified, against a real socket). Whether paper comes out
/// of your printer is untested. See HARDWARE_TEST.md.
///
/// Three things this has to get right, each of which is a common failure at a
/// counter:
///
///   1. **Permission.** Android 12 and later require BLUETOOTH_CONNECT at
///      runtime. Without it the paired-device list comes back empty and the
///      app looks broken rather than unpermitted.
///   2. **Paired devices only.** The brief says list only paired printers.
///      Discovery would show every phone and earbud in the restaurant, and the
///      owner would have to know a MAC address to pick the right one.
///   3. **Reconnect before each job.** SPP connections drop when the printer
///      sleeps, and the library reports stale state. Checking and reconnecting
///      costs a moment and avoids a failure that looks random.
library;

import 'dart:async';

import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import 'esc_pos.dart';
import 'printer.dart';

/// A printer the owner can choose in settings.
class PairedPrinter {
  const PairedPrinter({required this.name, required this.address});
  final String name;
  final String address;
}

class BluetoothPrinter implements Printer {
  BluetoothPrinter({
    this.connectTimeout = const Duration(seconds: 8),
    this.writeTimeout = const Duration(seconds: 20),
  });

  /// Bluetooth pairing is slower than TCP; 8 seconds is about the limit of
  /// what someone at a counter will wait before deciding it is broken.
  final Duration connectTimeout;
  final Duration writeTimeout;

  @override
  PrinterKind get kind => PrinterKind.bluetooth;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  /// Asks for BLUETOOTH_CONNECT if it has not been granted.
  ///
  /// Returns whether printing can go ahead. Called before listing devices and
  /// before each job, because the owner can revoke it in Settings at any time.
  static Future<bool> ensurePermission() async {
    if (await PrintBluetoothThermal.isPermissionBluetoothGranted) {
      return true;
    }
    final status = await Permission.bluetoothConnect.request();
    return status.isGranted;
  }

  /// Whether Bluetooth itself is switched on.
  static Future<bool> isBluetoothOn() =>
      PrintBluetoothThermal.bluetoothEnabled;

  /// Printers the phone is already paired with.
  ///
  /// Only paired devices, as the brief requires. Pairing happens in Android's
  /// own Bluetooth settings, which handles the PIN properly; duplicating that
  /// here would be worse and less familiar.
  static Future<List<PairedPrinter>> pairedPrinters() async {
    if (!await ensurePermission()) return const [];
    try {
      final devices = await PrintBluetoothThermal.pairedBluetooths;
      return [
        for (final d in devices)
          PairedPrinter(name: d.name, address: d.macAdress),
      ];
    } on Object {
      // A platform exception here is almost always Bluetooth being off, which
      // the settings screen checks for separately and reports better.
      return const [];
    }
  }

  @override
  Future<PrintResult> printBitmap(
    MonoBitmap bitmap, {
    required PrinterConfig config,
    String? jobName,
  }) async {
    if (config.address.trim().isEmpty) {
      return const PrintResult.failure(
        'No printer chosen. Pick one in Settings.',
      );
    }

    try {
      if (!await ensurePermission()) {
        return const PrintResult.failure(
          'This app needs Bluetooth permission to print. '
          'Allow it in Settings.',
        );
      }

      if (!await isBluetoothOn()) {
        _connected = false;
        return const PrintResult.failure(
          'Bluetooth is switched off. Turn it on and try again.',
        );
      }

      final ready = await _ensureConnected(config.address.trim());
      if (!ready) {
        _connected = false;
        return PrintResult.failure(
          'Could not connect to the printer. Check it is switched on and '
          'in range.',
          detail: 'connect to ${config.address} failed or timed out',
        );
      }

      final bytes = EscPos.job(bitmap, config);
      final wrote = await PrintBluetoothThermal.writeBytes(bytes)
          .timeout(writeTimeout);

      if (!wrote) {
        // The connection looked fine but the write was rejected, which usually
        // means it dropped between the check and the write. Drop our side so
        // the next attempt reconnects from scratch rather than retrying on a
        // dead link.
        _connected = false;
        await _safeDisconnect();
        return const PrintResult.failure(
          'The printer stopped responding part way through. Try again.',
        );
      }

      _connected = true;
      return const PrintResult.success();
    } on TimeoutException catch (e) {
      _connected = false;
      await _safeDisconnect();
      return PrintResult.failure(
        'The printer did not finish the receipt. Check for a paper jam.',
        detail: '$e',
      );
    } on Object catch (e) {
      _connected = false;
      await _safeDisconnect();
      return PrintResult.failure(
        'Could not print over Bluetooth.',
        detail: '$e',
      );
    }
  }

  /// Connects if not already connected to [address].
  ///
  /// The library's own connection status is advisory, so this trusts it only
  /// as a fast path: if it says connected, try the write and let a failure
  /// force a reconnect on the next attempt.
  Future<bool> _ensureConnected(String address) async {
    try {
      if (await PrintBluetoothThermal.connectionStatus) return true;
    } on Object {
      // Treat an error here as "not connected" and go on to connect.
    }

    try {
      return await PrintBluetoothThermal.connect(macPrinterAddress: address)
          .timeout(connectTimeout);
    } on TimeoutException {
      return false;
    } on Object {
      return false;
    }
  }

  Future<void> _safeDisconnect() async {
    try {
      await PrintBluetoothThermal.disconnect;
    } on Object {
      // Already gone, which is the state we wanted.
    }
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    await _safeDisconnect();
  }
}
