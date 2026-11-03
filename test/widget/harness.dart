/// Shared setup for widget tests.
///
/// The point of the provider overrides here: every screen reads its data
/// through `providers.dart`, so a test can hand it an in-memory database and
/// nothing in the screen itself needs to know.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:restaurant_pos/data/db.dart';
import 'package:restaurant_pos/providers.dart';
import 'package:restaurant_pos/theme/app_theme.dart';

/// Renders [child] with the real theme and an in-memory database.
///
/// [size] sets the surface, so one test can check a 390px phone and the next
/// a 1280px tablet.
///
/// The default is deliberately very tall. A ListView builds only the children
/// it can show, so on a real phone surface the fields below the fold do not
/// exist and a test cannot type into them. Interaction tests therefore use a
/// surface tall enough to build the whole form; layout and overflow tests pass
/// a real device size explicitly.
/// Returns the container, so a test can set state up (signing a user in, say)
/// without touching providers from inside a build, which Riverpod forbids.
Future<ProviderContainer> pumpScreen(
  WidgetTester tester, {
  required PosDatabase db,
  required Widget child,
  Size? size,
  void Function(ProviderContainer container)? before,
}) async {
  final surface = size ?? const Size(430, 3000);

  tester.view
    ..physicalSize = surface
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(db)],
  );
  addTearDown(container.dispose);

  // Runs before the first frame, so the screen's very first build already sees
  // the signed-in session rather than flashing a refusal and rebuilding.
  before?.call(container);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: child,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Types [text] into the field whose label is [label].
///
/// Finds by label rather than by index, so adding a field above does not
/// silently point an existing test at the wrong box.
Future<void> enterByLabel(
  WidgetTester tester,
  String label,
  String text,
) async {
  final field = find.ancestor(
    of: find.text(label),
    matching: find.byType(TextField),
  );
  expect(
    field,
    findsOneWidget,
    reason: 'no single TextField labelled "$label"',
  );
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

/// Taps [finder] and pumps a few frames WITHOUT settling.
///
/// Needed where the tap starts something that never settles: the setup screen
/// keeps its progress spinner running after a successful save, deliberately,
/// so the owner cannot submit twice while the app re-routes. pumpAndSettle
/// would wait for that spinner forever.
Future<void> tapAndPump(
  WidgetTester tester,
  Finder finder, {
  Duration wait = const Duration(seconds: 1),
}) async {
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(wait);
}
