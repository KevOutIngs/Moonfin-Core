import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/scheduler.dart';

/// Samples what mpv and Flutter report during desktop playback, so a
/// diagnostic report can say where stutter or tearing comes from.
///
/// On the texture path every video frame goes through two hands: mpv renders
/// it into media_kit's texture, then Flutter composites that texture in its
/// own frame. A frame lost in mpv shows up in its drop counters; a frame mpv
/// delivered but Flutter presented late shows up as a gap between Flutter
/// frames. One line every [interval] carries both, plus a snapshot of the
/// decode and render setup whenever it changes.
class MpvPlaybackDiagnostics {
  MpvPlaybackDiagnostics({
    required this._readProperty,
    required this._isPlaying,
    required this._renderPath,
    required this._textureSize,
    required this._log,
    this.interval = const Duration(seconds: 10),
  });

  final Future<String?> Function(String key) _readProperty;
  final bool Function() _isPlaying;
  final String Function() _renderPath;
  final Size? Function() _textureSize;
  final void Function(String message) _log;
  final Duration interval;

  static const _setupKeys = [
    'current-vo',
    'gpu-api',
    'gpu-context',
    'hwdec',
    'hwdec-current',
    'video-codec',
    'video-params/pixelformat',
    'video-params/w',
    'video-params/h',
    'video-params/gamma',
    'video-params/primaries',
    'video-out-params/pixelformat',
    'video-out-params/w',
    'video-out-params/h',
    'container-fps',
    'display-fps',
    'video-sync',
    'interpolation',
    'tone-mapping',
    'target-trc',
    'target-prim',
    'scale',
    'dscale',
    'cscale',
    'deband',
    'dither-depth',
  ];

  // Cumulative per file in mpv; logged as the change over each window.
  static const _counterKeys = [
    'frame-drop-count',
    'decoder-frame-drop-count',
    'vo-delayed-frame-count',
    'mistimed-frame-count',
  ];

  Timer? _timer;
  bool _sampling = false;
  String? _lastSetup;
  int _windowsSinceSetup = 0;

  // The report keeps the last 2000 entries, which a long film fills with
  // network lines, so the setup is repeated now and then to stay in it.
  static const _setupRepeatWindows = 30;
  final Map<String, int> _counterBaseline = {};
  final List<FrameTiming> _frames = [];
  bool _timingsAttached = false;

  /// Starts sampling a newly opened file. Safe to call again for the next
  /// file; the previous one's counters and setup are forgotten.
  void start() {
    stop();
    _timer = Timer.periodic(interval, (_) => unawaited(_sample()));
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timingsAttached = true;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (_timingsAttached) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _timingsAttached = false;
    }
    _frames.clear();
    _counterBaseline.clear();
    _lastSetup = null;
    _windowsSinceSetup = 0;
  }

  void _onTimings(List<FrameTiming> timings) {
    _frames.addAll(timings);
    // A paused video still lets the UI animate; the window never needs more
    // than a few seconds of frames at any refresh rate.
    if (_frames.length > 2000) {
      _frames.removeRange(0, _frames.length - 2000);
    }
  }

  Future<void> _sample() async {
    if (_sampling) return;
    _sampling = true;
    try {
      if (!_isPlaying()) {
        // Paused frames say nothing about playback; drop them so the next
        // window measures playing time only.
        _frames.clear();
        return;
      }
      await _logSetupIfChanged();
      await _logWindow();
    } catch (_) {
      // Diagnostics must never disturb playback.
    } finally {
      _sampling = false;
    }
  }

  Future<void> _logSetupIfChanged() async {
    final values = await Future.wait(_setupKeys.map(_readProperty));
    // Before the first frame mpv has no video-params yet; wait for them so
    // the snapshot describes the file actually playing.
    if (values[_setupKeys.indexOf('video-params/w')] == null) return;

    final parts = <String>['path=${_renderPath()}'];
    for (var i = 0; i < _setupKeys.length; i++) {
      parts.add('${_setupKeys[i]}=${values[i] ?? '-'}');
    }
    final texture = _textureSize();
    if (texture != null) {
      parts.add('texture=${texture.width.round()}x${texture.height.round()}');
    }
    parts.add(_describeDisplay());

    final setup = parts.join(' ');
    _windowsSinceSetup++;
    if (setup == _lastSetup && _windowsSinceSetup < _setupRepeatWindows) {
      return;
    }
    _lastSetup = setup;
    _windowsSinceSetup = 0;
    _log('Video setup: $setup');
  }

  Future<void> _logWindow() async {
    final counters = await Future.wait(_counterKeys.map(_readProperty));
    final live = await Future.wait(
      [
        'estimated-vf-fps',
        'avsync',
        'vsync-jitter',
        'demuxer-cache-duration',
        'paused-for-cache',
      ].map(_readProperty),
    );

    final parts = <String>[];
    for (var i = 0; i < _counterKeys.length; i++) {
      final value = int.tryParse(counters[i] ?? '');
      if (value == null) continue;
      final base = _counterBaseline[_counterKeys[i]];
      // A counter that went backwards belongs to a new file.
      final delta = base == null || value < base ? value : value - base;
      _counterBaseline[_counterKeys[i]] = value;
      parts.add('${_shortName(_counterKeys[i])}=+$delta');
    }

    final vfFps = double.tryParse(live[0] ?? '');
    parts
      ..add('vf-fps=${_fixed(vfFps)}')
      ..add('avsync=${_ms(live[1])}')
      ..add('vsync-jitter=${live[2] ?? '-'}')
      ..add('cache=${_fixed(double.tryParse(live[3] ?? ''))}s')
      ..add('paused-for-cache=${live[4] ?? '-'}')
      ..add(_describeFlutterFrames(vfFps));

    _log('Video stats ${interval.inSeconds}s: ${parts.join(' ')}');
  }

  /// How Flutter presented the window's frames. A video frame mpv delivered
  /// on time still stutters if the frame showing it reaches the screen late,
  /// which reads here as a gap longer than one video frame.
  String _describeFlutterFrames(double? vfFps) {
    final frames = List<FrameTiming>.of(_frames);
    _frames.clear();
    if (frames.isEmpty) return 'ui-frames=0';

    final refresh = _refreshRate();
    final budgetUs = refresh > 0 ? 1e6 / refresh : 1e6 / 60;
    final videoFrameUs = vfFps != null && vfFps > 0 ? 1e6 / vfFps : null;

    var slowBuild = 0;
    var slowRaster = 0;
    var maxBuildUs = 0;
    var maxRasterUs = 0;
    var gaps = 0;
    var maxGapUs = 0;
    int? previousFinish;
    final rasters = <int>[];
    for (final f in frames) {
      final build = f.buildDuration.inMicroseconds;
      final raster = f.rasterDuration.inMicroseconds;
      rasters.add(raster);
      if (build > budgetUs) slowBuild++;
      if (raster > budgetUs) slowRaster++;
      maxBuildUs = math.max(maxBuildUs, build);
      maxRasterUs = math.max(maxRasterUs, raster);

      final finish = f.timestampInMicroseconds(FramePhase.rasterFinish);
      if (previousFinish != null) {
        final gap = finish - previousFinish;
        maxGapUs = math.max(maxGapUs, gap);
        if (videoFrameUs != null && gap > videoFrameUs * 1.5) gaps++;
      }
      previousFinish = finish;
    }
    rasters.sort();
    final p95Raster = rasters[((rasters.length - 1) * 0.95).round()];

    return [
      'ui-frames=${frames.length}',
      'slow-build=$slowBuild',
      'slow-raster=$slowRaster',
      'max-build=${_usToMs(maxBuildUs)}',
      'max-raster=${_usToMs(maxRasterUs)}',
      'p95-raster=${_usToMs(p95Raster)}',
      'gaps>1.5vf=$gaps',
      'max-gap=${_usToMs(maxGapUs)}',
    ].join(' ');
  }

  String _describeDisplay() {
    final view = PlatformDispatcher.instance.implicitView;
    if (view == null) return 'display=-';
    final size = view.physicalSize;
    return 'display-hz=${_fixed(_refreshRate())} '
        'view=${size.width.round()}x${size.height.round()} '
        'dpr=${view.devicePixelRatio}';
  }

  double _refreshRate() {
    try {
      return PlatformDispatcher.instance.implicitView?.display.refreshRate ??
          0;
    } catch (_) {
      return 0;
    }
  }

  static String _shortName(String key) => switch (key) {
    'frame-drop-count' => 'vo-drops',
    'decoder-frame-drop-count' => 'dec-drops',
    'vo-delayed-frame-count' => 'vo-delayed',
    'mistimed-frame-count' => 'mistimed',
    _ => key,
  };

  static String _fixed(double? value) =>
      value == null ? '-' : value.toStringAsFixed(3);

  static String _ms(String? seconds) {
    final value = double.tryParse(seconds ?? '');
    return value == null ? '-' : '${(value * 1000).toStringAsFixed(1)}ms';
  }

  static String _usToMs(int us) => '${(us / 1000).toStringAsFixed(1)}ms';
}
