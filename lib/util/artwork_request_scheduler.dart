import 'dart:async';
import 'dart:collection';

import 'package:clock/clock.dart';

import 'image_fetch_priority.dart';

/// Decides which queued artwork request goes out next.
///
/// The cache manager's own queue is first come first served. On a fast scroll
/// that fills it with cells already scrolled past, and the cells now on screen
/// wait behind them. A fetch can't be cancelled, so nothing drains that queue
/// but time. This admits [slots] requests at once and orders the rest by lane,
/// then newest batch first, then first come first served inside a batch, so a
/// freshly built grid still fills from its top left corner.
///
/// A request holds no connection and no timer while it waits here. The header
/// timeout starts at admission, so the rule that nothing sits in a queue
/// dart:io never times out still holds: dart:io only ever sees [slots]
/// requests.
class ArtworkRequestScheduler {
  ArtworkRequestScheduler({
    required this.slots,
    this.batchGap = defaultBatchGap,
  }) : assert(slots > 0);

  /// How many requests may be in flight at once. Matched to the connection
  /// budget of the client the requests go through.
  final int slots;

  /// Two requests closer together than this belong to the same batch.
  ///
  /// The cells of one grid build reach the gate within a couple of
  /// milliseconds of each other, since only a memory lookup and a file
  /// existence check separate them, while successive frames of a fling are
  /// sixteen milliseconds apart. Eight keeps one build together, so its rows
  /// load top to bottom, and splits a fling frame by frame, so the last frame
  /// built goes first. Smaller would split one build and load its bottom rows
  /// first.
  final Duration batchGap;
  static const defaultBatchGap = Duration(milliseconds: 8);

  int _running = 0;
  int _batch = 0;
  DateTime? _lastEnqueue;

  /// Batches keyed by id, each a first-in first-out queue. The last key is
  /// the newest batch.
  final Map<ImageFetchPriority, SplayTreeMap<int, Queue<_Waiter>>> _lanes = {
    for (final lane in ImageFetchPriority.values)
      lane: SplayTreeMap<int, Queue<_Waiter>>(),
  };
  final Map<String, _Waiter> _waiting = <String, _Waiter>{};

  int get running => _running;
  int get queueDepth => _waiting.length;

  /// Completes when [url] may be sent, with the batch it was filed under and
  /// how many were waiting when it arrived, for the log. Every acquire must
  /// be paired with one [release], whether the request succeeded or not.
  Future<ArtworkAdmission> acquire(
    String url, {
    ImageFetchPriority priority = ImageFetchPriority.normal,
  }) {
    _touchBatch();
    final waiter = _Waiter(
      url,
      priority,
      batch: _batch,
      depthAtEnqueue: _waiting.length,
    );
    if (_running < slots && _waiting.isEmpty) {
      _running++;
      waiter.admit();
      return waiter.completer.future;
    }
    _enqueue(waiter);
    return waiter.completer.future;
  }

  void release() {
    if (_running > 0) _running--;
    _admit();
  }

  /// Files a waiting request for [url] as if it had just been made in
  /// [priority]'s lane, for a widget that has just mounted for an image a
  /// prefetch asked for earlier, or that an older batch still holds. The
  /// cache manager merges requests for one URL, so the visible widget would
  /// otherwise inherit the lane and the batch of whoever asked first.
  void promote(String url, ImageFetchPriority priority) {
    final waiter = _waiting[url];
    if (waiter == null) return;
    _touchBatch();
    if (waiter.priority.index <= priority.index && waiter.batch == _batch) {
      return;
    }
    _dequeue(waiter);
    _enqueue(
      _Waiter(
        url,
        waiter.priority.index < priority.index ? waiter.priority : priority,
        batch: _batch,
        depthAtEnqueue: waiter.depthAtEnqueue,
        completer: waiter.completer,
      ),
    );
  }

  /// Opens a new batch when the last request was longer than [batchGap] ago.
  void _touchBatch() {
    final now = clock.now();
    final last = _lastEnqueue;
    if (last == null || now.difference(last) > batchGap) _batch++;
    _lastEnqueue = now;
  }

  void _enqueue(_Waiter waiter) {
    _lanes[waiter.priority]!
        .putIfAbsent(waiter.batch, Queue<_Waiter>.new)
        .add(waiter);
    _waiting[waiter.url] = waiter;
  }

  void _dequeue(_Waiter waiter) {
    final batches = _lanes[waiter.priority]!;
    final queue = batches[waiter.batch];
    if (queue != null) {
      queue.remove(waiter);
      if (queue.isEmpty) batches.remove(waiter.batch);
    }
    _waiting.remove(waiter.url);
  }

  void _admit() {
    while (_running < slots) {
      final next = _next();
      if (next == null) return;
      _dequeue(next);
      _running++;
      next.admit();
    }
  }

  _Waiter? _next() {
    for (final lane in ImageFetchPriority.values) {
      final batches = _lanes[lane]!;
      if (batches.isEmpty) continue;
      return batches[batches.lastKey()]!.first;
    }
    return null;
  }
}

/// What a request learns when it is let through.
typedef ArtworkAdmission = ({int batch, int queueDepth});

class _Waiter {
  _Waiter(
    this.url,
    this.priority, {
    required this.batch,
    required this.depthAtEnqueue,
    Completer<ArtworkAdmission>? completer,
  }) : completer = completer ?? Completer<ArtworkAdmission>();

  final String url;
  final ImageFetchPriority priority;
  final int batch;
  final int depthAtEnqueue;
  final Completer<ArtworkAdmission> completer;

  void admit() =>
      completer.complete((batch: batch, queueDepth: depthAtEnqueue));
}
