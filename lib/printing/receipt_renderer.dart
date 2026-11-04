/// Turns a [ReceiptDoc] into a 1-bit bitmap.
///
/// Rendered with `dart:ui` — the same text engine that draws the app — rather
/// than with the printer's built-in fonts or a bitmap-font package. That is not
/// a preference, it is the only thing that works:
///
///   - Thermal printers have no Telugu glyphs. A printer font would produce
///     boxes, or worse, silently nothing.
///   - Telugu needs real shaping: vowel signs reorder around consonants and
///     consonant clusters form conjuncts. Drawing glyph-by-glyph from a bitmap
///     font gets this wrong in ways that look almost right.
///   - The ₹ sign is missing from most printers' code pages too.
///
/// So every receipt is an image. The cost is a slower print and a bigger
/// payload; the benefit is that what the kitchen reads is what the screen
/// showed.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import '../core/receipt.dart';
import '../theme/app_theme.dart';
import 'printer.dart';
import 'qr.dart';

/// Pixel metrics for an 80 mm head at 203 dpi (576 dots).
///
/// Everything scales off [width], so a 58 mm printer at 384 dots gets
/// proportionally smaller text rather than a clipped receipt.
class ReceiptMetrics {
  const ReceiptMetrics({required this.width});

  final int width;

  double get scale => width / 576;

  double get margin => 12 * scale;
  double get contentWidth => width - margin * 2;

  double get normalSize => 22 * scale;
  double get smallSize => 18 * scale;
  double get largeSize => 30 * scale;

  double get lineGap => 4 * scale;
  double get dividerThickness => 1.5 * scale;
  double get qrSize => 200 * scale;
}

/// Renders [doc] to a 1-bit bitmap [width] dots across.
///
/// Must run on the platform thread with a Flutter binding available, which is
/// true in the app and in `flutter test`.
Future<MonoBitmap> renderReceipt(
  ReceiptDoc doc, {
  int width = 576,
}) async {
  final metrics = ReceiptMetrics(width: width);

  // Lay every block out first, so the canvas can be made exactly tall enough.
  // A receipt that is too short clips the total; one that is too long wastes
  // paper on every single bill.
  final laid = <_Laid>[];
  var y = metrics.margin;

  for (final block in doc.blocks) {
    final item = _layout(block, metrics);
    laid.add(_Laid(item, y));
    y += item.height + metrics.lineGap;
  }
  final height = (y + metrics.margin).ceil();

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  // White paper. Everything is drawn black; the threshold below turns grey
  // antialiasing into ink or nothing.
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );

  for (final entry in laid) {
    entry.item.paint(canvas, entry.y, metrics);
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  picture.dispose();
  image.dispose();

  if (data == null) {
    throw StateError('Could not read the rendered receipt back.');
  }

  return _threshold(data.buffer.asUint8List(), width, height);
}

/// Converts RGBA to one bit per pixel.
///
/// A thermal head is binary: a dot is burned or it is not. Antialiased grey
/// has to become one or the other, and the midpoint is the honest choice.
/// Rows are padded to whole bytes, which is what the raster commands expect.
MonoBitmap _threshold(Uint8List rgba, int width, int height) {
  final bytesPerRow = (width + 7) ~/ 8;
  final bits = Uint8List(bytesPerRow * height);

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      // Luminance, not a plain average: green carries most of the perceived
      // brightness, and antialiased text looks wrong without this.
      final luma = 0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2];
      if (luma < 128) {
        bits[y * bytesPerRow + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
  }

  return MonoBitmap(width: width, height: height, bits: bits);
}

class _Laid {
  const _Laid(this.item, this.y);
  final _Item item;
  final double y;
}

abstract class _Item {
  double get height;
  void paint(ui.Canvas canvas, double y, ReceiptMetrics m);
}

_Item _layout(ReceiptBlock block, ReceiptMetrics m) => switch (block) {
      TextLine() => _TextItem.single(block, m),
      TwoColumn() => _TwoColumnItem(block, m),
      ItemRowBlock() => _ItemRowItem(block, m),
      DividerBlock() => _DividerItem(m),
      SpacerBlock(:final lines) => _SpacerItem(lines * m.normalSize * 0.5),
      QrBlock() => _QrItem(block, m),
      RulerBlock() => _RulerItem(m),
    };

double _sizeFor(TextScale scale, ReceiptMetrics m) => switch (scale) {
      TextScale.small => m.smallSize,
      TextScale.normal => m.normalSize,
      TextScale.large => m.largeSize,
    };

ui.Paragraph _paragraph(
  String text, {
  required double size,
  required bool bold,
  required double maxWidth,
  ui.TextAlign align = ui.TextAlign.left,
}) {
  final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
    textAlign: align,
    fontFamily: kFontFamily,
    fontSize: size,
    fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
    // Receipts are read in a hurry, often in poor light.
    height: 1.25,
  ))
    ..pushStyle(ui.TextStyle(
      color: const ui.Color(0xFF000000),
      fontFamily: kFontFamily,
      fontSize: size,
      fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
    ))
    ..addText(text);

  return builder.build()
    ..layout(ui.ParagraphConstraints(width: maxWidth));
}

class _TextItem implements _Item {
  _TextItem(this.paragraph);

  factory _TextItem.single(TextLine line, ReceiptMetrics m) {
    final align = switch (line.align) {
      Align.left => ui.TextAlign.left,
      Align.centre => ui.TextAlign.center,
      Align.right => ui.TextAlign.right,
    };
    return _TextItem(_paragraph(
      line.text,
      size: _sizeFor(line.scale, m),
      bold: line.bold,
      maxWidth: m.contentWidth,
      align: align,
    ));
  }

  final ui.Paragraph paragraph;

  @override
  double get height => paragraph.height;

  @override
  void paint(ui.Canvas canvas, double y, ReceiptMetrics m) =>
      canvas.drawParagraph(paragraph, ui.Offset(m.margin, y));
}

/// Left label, right amount. The amount is laid out at its natural width and
/// right-aligned, so columns of figures line up even with long labels.
class _TwoColumnItem implements _Item {
  _TwoColumnItem(TwoColumn block, ReceiptMetrics m)
      : _m = m {
    final size = _sizeFor(block.scale, m);
    // The right column gets what it needs; the left takes the rest and wraps.
    final rightWidth = m.contentWidth * 0.42;
    _right = _paragraph(
      block.right,
      size: size,
      bold: block.bold,
      maxWidth: rightWidth,
      align: ui.TextAlign.right,
    );
    _left = _paragraph(
      block.left,
      size: size,
      bold: block.bold,
      maxWidth: m.contentWidth - rightWidth - 4 * m.scale,
    );
  }

  final ReceiptMetrics _m;
  late final ui.Paragraph _left;
  late final ui.Paragraph _right;

  @override
  double get height =>
      _left.height > _right.height ? _left.height : _right.height;

  @override
  void paint(ui.Canvas canvas, double y, ReceiptMetrics m) {
    canvas
      ..drawParagraph(_left, ui.Offset(m.margin, y))
      ..drawParagraph(
        _right,
        ui.Offset(m.width - m.margin - _right.width, y),
      );
    assert(_m.width == m.width);
  }
}

/// `2  Chicken Dum Biryani            480.00`
/// with the Telugu name and unit price underneath.
class _ItemRowItem implements _Item {
  _ItemRowItem(ItemRowBlock block, ReceiptMetrics m) {
    final amountWidth = m.contentWidth * 0.3;
    final nameWidth = m.contentWidth - amountWidth - 6 * m.scale;

    _amount = _paragraph(
      block.amount,
      size: m.normalSize,
      bold: false,
      maxWidth: amountWidth,
      align: ui.TextAlign.right,
    );
    _name = _paragraph(
      '${block.qty}  ${block.name}',
      size: m.normalSize,
      bold: false,
      maxWidth: nameWidth,
    );

    final sub = <String>[
      if (block.nameTe != null && block.nameTe!.isNotEmpty) block.nameTe!,
      if (block.unitPrice != null) '@ ${block.unitPrice}',
    ];
    _sub = sub.isEmpty
        ? null
        : _paragraph(
            sub.join('   '),
            size: m.smallSize,
            bold: false,
            maxWidth: nameWidth,
          );
  }

  late final ui.Paragraph _name;
  late final ui.Paragraph _amount;
  late final ui.Paragraph? _sub;

  @override
  double get height {
    final top = _name.height > _amount.height ? _name.height : _amount.height;
    return top + (_sub?.height ?? 0);
  }

  @override
  void paint(ui.Canvas canvas, double y, ReceiptMetrics m) {
    canvas
      ..drawParagraph(_name, ui.Offset(m.margin, y))
      ..drawParagraph(
        _amount,
        ui.Offset(m.width - m.margin - _amount.width, y),
      );
    if (_sub != null) {
      // Indented under the name, past the quantity column.
      canvas.drawParagraph(
        _sub,
        ui.Offset(m.margin + 20 * m.scale, y + _name.height),
      );
    }
  }
}

class _DividerItem implements _Item {
  _DividerItem(this.m);
  final ReceiptMetrics m;

  @override
  double get height => m.dividerThickness + 4 * m.scale;

  @override
  void paint(ui.Canvas canvas, double y, ReceiptMetrics metrics) {
    canvas.drawRect(
      ui.Rect.fromLTWH(
        metrics.margin,
        y + 2 * metrics.scale,
        metrics.contentWidth,
        metrics.dividerThickness,
      ),
      ui.Paint()..color = const ui.Color(0xFF000000),
    );
  }
}

/// A full-width ruler with a tick every 10% and a taller one at the halfway
/// mark, so a mis-set width is obvious at a glance.
class _RulerItem implements _Item {
  _RulerItem(this.m);
  final ReceiptMetrics m;

  @override
  double get height => 16 * m.scale;

  @override
  void paint(ui.Canvas canvas, double y, ReceiptMetrics metrics) {
    final paint = ui.Paint()..color = const ui.Color(0xFF000000);
    final baseline = y + 12 * metrics.scale;
    final thickness = 1.5 * metrics.scale;

    // The baseline runs the exact printable width, edge to edge.
    canvas.drawRect(
      ui.Rect.fromLTWH(
        metrics.margin,
        baseline,
        metrics.contentWidth,
        thickness,
      ),
      paint,
    );

    for (var i = 0; i <= 10; i++) {
      final tall = i == 0 || i == 5 || i == 10;
      final tickHeight = (tall ? 12 : 6) * metrics.scale;
      final x = metrics.margin +
          metrics.contentWidth * (i / 10) -
          (i == 10 ? thickness : 0);
      canvas.drawRect(
        ui.Rect.fromLTWH(x, baseline - tickHeight, thickness, tickHeight),
        paint,
      );
    }
  }
}

class _SpacerItem implements _Item {
  _SpacerItem(this.height);
  @override
  final double height;
  @override
  void paint(ui.Canvas canvas, double y, ReceiptMetrics m) {}
}

class _QrItem implements _Item {
  _QrItem(this.block, ReceiptMetrics m)
      : _matrix = QrMatrix.encode(block.data),
        _size = m.qrSize,
        _caption = block.caption == null
            ? null
            : _paragraph(
                block.caption!,
                size: m.smallSize,
                bold: false,
                maxWidth: m.contentWidth,
                align: ui.TextAlign.center,
              );

  final QrBlock block;
  final QrMatrix _matrix;
  final double _size;
  final ui.Paragraph? _caption;

  @override
  double get height => _size + (_caption?.height ?? 0) + 4;

  @override
  void paint(ui.Canvas canvas, double y, ReceiptMetrics m) {
    final size = _size;
    final cell = size / _matrix.size;
    final left = (m.width - size) / 2;
    final paint = ui.Paint()..color = const ui.Color(0xFF000000);

    for (var row = 0; row < _matrix.size; row++) {
      for (var col = 0; col < _matrix.size; col++) {
        if (!_matrix.isDark(row, col)) continue;
        canvas.drawRect(
          ui.Rect.fromLTWH(
            left + col * cell,
            y + row * cell,
            // A hair over, so neighbouring cells never leave a white seam that
            // a scanner reads as a gap.
            cell + 0.5,
            cell + 0.5,
          ),
          paint,
        );
      }
    }

    if (_caption != null) {
      canvas.drawParagraph(_caption, ui.Offset(m.margin, y + size + 4));
    }
  }
}
