/// Renders the launcher icons from `lib/theme/brand.dart`. A tool, not a test.
///
/// Tagged `brand` and therefore skipped on a normal run, like
/// `test/seed_device_test.dart`. Run it after changing the mark:
///
///     flutter test test/brand_icons_test.dart --run-skipped
///
/// It writes straight into `android/app/src/main/res/`, so the icons are
/// generated from the one definition rather than kept up to date by hand.
/// The Play Store listing image goes to `build/brand/`, which is not
/// checked in, because nothing in the build consumes it.
@Tags(['brand'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/theme/brand.dart';

const _res = 'android/app/src/main/res';

/// Density buckets, and the multiplier Android applies to each.
const _densities = <String, double>{
  'mdpi': 1,
  'hdpi': 1.5,
  'xhdpi': 2,
  'xxhdpi': 3,
  'xxxhdpi': 4,
};

Future<void> write(String path, int px, {bool background = true}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  paintBrandMark(canvas, px.toDouble(), withBackground: background);

  final image = await recorder.endRecording().toImage(px, px);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) throw StateError('nothing encoded for $path');

  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(data.buffer.asUint8List());
  // ignore: avoid_print
  print('wrote $path (${data.lengthInBytes} bytes)');
}

void main() {
  // Everything runs inside tester.runAsync. A widget test drives a fake async
  // zone, and Picture.toImage needs the real event loop to finish: the first
  // file wrote and every call after it hung for good.
  testWidgets('render the launcher icons', (tester) async {
    await tester.runAsync(() async {
      for (final entry in _densities.entries) {
        final dir = '$_res/mipmap-${entry.key}';

        // The legacy icon: 48dp, with its own background.
        await write('$dir/ic_launcher.png', (48 * entry.value).round());

        // The adaptive icon's foreground: 108dp, transparent, because the
        // background is a separate layer. The mark sits inside the central
        // safe zone, so a launcher may mask it to any shape without
        // clipping anything.
        await write(
          '$dir/ic_launcher_foreground.png',
          (108 * entry.value).round(),
          background: false,
        );
      }

      // The Play Store listing wants 512 with no transparency.
      await write('build/brand/play-store-512.png', 512);
    });

    for (final density in _densities.keys) {
      expect(
        File('$_res/mipmap-$density/ic_launcher.png').existsSync(),
        isTrue,
        reason: '$density icon missing',
      );
    }
  });
}
