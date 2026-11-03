/// A QR code as a grid of dark and light cells.
///
/// A thin wrapper over `package:qr`, which does the encoding and the
/// Reed-Solomon error correction. We want the matrix, not a widget: the
/// receipt is a bitmap drawn on a canvas, and `qr_flutter` would hand back a
/// widget that has no place in it.
library;

import 'package:qr/qr.dart';

class QrMatrix {
  const QrMatrix._(this._image, this.size);

  final QrImage _image;

  /// Modules per side, including the quiet zone added by [encode].
  final int size;

  /// The quiet zone: four light modules on every side.
  ///
  /// Required by the spec and routinely left out, which is the usual reason a
  /// printed QR scans on a phone screen but not off paper.
  static const int quietZone = 4;

  /// Encodes [data], picking the smallest version that fits.
  ///
  /// Error correction level M (about 15%) is the usual choice for print: a
  /// thermal receipt smudges and creases, and L is not enough once it has been
  /// in an apron pocket.
  factory QrMatrix.encode(String data) {
    final code = QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    );
    final image = QrImage(code);
    return QrMatrix._(image, image.moduleCount + quietZone * 2);
  }

  /// Whether the cell at [row], [col] should be black.
  ///
  /// Coordinates include the quiet zone, so the border always reads light.
  bool isDark(int row, int col) {
    final r = row - quietZone;
    final c = col - quietZone;
    if (r < 0 || c < 0 || r >= _image.moduleCount || c >= _image.moduleCount) {
      return false;
    }
    return _image.isDark(r, c);
  }
}
