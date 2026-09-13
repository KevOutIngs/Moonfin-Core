/// Decides whether a live stream is showing a picture, from the bit rate
/// its demuxer measures for the video track.
///
/// A tuner's failover placeholder is a black video with a sound track: it
/// decodes, plays and runs its clock like any channel, so the player sees
/// nothing wrong. But a black or frozen picture compresses to almost nothing,
/// tens of kilobits a second at 1080p where a real channel carries megabits,
/// for every codec and container. The video bit rate against the frame size
/// says whether there is anything to show.
///
/// Fed one sample a second from a player that reports its video bit rate
/// (mpv's `video-bitrate`, averaged by the player over about a second), and
/// asked for a verdict at a time. The Android backend reads the same signal
/// from the frames it hands its decoder; this is the same rule on the
/// player's own measurement.
///
/// Pure and clock-agnostic, so it can be tested with a fixed clock.
class StreamPictureEvidence {
  StreamPictureEvidence({
    this.window = const Duration(seconds: 6),
    this.minSpan = const Duration(milliseconds: 1500),
    this.minBitsPerPixelPerSecond = 0.1,
  });

  /// How much recent history a verdict is based on. Long enough to hold a
  /// keyframe of any broadcast GOP, so a still picture is not mistaken for
  /// a black one.
  final Duration window;

  /// How much history there has to be before a verdict.
  final Duration minSpan;

  /// Below this, the video cannot be carrying a picture: 200 kbit/s at
  /// 1080p, 90 at 720p, 40 at SD. A black stream runs at about a fifth of
  /// it whatever its size; the poorest real broadcast at three times it.
  final double minBitsPerPixelPerSecond;

  final List<({DateTime at, double bitsPerPixelPerSecond})> _samples = [];

  void reset() => _samples.clear();

  /// One reading of the video bit rate for a frame of [width] by [height].
  /// A rate of zero is the player not having measured yet, not a black
  /// picture, and is not a sample.
  void onSample({
    required DateTime at,
    required int videoBitsPerSecond,
    required int width,
    required int height,
  }) {
    if (videoBitsPerSecond <= 0 || width <= 0 || height <= 0) return;
    _samples.add((
      at: at,
      bitsPerPixelPerSecond: videoBitsPerSecond / (width * height),
    ));
    final floor = at.subtract(window);
    _samples.removeWhere((s) => s.at.isBefore(floor));
  }

  /// True when the stream cannot be showing a picture, false when it is,
  /// null while there is not enough to say.
  bool? noPicture(DateTime now) {
    if (_samples.length < 2) return null;
    if (_samples.last.at.difference(_samples.first.at) < minSpan) return null;
    return _mean() < minBitsPerPixelPerSecond;
  }

  double _mean() =>
      _samples.fold(0.0, (sum, s) => sum + s.bitsPerPixelPerSecond) /
      _samples.length;

  /// One line for the log: what the verdict rests on.
  String describe() {
    if (_samples.isEmpty) return 'no samples';
    final span = _samples.last.at.difference(_samples.first.at);
    return '${_samples.length} samples over ${span.inMilliseconds}ms, '
        '${_mean().toStringAsFixed(4)} bits/px/s';
  }
}
