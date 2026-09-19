import 'dart:async';

/// Batches multiple API requests into single batch calls.
///
/// Reduces network overhead by combining related requests.
class RequestBatcher<T> {
  RequestBatcher({
    required this.batchFn,
    this.maxBatchSize = 20,
    this.maxWaitMs = 100,
  });

  final Future<List<T?>> Function(List<String> ids) batchFn;
  final int maxBatchSize;
  final int maxWaitMs;

  final _pending = <String, Completer<T?>>{};
  Timer? _batchTimer;

  /// Request a single item, potentially batched with others.
  Future<T?> request(String id) {
    if (_pending.containsKey(id)) {
      return _pending[id]!.future;
    }

    final completer = Completer<T?>();
    _pending[id] = completer;

    if (_pending.length >= maxBatchSize) {
      _flush();
    } else {
      _batchTimer?.cancel();
      _batchTimer = Timer(Duration(milliseconds: maxWaitMs), _flush);
    }

    return completer.future;
  }

  void _flush() {
    if (_pending.isEmpty) return;

    final ids = _pending.keys.toList();
    final completers = Map<String, Completer<T?>>.from(_pending);
    _pending.clear();

    batchFn(ids).then((results) {
      for (var i = 0; i < ids.length && i < results.length; i++) {
        completers[ids[i]]?.complete(results[i]);
      }
    }).catchError((e) {
      for (final c in completers.values) {
        if (!c.isCompleted) c.completeError(e);
      }
    });
  }

  void dispose() {
    _batchTimer?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _pending.clear();
  }
}
