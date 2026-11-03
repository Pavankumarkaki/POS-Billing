/// Runs print jobs one at a time.
///
/// The brief: "queue jobs so two never overlap". Two concurrent writes to a
/// thermal printer do not produce two receipts, they produce one corrupted
/// one, because the printer is a byte stream with no framing. On Bluetooth it
/// can also wedge the connection until the printer is power-cycled.
///
/// This matters more than it sounds at a counter: the owner taps Charge, the
/// receipt is slow, and they tap Reprint on the previous bill while waiting.
library;

import 'dart:async';

/// One queued piece of work.
typedef PrintTask<T> = Future<T> Function();

class PrintQueue {
  Future<void> _tail = Future<void>.value();

  /// How many jobs are waiting or running. For a "printing..." indicator.
  int _pending = 0;
  int get pending => _pending;

  bool get isBusy => _pending > 0;

  /// Queues [task] and returns its result.
  ///
  /// Jobs run in the order they were added. A job that throws does not stop
  /// the ones behind it: one failed receipt must not block the next sale.
  Future<T> add<T>(PrintTask<T> task) {
    _pending++;
    final completer = Completer<T>();

    _tail = _tail.then((_) async {
      try {
        completer.complete(await task());
      } on Object catch (e, st) {
        completer.completeError(e, st);
      } finally {
        _pending--;
      }
    });

    return completer.future;
  }

  /// Waits for everything currently queued to finish.
  Future<void> drain() => _tail;
}
