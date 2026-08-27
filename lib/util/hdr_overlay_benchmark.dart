import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Phase 1 question for the layered-window architecture
/// (`docs/windows-hdr-phase0-results.md`): can Flutter produce the controls
/// bitmap fast enough to feed `UpdateLayeredWindow`?
///
/// Mode `10` of the Q4 spike settled the compositing - a premultiplied ARGB
/// scrim does blend correctly over the video window, gradients intact. What it
/// did not settle is where that bitmap comes from. The intended route is an
/// off-screen `RepaintBoundary.toImage()` followed by `toByteData()`, and the
/// second call is a GPU-to-CPU readback whose cost scales with area.
///
/// This runs instead of the app when `MOONFIN_HDR_Q4=11`, renders a stand-in
/// OSD at several sizes, and times the round trip. Results land in
/// `%TEMP%\moonfin_hdr_q4.log` next to the native probe's own lines.
///
/// The widget content is deliberately close to the real player chrome in
/// *shape* - two scrim gradients, a progress bar, a row of buttons - because
/// what matters is the raster and readback cost at that resolution, not which
/// widgets produced it.
class HdrOverlayBenchmarkApp extends StatelessWidget {
  const HdrOverlayBenchmarkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _Benchmark(),
    );
  }
}

/// The sizes worth knowing about, in physical pixels.
///
/// The full window is the honest number, because a scrim that fades across the
/// top quarter of the screen cannot be cropped to a small band. The narrower
/// entries measure the fallback: if the full frame is too slow, the controls
/// could be split into two smaller layered windows, one per scrim, and the
/// clear middle left out entirely.
const _sizes = <({String label, int width, int height})>[
  (label: 'full window 4K-ish', width: 3814, height: 1993),
  (label: 'full window 1080p', width: 1907, height: 996),
  (label: 'bottom controls band only', width: 3814, height: 500),
  (label: 'bottom controls band 1080p', width: 1907, height: 250),
];

class _Benchmark extends StatefulWidget {
  const _Benchmark();

  @override
  State<_Benchmark> createState() => _BenchmarkState();
}

class _BenchmarkState extends State<_Benchmark> {
  final _boundaryKey = GlobalKey();
  final _lines = <String>[];
  String _status = 'warming up';

  // The boundary is laid out at whichever size is being measured, so the
  // raster and the readback are both the real ones. Scaling a single large
  // boundary with pixelRatio would have measured neither.
  ({String label, int width, int height}) _current = _sizes.first;

  Future<void> _layoutAt(({String label, int width, int height}) size) {
    final settled = Completer<void>();
    setState(() => _current = size);
    WidgetsBinding.instance.addPostFrameCallback((_) => settled.complete());
    return settled.future;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _log(String line) async {
    _lines.add(line);
    final path = '${Directory.systemTemp.path}\\moonfin_hdr_q4.log';
    try {
      await File(path).writeAsString('$line\n', mode: FileMode.append);
    } catch (_) {
      // The native half logs to the same file; losing a line here is not
      // worth failing the run over.
    }
  }

  Future<void> _run() async {
    await _log('--- toImage/toByteData throughput ---');

    for (final size in _sizes) {
      await _layoutAt(size);

      // A few untimed passes first, so shader compilation and the first
      // allocation do not land in the average.
      for (var i = 0; i < 3; i++) {
        await _captureOnce();
      }

      const runs = 20;
      final watch = Stopwatch()..start();
      var bytes = 0;
      for (var i = 0; i < runs; i++) {
        bytes = await _captureOnce();
      }
      watch.stop();

      final msPerFrame = watch.elapsedMicroseconds / runs / 1000.0;
      final fps = msPerFrame > 0 ? 1000.0 / msPerFrame : 0.0;
      final megabytes = bytes / (1024 * 1024);
      final verdict = fps >= 60
          ? 'comfortable at 60fps'
          : fps >= 30
          ? 'usable, 30fps class'
          : fps >= 15
          ? 'marginal - only if the controls redraw rarely'
          : 'too slow';

      await _log(
        '${size.label.padRight(28)} '
        '${size.width}x${size.height}  '
        '${msPerFrame.toStringAsFixed(1)} ms/frame  '
        '${fps.toStringAsFixed(1)} fps  '
        '${megabytes.toStringAsFixed(1)} MB  '
        '$verdict',
      );
      if (mounted) {
        setState(() => _status = _lines.last);
      }
    }

    await _log('--- done ---');
    if (mounted) {
      setState(() => _status = 'done - see %TEMP%\\moonfin_hdr_q4.log');
    }
  }

  /// One full round trip: raster the boundary, then pull the pixels back to
  /// the CPU in the layout `UpdateLayeredWindow` wants. Returns the byte
  /// count so the log can show what is actually being moved.
  Future<int> _captureOnce() async {
    final boundary =
        _boundaryKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) {
      return 0;
    }
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return data?.lengthInBytes ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Off-screen and unpainted, but laid out at full size so the raster
          // cost is the real one.
          Positioned(
            left: -100000,
            top: 0,
            child: RepaintBoundary(
              key: _boundaryKey,
              child: SizedBox(
                width: _current.width.toDouble(),
                height: _current.height.toDouble(),
                child: const _StandInOsd(),
              ),
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'MOONFIN_HDR_Q4=11  overlay throughput',
                    style: TextStyle(color: Colors.white, fontSize: 22),
                  ),
                  const SizedBox(height: 16),
                  for (final line in _lines)
                    Text(
                      line,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    _status,
                    style: const TextStyle(color: Colors.amber, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The same shape as the player chrome: a scrim fading down from the top, a
/// scrim fading up from the bottom, a progress bar and a row of buttons.
class _StandInOsd extends StatelessWidget {
  const _StandInOsd();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 400,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black.withValues(alpha: 0.7), Colors.transparent],
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.all(48),
              child: Text(
                'Some Movie Title',
                style: TextStyle(color: Colors.white, fontSize: 48),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          height: 500,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black.withValues(alpha: 0.8), Colors.transparent],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 64),
                  child: LinearProgressIndicator(
                    value: 0.42,
                    minHeight: 8,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(Colors.lightBlue),
                  ),
                ),
                const SizedBox(height: 40),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Icon(Icons.favorite, color: Colors.white, size: 48),
                    Icon(Icons.bookmark, color: Colors.white, size: 48),
                    Icon(Icons.subtitles, color: Colors.white, size: 48),
                    Icon(Icons.music_note, color: Colors.white, size: 48),
                    Icon(Icons.cast, color: Colors.white, size: 48),
                    Icon(Icons.volume_up, color: Colors.white, size: 48),
                    Icon(Icons.settings, color: Colors.white, size: 48),
                    Icon(Icons.fullscreen, color: Colors.white, size: 48),
                  ],
                ),
                const SizedBox(height: 60),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
