/// Entry point.
///
/// Flutter note: ProviderScope is Riverpod's container. Everything in
/// providers.dart is built lazily beneath it, and a test can replace any of
/// them by passing `overrides`.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The fake printer writes receipts here. Inside the app's documents
  // directory so they are easy to find and go away with the app.
  final docs = await getApplicationDocumentsDirectory();
  final receipts = Directory('${docs.path}/receipts');

  runApp(
    ProviderScope(
      overrides: [
        receiptDirectoryProvider.overrideWithValue(receipts),
      ],
      child: const PosApp(),
    ),
  );
}
