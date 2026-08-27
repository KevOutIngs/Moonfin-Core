import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../../playback/hdr_overlay_channel.dart';

/// Mirrors part of the player chrome into a layered window above the HDR
/// video window.
///
/// While native HDR output is running, mpv draws into its own window, which
/// covers the Flutter view. The widget tree underneath is left exactly as it
/// is - still laid out, still hit-tested, still holding focus - because the
/// video window and the overlays are both `WS_EX_TRANSPARENT`, so clicks fall
/// straight through to it. Only the *pixels* have to be re-sent, which is what
/// this does.
///
/// Wrapping a subtree in this changes nothing when [enabled] is false, so the
/// texture path is untouched.
///
/// See docs/windows-hdr-output-plan.md.
class HdrOverlayCapture extends StatefulWidget {
  const HdrOverlayCapture({
    super.key,
    required this.band,
    required this.enabled,
    required this.channel,
    required this.child,
  });

  final HdrOverlayBand band;

  /// Capture only while the chrome is actually on screen. The controls
  /// auto-hide during playback, so the steady state is no readback at all.
  final bool enabled;

  final HdrOverlayChannel channel;
  final Widget child;

  @override
  State<HdrOverlayCapture> createState() => _HdrOverlayCaptureState();
}

class _HdrOverlayCaptureState extends State<HdrOverlayCapture> {
  final _boundaryKey = GlobalKey();

  /// One capture in flight at a time. `toByteData` is a GPU-to-CPU readback,
  /// so overlapping calls would queue up behind each other and the overlay
  /// would drift further behind the widget tree with every frame.
  bool _capturing = false;
  bool _scheduled = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _schedule();
  }

  @override
  void didUpdateWidget(HdrOverlayCapture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && !oldWidget.enabled) {
      _schedule();
    } else if (!widget.enabled && oldWidget.enabled) {
      widget.channel.hide(widget.band);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    widget.channel.hide(widget.band);
    super.dispose();
  }

  void _schedule() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _capture();
    });
  }

  Future<void> _capture() async {
    if (_disposed || !widget.enabled || _capturing) return;
    final context = _boundaryKey.currentContext;
    final boundary = context?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || !boundary.hasSize) {
      _schedule();
      return;
    }

    _capturing = true;
    try {
      // Physical pixels: the layered window is sized in them, and rendering
      // at the logical size would upscale the chrome on a high-DPI display.
      final ratio = MediaQuery.devicePixelRatioOf(context!);
      final image = await boundary.toImage(pixelRatio: ratio);
      // rawRgba is premultiplied, which is what AC_SRC_ALPHA wants. The
      // runner swaps RGBA to BGRA so that loop stays off this isolate.
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final width = image.width;
      final height = image.height;
      image.dispose();

      if (data == null || _disposed || !widget.enabled) return;

      final origin = boundary.localToGlobal(Offset.zero) * ratio;
      await widget.channel.push(
        band: widget.band,
        rect: Rect.fromLTWH(
          origin.dx,
          origin.dy,
          width.toDouble(),
          height.toDouble(),
        ),
        pixels: data.buffer.asUint8List(),
        width: width,
        height: height,
      );
    } catch (_) {
      // A capture can fail while the tree is being torn down. The next frame
      // either retries or the widget is gone.
    } finally {
      _capturing = false;
    }

    if (widget.enabled) _schedule();
  }

  @override
  Widget build(BuildContext context) {
    // The boundary is always present, so toggling [enabled] never forces a
    // relayout of the chrome underneath it.
    return RepaintBoundary(key: _boundaryKey, child: widget.child);
  }
}

/// Reports where the video should be, so the native window can be moved there.
///
/// Takes the place of the `Video` widget while native HDR output is running:
/// mpv is drawing into its own window, so there is nothing for Flutter to
/// paint here, but the rect still has to be measured from the same layout the
/// texture path would have used.
class HdrVideoGeometry extends StatefulWidget {
  const HdrVideoGeometry({
    super.key,
    required this.onGeometry,
  });

  /// Called with the video rect in physical pixels, relative to the top-level
  /// window's client area.
  final void Function(Rect rect) onGeometry;

  @override
  State<HdrVideoGeometry> createState() => _HdrVideoGeometryState();
}

class _HdrVideoGeometryState extends State<HdrVideoGeometry> {
  void _report() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final origin = box.localToGlobal(Offset.zero) * ratio;
    widget.onGeometry(
      Rect.fromLTWH(
        origin.dx,
        origin.dy,
        box.size.width * ratio,
        box.size.height * ratio,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _scheduleReport();
  }

  // Re-asserts on every frame rather than only when the rect changes, and lets
  // HdrVideoWindow drop the duplicates, so no channel traffic follows the
  // first report. Reporting only on change lost a race: when the player screen
  // is rebuilt, the outgoing state's dispose hides the window *after* the
  // incoming one has asked for it to be shown, and with a change-only report
  // nothing ever asked again - leaving mpv rendering into a window nobody
  // could see. Re-asserting recovers on the very next frame.
  void _scheduleReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _report();
      _scheduleReport();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
