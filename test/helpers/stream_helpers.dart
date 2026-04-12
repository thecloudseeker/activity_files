// SPDX-License-Identifier: BSD-3-Clause
/// Stream testing utilities.
///
/// Provides stream wrappers and builders for testing stream-based operations.
library;

import 'dart:async';

/// Stream wrapper that counts how many times it has been listened to.
///
/// Throws [StateError] if listened to more than once.
/// Useful for testing that stream sources are only subscribed once.
class CountingStream extends Stream<List<int>> {
  CountingStream(this._chunks);

  final List<List<int>> _chunks;
  int listenCount = 0;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (listenCount > 0) {
      throw StateError('Stream can only be listened to once.');
    }
    listenCount++;
    final controller = StreamController<List<int>>();
    Future(() async {
      try {
        for (final chunk in _chunks) {
          controller.add(chunk);
          await Future<void>.delayed(Duration.zero);
        }
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      } finally {
        await controller.close();
      }
    });
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

/// Creates a chunked stream from bytes for testing.
///
/// Splits the bytes into [chunkCount] approximately equal chunks.
Stream<List<int>> createChunkedStream(List<int> bytes, {int chunkCount = 2}) {
  final chunkSize = (bytes.length / chunkCount).ceil();
  final chunks = <List<int>>[];

  for (var i = 0; i < bytes.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, bytes.length);
    chunks.add(bytes.sublist(i, end));
  }

  return Stream.fromIterable(chunks);
}
