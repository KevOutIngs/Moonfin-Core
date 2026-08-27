import 'package:flutter/services.dart';

/// Dart side of `windows/runner/hdr_overlay_window.cpp`: the player controls,
/// composited over the HDR video window with real per-pixel alpha.
///
/// Phase 0 established that nothing shows through the Flutter surface on
/// Windows, so the controls cannot stay where they are with video behind them.
/// `UpdateLayeredWindow` is the only Win32 call that blends a gradient over an
/// arbitrary window correctly, which is exactly what the player's scrims need.
/// See docs/windows-hdr-output-plan.md.
class HdrOverlayChannel {
  static const MethodChannel _channel = MethodChannel('moonfin/hdr_overlay');

  bool _unavailable = false;

  Future<T?> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    if (_unavailable) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // Not a Windows build, or a runner predating the channel.
      _unavailable = true;
      return null;
    } on PlatformException {
      // Nothing to recover: the next push re-establishes the state.
      return null;
    }
  }

  /// Pushes the overlay's pixels. [pixels] must be premultiplied RGBA, which
  /// is what `ImageByteFormat.rawRgba` already produces; the runner swaps the
  /// channel order into BGRA so that work stays off the UI isolate.
  ///
  /// [x] and [y] are in physical pixels relative to the top-level window's
  /// client area, and [width]/[height] must match [pixels].
  Future<void> push({
    required double x,
    required double y,
    required Uint8List pixels,
    required int width,
    required int height,
  }) => _invoke<void>('push', {
    'x': x.round(),
    'y': y.round(),
    'width': width,
    'height': height,
    'bytes': pixels,
  });

  /// Hides the overlay. The controls auto-hide during playback, so this is the
  /// steady state and it is what keeps the readback cost at zero while a film
  /// is simply playing.
  Future<void> hide() => _invoke<void>('hide');
}
