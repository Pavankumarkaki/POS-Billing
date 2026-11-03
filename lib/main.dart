/// Entry point.
///
/// Flutter note: ProviderScope is Riverpod's container. Everything in
/// providers.dart is built lazily beneath it, and a test can replace any of
/// them by passing `overrides`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  runApp(const ProviderScope(child: PosApp()));
}
