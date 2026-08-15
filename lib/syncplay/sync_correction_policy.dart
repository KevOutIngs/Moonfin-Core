/// Decides what SyncPlay drift correction should do about one measurement,
/// with no player or network dependencies so the timing rules can be exercised
/// on their own.
library;

enum SyncCorrectionAction { hold, defer, skip, speed, giveUp }

class SyncCorrectionSettings {
  final bool useSkipToSync;
  final bool useSpeedToSync;
  final int minDelaySkipToSyncMs;
  final int minDelaySpeedToSyncMs;
  final int maxDelaySpeedToSyncMs;
  final int speedToSyncDurationMs;
  final int extraTimeOffsetMs;

  const SyncCorrectionSettings({
    required this.useSkipToSync,
    required this.useSpeedToSync,
    required this.minDelaySkipToSyncMs,
    required this.minDelaySpeedToSyncMs,
    required this.maxDelaySpeedToSyncMs,
    required this.speedToSyncDurationMs,
    this.extraTimeOffsetMs = 0,
  });
}

class SyncCorrectionDecision {
  final SyncCorrectionAction action;
  /// Unclamped: the policy does not know the item duration.
  final int targetPositionMs;
  final double speed;
  final int speedDurationMs;
  /// Positive means ahead of the group, zero when nothing was measurable.
  final int measuredDelayMs;

  const SyncCorrectionDecision._(
    this.action, {
    this.targetPositionMs = 0,
    this.speed = 1.0,
    this.speedDurationMs = 0,
    this.measuredDelayMs = 0,
  });

  const SyncCorrectionDecision.defer() : this._(SyncCorrectionAction.defer);
}

class SyncCorrectionPolicy {
  // Backends sample position on a timer (250ms on Apple TV and media3), so
  // drift under this is quantisation noise and correcting on it just wobbles
  // the rate every couple of seconds.
  static const int noiseFloorMs = 400;
  static const int skipSettleMs = 6000;
  static const int maxSeekLatencyAllowanceMs = 8000;
  static const int maxConsecutiveSkips = 4;

  static const double _slowDownSpeed = 0.95;
  static const double _speedUpSpeed = 1.05;

  int _consecutiveSkips = 0;
  int _seekLatencyAllowanceMs = 0;
  int _blockedUntilMs = 0;
  bool _awaitingSkipSettle = false;
  bool _gaveUp = false;

  int get seekLatencyAllowanceMs => _seekLatencyAllowanceMs;
  int get consecutiveSkips => _consecutiveSkips;
  bool get hasGivenUp => _gaveUp;

  SyncCorrectionDecision evaluate({
    required int nowMs,
    required int serverNowMs,
    required int currentPositionMs,
    required int lastSyncPositionMs,
    required int lastSyncTimeMs,
    required bool isBuffering,
    required bool isPlaying,
    required int clockJitterMs,
    required SyncCorrectionSettings settings,
  }) {
    if (_gaveUp) {
      return const SyncCorrectionDecision._(SyncCorrectionAction.giveUp);
    }

    // A stalled or paused pipeline has a frozen position, so every sample reads
    // as far behind. Seeking on that measurement stalls the pipeline again,
    // which is the loop that leaves one client scrubbing in place while the
    // rest of the group plays on.
    if (isBuffering || !isPlaying) return const SyncCorrectionDecision.defer();
    if (nowMs < _blockedUntilMs) return const SyncCorrectionDecision.defer();

    final expectedMs = lastSyncPositionMs +
        (serverNowMs - lastSyncTimeMs) +
        settings.extraTimeOffsetMs;
    final delay = currentPositionMs - expectedMs;
    final absDelay = delay.abs();

    if (_awaitingSkipSettle) {
      _awaitingSkipSettle = false;
      // A skip lands at a position computed before the seek began, so whatever
      // it is still short by once it settles is this client's own seek latency.
      // Without folding that back in, every skip loses the same amount again
      // and the correction never converges.
      if (delay < 0) {
        final grown = _seekLatencyAllowanceMs + absDelay;
        _seekLatencyAllowanceMs = grown > maxSeekLatencyAllowanceMs
            ? maxSeekLatencyAllowanceMs
            : grown;
      } else {
        final shrunk = _seekLatencyAllowanceMs - delay;
        _seekLatencyAllowanceMs = shrunk < 0 ? 0 : shrunk;
      }
    }

    final floor = noiseFloorMs + (clockJitterMs ~/ 2);
    if (absDelay <= floor) {
      _consecutiveSkips = 0;
      return SyncCorrectionDecision._(
        SyncCorrectionAction.hold,
        measuredDelayMs: delay,
      );
    }

    if (settings.useSkipToSync && absDelay > settings.minDelaySkipToSyncMs) {
      if (_consecutiveSkips >= maxConsecutiveSkips) {
        _gaveUp = true;
        return SyncCorrectionDecision._(
          SyncCorrectionAction.giveUp,
          measuredDelayMs: delay,
        );
      }
      _consecutiveSkips++;
      _awaitingSkipSettle = true;
      _blockedUntilMs = nowMs + skipSettleMs;
      return SyncCorrectionDecision._(
        SyncCorrectionAction.skip,
        targetPositionMs: expectedMs + _seekLatencyAllowanceMs,
        measuredDelayMs: delay,
      );
    }

    _consecutiveSkips = 0;

    if (settings.useSpeedToSync &&
        absDelay > settings.minDelaySpeedToSyncMs &&
        absDelay < settings.maxDelaySpeedToSyncMs) {
      return SyncCorrectionDecision._(
        SyncCorrectionAction.speed,
        speed: delay > 0 ? _slowDownSpeed : _speedUpSpeed,
        speedDurationMs: settings.speedToSyncDurationMs,
        measuredDelayMs: delay,
      );
    }

    return SyncCorrectionDecision._(
      SyncCorrectionAction.hold,
      measuredDelayMs: delay,
    );
  }

  /// A fresh sync point. The learned seek latency belongs to the device and
  /// stream, so it survives a pause where the skip streak does not.
  void onResumed() {
    _consecutiveSkips = 0;
    _awaitingSkipSettle = false;
    _blockedUntilMs = 0;
  }

  void reset() {
    _consecutiveSkips = 0;
    _seekLatencyAllowanceMs = 0;
    _blockedUntilMs = 0;
    _awaitingSkipSettle = false;
    _gaveUp = false;
  }
}
