/// Writing a 1-bit bitmap out as a PNG.
///
/// Hand-rolled, which needs a word of justification: `package:image` would do
/// this in one call, but it was dropped in milestone 4 because it cannot shape
/// Telugu and conflicted with `excel` over `archive`. Pulling it back purely
/// to save a PNG would reintroduce that conflict for no benefit.
///
/// A greyscale 1-bit PNG is about sixty lines: a signature, three chunks, and
/// zlib with stored (uncompressed) blocks. Receipt bitmaps are small and these
/// files are for looking at, not for shipping, so not compressing is fine.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'printer.dart';

/// Encodes [bitmap] as a 1-bit greyscale PNG.
Uint8List encodeMonoPng(MonoBitmap bitmap) {
  final out = BytesBuilder()
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10]); // PNG signature

  // IHDR: width, height, bit depth 1, colour type 0 (greyscale).
  final ihdr = BytesBuilder()
    ..add(_be32(bitmap.width))
    ..add(_be32(bitmap.height))
    ..add([1, 0, 0, 0, 0]);
  out.add(_chunk('IHDR', ihdr.toBytes()));

  // Raw scanlines: a filter byte then the row's bits.
  //
  // PNG's 1-bit greyscale has 0 as black, which is the opposite of our
  // convention where a set bit means burn a dot. So every byte is inverted.
  final bytesPerRow = bitmap.bytesPerRow;
  final raw = BytesBuilder();
  for (var y = 0; y < bitmap.height; y++) {
    raw.addByte(0); // filter type 0: none
    final start = y * bytesPerRow;
    for (var i = 0; i < bytesPerRow; i++) {
      raw.addByte(~bitmap.bits[start + i] & 0xFF);
    }
  }

  out
    ..add(_chunk('IDAT', _zlibStored(raw.toBytes())))
    ..add(_chunk('IEND', Uint8List(0)));

  return out.toBytes();
}

Uint8List _be32(int v) => Uint8List(4)
  ..[0] = (v >> 24) & 0xFF
  ..[1] = (v >> 16) & 0xFF
  ..[2] = (v >> 8) & 0xFF
  ..[3] = v & 0xFF;

Uint8List _chunk(String type, Uint8List data) {
  final typeBytes = ascii.encode(type);
  final body = BytesBuilder()
    ..add(typeBytes)
    ..add(data);
  final bodyBytes = body.toBytes();

  return (BytesBuilder()
        ..add(_be32(data.length))
        ..add(bodyBytes)
        ..add(_be32(_crc32(bodyBytes))))
      .toBytes();
}

/// A zlib stream using stored blocks: no compression, but a valid stream that
/// every PNG reader accepts.
Uint8List _zlibStored(Uint8List data) {
  final out = BytesBuilder()..add(const [0x78, 0x01]); // zlib header

  const maxBlock = 65535;
  var offset = 0;
  while (offset < data.length) {
    final size = (data.length - offset > maxBlock)
        ? maxBlock
        : data.length - offset;
    final last = offset + size >= data.length;
    out
      ..addByte(last ? 1 : 0)
      ..addByte(size & 0xFF)
      ..addByte((size >> 8) & 0xFF)
      ..addByte(~size & 0xFF)
      ..addByte((~size >> 8) & 0xFF)
      ..add(Uint8List.sublistView(data, offset, offset + size));
    offset += size;
  }

  out.add(_be32(_adler32(data)));
  return out.toBytes();
}

int _adler32(Uint8List data) {
  var a = 1;
  var b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(Uint8List data) {
  var c = 0xFFFFFFFF;
  for (final byte in data) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
