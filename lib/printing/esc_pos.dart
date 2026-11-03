/// ESC/POS command bytes.
///
/// Written out here rather than taken from `esc_pos_utils_plus` directly. That
/// package has not been published since September 2024, and what we need from
/// it is about a dozen byte sequences that have been fixed since the 1990s.
/// Keeping them in one small file means a stale dependency cannot break
/// printing, and the bytes are visible to anyone debugging with a serial trace.
///
/// Two raster commands, because cheap thermal printers disagree:
///   - `GS v 0`: the modern one. One command, the whole image. Default.
///   - `ESC *`: the older one. 24 dot rows at a time. The fallback.
library;

import 'dart:typed_data';

import 'printer.dart';

abstract final class EscPos {
  /// `ESC @` — reset to a known state. Every job starts with this, because the
  /// previous job may have left the printer in any mode at all.
  static const List<int> initialise = [0x1B, 0x40];

  /// `LF` — advance one line.
  static const List<int> lineFeed = [0x0A];

  /// `GS V 66 n` — feed n lines, then cut. Partial cut leaves a small tab so
  /// the receipt does not drop on the floor.
  static List<int> cut({int feedLines = 4}) =>
      [0x1D, 0x56, 0x42, feedLines];

  /// `ESC d n` — feed n lines without cutting.
  static List<int> feed(int lines) => [0x1B, 0x64, lines];

  /// `GS v 0` raster bit image.
  ///
  /// Sent in horizontal strips rather than as one block. A long receipt as a
  /// single command overflows the print buffer on cheap printers, and the
  /// symptom is half a receipt with no error.
  static Uint8List rasterGsV0(MonoBitmap bitmap, {int stripHeight = 128}) {
    final out = BytesBuilder();
    final bytesPerRow = bitmap.bytesPerRow;

    for (var top = 0; top < bitmap.height; top += stripHeight) {
      final rows =
          (top + stripHeight > bitmap.height) ? bitmap.height - top : stripHeight;

      // GS v 0 m xL xH yL yH
      out.add([
        0x1D, 0x76, 0x30, 0x00,
        bytesPerRow & 0xFF, (bytesPerRow >> 8) & 0xFF,
        rows & 0xFF, (rows >> 8) & 0xFF,
      ]);
      out.add(Uint8List.sublistView(
        bitmap.bits,
        top * bytesPerRow,
        (top + rows) * bytesPerRow,
      ));
    }

    return out.toBytes();
  }

  /// `ESC * 33` 24-dot double-density bit image.
  ///
  /// The old way: the image is transposed into vertical slices of 24 dots,
  /// three bytes per column. Slower and fussier than `GS v 0`, which is why it
  /// is the fallback rather than the default.
  static Uint8List rasterEscStar(MonoBitmap bitmap) {
    final out = BytesBuilder()..add([0x1B, 0x33, 24]); // ESC 3 n: line spacing

    for (var top = 0; top < bitmap.height; top += 24) {
      // ESC * m nL nH
      out.add([
        0x1B, 0x2A, 33,
        bitmap.width & 0xFF, (bitmap.width >> 8) & 0xFF,
      ]);

      final column = Uint8List(bitmap.width * 3);
      for (var x = 0; x < bitmap.width; x++) {
        for (var k = 0; k < 3; k++) {
          var byte = 0;
          for (var bit = 0; bit < 8; bit++) {
            final y = top + k * 8 + bit;
            if (y < bitmap.height && bitmap.pixelAt(x, y)) {
              byte |= 0x80 >> bit;
            }
          }
          column[x * 3 + k] = byte;
        }
      }
      out
        ..add(column)
        ..add(lineFeed);
    }

    // ESC 2: back to the default line spacing, so the next job is unaffected.
    out.add([0x1B, 0x32]);
    return out.toBytes();
  }

  /// A complete job: initialise, image, feed, optional cut.
  static Uint8List job(MonoBitmap bitmap, PrinterConfig config) {
    final out = BytesBuilder()..add(initialise);

    out.add(
      config.useEscStar ? rasterEscStar(bitmap) : rasterGsV0(bitmap),
    );

    if (config.autoCut) {
      out.add(cut());
    } else {
      // Without a cutter, feed far enough that the whole receipt clears the
      // tear bar. Otherwise the last lines are still inside the printer.
      out.add(feed(5));
    }

    return out.toBytes();
  }
}
