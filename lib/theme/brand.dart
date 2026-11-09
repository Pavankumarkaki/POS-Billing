/// The Lekka mark: a receipt coming out of the machine that printed it.
///
/// Drawn in code rather than shipped as a PNG so there is one definition of
/// it. `test/brand_icons_test.dart` renders this straight into the Android
/// launcher densities, so the icons are regenerated rather than maintained
/// by hand, and the app can paint the same thing at any size without a
/// second asset going stale.
///
/// Two earlier attempts are worth recording, because both failed in ways
/// that are easy to repeat. Putting the slip on a circle, meaning the paper
/// roll seen end on, read as a keyhole: the shapes were close enough in
/// width to merge. Sinking the slot into the middle of the body made the
/// slot read as a handle, with the paper resting on a lid. A wide body, a
/// narrow slip, and a slot straddling the top edge is what separates them.
///
/// Everything is three or four bold shapes rather than fine detail, because
/// the size that decides a launcher icon is 48px, not 512.
///
/// Colours are the ones already in `app_theme.dart`. Nothing new here.
library;

import 'dart:ui';

import 'app_theme.dart';

/// The reference grid every coordinate below is expressed in.
const double _grid = 512;

/// Paints the mark into a [size] by [size] square.
///
/// [withBackground] draws the green rounded square behind it, which a legacy
/// launcher icon and the Play Store listing both need. An Android adaptive
/// icon supplies its own background layer, so its foreground passes false.
void paintBrandMark(
  Canvas canvas,
  double size, {
  bool withBackground = true,
}) {
  final s = size / _grid;
  double x(double v) => v * s;

  if (withBackground) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size, size),
        Radius.circular(x(112)),
      ),
      Paint()..color = AppColors.primary,
    );
  }

  // --- the slip ------------------------------------------------------------
  //
  // Drawn first, so the body covers the end of it. Torn across the top,
  // where it was cut: that edge is what makes it a receipt rather than a
  // document, because it is what a thermal printer leaves behind.
  //
  // Three deep teeth, not six shallow ones. The shallow version looked right
  // at 512px and turned into a grey fringe at 48.
  const left = 208.0;
  const right = 304.0;
  const foot = 300.0;
  const tear = 142.0;
  const toothRise = 24.0;
  const teeth = 3;

  final slip = Path()
    ..moveTo(x(left), x(foot))
    ..lineTo(x(right), x(foot))
    ..lineTo(x(right), x(tear));

  const toothWidth = (right - left) / teeth;
  for (var i = 0; i < teeth; i++) {
    final toX = right - toothWidth * (i + 1);
    final midX = right - toothWidth * (i + 0.5);
    slip
      ..lineTo(x(midX), x(tear - toothRise))
      ..lineTo(x(toX), x(tear));
  }

  canvas.drawPath(slip..close(), Paint()..color = AppColors.surface);

  // The printed total: the one line on a receipt anybody actually reads, and
  // the only place the accent colour appears.
  canvas.drawLine(
    Offset(x(228), x(204)),
    Offset(x(284), x(204)),
    Paint()
      ..color = AppColors.accent
      ..strokeWidth = x(20)
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke,
  );

  // --- the machine ---------------------------------------------------------
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTRB(x(146), x(290), x(366), x(378)),
      Radius.circular(x(30)),
    ),
    Paint()..color = AppColors.surface,
  );

  // The slot, straddling the top edge so the slip visibly goes into it.
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTRB(x(196), x(282), x(316), x(302)),
      Radius.circular(x(9)),
    ),
    Paint()..color = AppColors.primary,
  );
}
