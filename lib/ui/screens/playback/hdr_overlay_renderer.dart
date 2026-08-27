import 'dart:async';
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
    required this.enabled,
    required this.channel,
    required this.child,
  });

  /// Capture only while mpv owns its own window. False leaves the subtree
  /// completely untouched, which is what lets the call site wrap
  /// unconditionally and keep one element identity across engage/disengage -
  /// branching there cost the player its keyboard focus.
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

  /// Floor on how often the overlay is re-sent.
  ///
  /// The only continuously-moving pixel is the seek bar, which at 4K advances
  /// one physical pixel every couple of seconds of a feature film, and the
  /// remaining-time label changes once a second. Capturing at the display's
  /// frame rate spent the whole readback - tens of megabytes - redrawing
  /// pixels that had not changed.
  static const _minInterval = Duration(milliseconds: 66);
  final _sinceLastCapture = Stopwatch();

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
      widget.channel.hide();
    }
  }

  @override
  void dispose() {
    if (widget.enabled) widget.channel.hide();
    super.dispose();
  }

  void _schedule() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_capture());
    });
  }

  Future<void> _capture() async {
    if (!mounted || !widget.enabled || _capturing) return;
    if (_sinceLastCapture.isRunning &&
        _sinceLastCapture.elapsed < _minInterval) {
      _schedule();
      return;
    }
    final context = _boundaryKey.currentContext;
    final boundary = context?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null || !boundary.hasSize) {
      _schedule();
      return;
    }

    _capturing = true;
    _sinceLastCapture
      ..reset()
      ..start();
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

      // `data == null` is a documented outcome of toByteData, and returning
      // here would skip the reschedule below and freeze the overlay on its
      // last bitmap for the rest of the screen's life. Fall through instead.
      if (data != null && mounted && widget.enabled) {
        final origin = boundary.localToGlobal(Offset.zero) * ratio;
        await widget.channel.push(
          x: origin.dx,
          y: origin.dy,
          pixels: data.buffer.asUint8List(),
          width: width,
          height: height,
        );
      }
    } catch (_) {
      // A capture can fail while the tree is being torn down. The next frame
      // either retries or the widget is gone.
    } finally {
      _capturing = false;
    }

    if (mounted && widget.enabled) _schedule();
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
    required this.onDetached,
  });

  /// Called with the video rect in physical pixels, relative to the top-level
  /// window's client area, whenever it changes.
  final void Function(Rect rect) onGeometry;

  /// Called when this widget goes away, so the window can be released by
  /// whoever still owns it.
  final VoidCallback onDetached;

  @override
  State<HdrVideoGeometry> createState() => _HdrVideoGeometryState();
}

class _HdrVideoGeometryState extends State<HdrVideoGeometry> {
  Rect? _last;

  void _report() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final ratio = MediaQuery.devicePixelRatioOf(context);
    final origin = box.localToGlobal(Offset.zero) * ratio;
    final rect = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      box.size.width * ratio,
      box.size.height * ratio,
    );
    if (rect == _last) return;
    _last = rect;
    widget.onGeometry(rect);
  }

  @override
  void dispose() {
    widget.onDetached();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Once per layout, not once per frame. An earlier version re-asserted on
    // every frame to survive the dispose/build race between two player-screen
    // states - `localToGlobal` walks the whole ancestor chain, so that was
    // several microseconds and a few hundred bytes of garbage per frame for
    // the length of a film. The race is closed properly now, by
    // HdrVideoWindow.claim/release taking ownership by identity.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _report();
    });
    return const SizedBox.expand();
  }
}
