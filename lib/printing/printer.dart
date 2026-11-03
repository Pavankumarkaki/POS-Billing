/// The printer, as an interface.
///
/// Three implementations: Bluetooth, LAN, and a fake that writes to files.
/// Every screen depends on this type and never on a concrete printer, so the
/// billing flow can be tested end to end without hardware.
///
/// The hard rule from the brief lives in the caller, not here: the bill is
/// saved BEFORE anything is printed. Nothing in this file can lose a bill,
/// because by the time it runs the bill is already committed.
library;

import 'dart:typed_data';

/// A 1-bit image, ready for the printer.
///
/// Row-major, one bit per pixel, 1 meaning black. Rows are padded to whole
/// bytes, which is what both `GS v 0` and `ESC *` expect.
class MonoBitmap {
  const MonoBitmap({
    required this.width,
    required this.height,
    required this.bits,
  });

  final int width;
  final int height;

  /// `heightInRows * bytesPerRow` bytes.
  final Uint8List bits;

  int get bytesPerRow => (width + 7) ~/ 8;

  bool pixelAt(int x, int y) {
    if (x < 0 || y < 0 || x >= width || y >= height) return false;
    final byte = bits[y * bytesPerRow + (x >> 3)];
    return (byte & (0x80 >> (x & 7))) != 0;
  }

  /// Total black dots.
  int get blackPixels {
    var black = 0;
    for (final b in bits) {
      black += _bitCount(b);
    }
    return black;
  }

  /// Proportion of the bitmap that is black, 0 to 1.
  ///
  /// Useful for "did anything render at all", but NOT for "did this block add
  /// ink": a QR code adds far more white quiet zone than black cells, so the
  /// ratio falls even as the dot count rises. Compare [blackPixels] for that.
  double get inkCoverage =>
      bits.isEmpty ? 0 : blackPixels / (bits.length * 8);

  static int _bitCount(int b) {
    var n = b;
    var count = 0;
    while (n != 0) {
      count += n & 1;
      n >>= 1;
    }
    return count;
  }
}

/// How the printer is reached.
enum PrinterKind { bluetooth, lan, fake }

/// What a print attempt produced.
class PrintResult {
  const PrintResult._({
    required this.ok,
    this.error,
    this.detail,
    this.artefactPath,
  });

  const PrintResult.success({String? artefactPath})
      : this._(ok: true, artefactPath: artefactPath);

  const PrintResult.failure(String error, {String? detail})
      : this._(ok: false, error: error, detail: detail);

  final bool ok;

  /// Something the owner can act on: "Printer is off or out of range."
  final String? error;

  /// The underlying message, for the log. Not shown on the till.
  final String? detail;

  /// Where the fake printer wrote its output.
  final String? artefactPath;
}

/// Printer settings, stored as JSON on the device row.
class PrinterConfig {
  const PrinterConfig({
    this.kind = PrinterKind.fake,
    this.address = '',
    this.widthPx = 576,
    this.autoCut = true,
    this.useEscStar = false,
    this.port = 9100,
  });

  final PrinterKind kind;

  /// A MAC address for Bluetooth, an IP for LAN. Empty for the fake printer.
  final String address;

  /// Dots across the head. 576 is standard for 80 mm at 203 dpi; 384 is the
  /// usual 58 mm. Configurable because cheap printers vary.
  final int widthPx;

  final bool autoCut;

  /// `GS v 0` is the modern raster command and the default. Some older
  /// printers only understand `ESC *`, so it stays available.
  final bool useEscStar;

  /// Raw TCP port for LAN printers. 9100 is the convention.
  final int port;

  Map<String, Object?> toJson() => {
        'kind': kind.name,
        'address': address,
        'width_px': widthPx,
        'auto_cut': autoCut,
        'use_esc_star': useEscStar,
        'port': port,
      };

  static PrinterConfig fromJson(Map<String, Object?> json) => PrinterConfig(
        kind: PrinterKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => PrinterKind.fake,
        ),
        address: (json['address'] as String?) ?? '',
        widthPx: (json['width_px'] as int?) ?? 576,
        autoCut: (json['auto_cut'] as bool?) ?? true,
        useEscStar: (json['use_esc_star'] as bool?) ?? false,
        port: (json['port'] as int?) ?? 9100,
      );

  PrinterConfig copyWith({
    PrinterKind? kind,
    String? address,
    int? widthPx,
    bool? autoCut,
    bool? useEscStar,
    int? port,
  }) =>
      PrinterConfig(
        kind: kind ?? this.kind,
        address: address ?? this.address,
        widthPx: widthPx ?? this.widthPx,
        autoCut: autoCut ?? this.autoCut,
        useEscStar: useEscStar ?? this.useEscStar,
        port: port ?? this.port,
      );
}

/// Something that can put a bitmap on paper.
///
/// Implementations must be safe to call again after a failure: the brief
/// requires a retry, and a printer that needs the app restarted after one bad
/// job is useless at a counter.
abstract class Printer {
  PrinterKind get kind;

  /// Whether the last attempt left us connected. Advisory only: the only way
  /// to know is to try.
  bool get isConnected;

  /// Prints one receipt. Reconnects first if needed.
  Future<PrintResult> printBitmap(
    MonoBitmap bitmap, {
    required PrinterConfig config,
    String? jobName,
  });

  /// Releases the connection. Safe to call when not connected.
  Future<void> disconnect();
}
