import 'package:flutter/services.dart';

/// Which band an overlay push belongs to.
///
/// Two bands rather than one full-screen surface because the readback cost of
/// `toImage`/`toByteData` tracks area: 19.2 ms for a whole 4K window against
/// 4.9 ms for a 3814x500 band. Splitting the chrome leaves the clear middle of
/// the screen never read back at all, and leaves the video window overlapped
/// only where controls actually are.
///
/// [full] exists for dialogs, which sit between the bands. It costs the full
/// 19 ms, but a dialog is static, so ~50 fps is ample.
enum HdrOverlayBand {
  top('top'),
  bottom('bottom'),
  full('full');

  const HdrOverlayBand(this.id);
  final String id;
}

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

  /// Pushes one band's pixels. [pixels] must be premultiplied RGBA, which is
  /// what `ImageByteFormat.rawRgba` already produces; the runner swaps the
  /// channel order into BGRA so that work stays off the UI isolate.
  ///
  /// [rect] is in physical pixels relative to the top-level window's client
  /// area, and must match [width] and [height].
  Future<bool> push({
    required HdrOverlayBand band,
    required Rect rect,
    required Uint8List pixels,
    required int width,
    required int height,
  }) async {
    if (_unavailable) return false;
    try {
      await _channel.invokeMethod<void>('push', {
        'id': band.id,
        'x': rect.left.round(),
        'y': rect.top.round(),
        'width': width,
        'height': height,
        'bytes': pixels,
      });
      return true;
    } on MissingPluginException {
      _unavailable = true;
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Hides one band, or every band when [band] is null. The controls auto-hide
  /// during playback, so this is the steady state and it is what keeps the
  /// readback cost at zero while a film is simply playing.
  Future<void> hide([HdrOverlayBand? band]) async {
    if (_unavailable) return;
    try {
      await _channel.invokeMethod<void>('hide', {'id': band?.id ?? ''});
    } on MissingPluginException {
      _unavailable = true;
    } on PlatformException {
      // Nothing to recover: the next push re-establishes the state.
    }
  }

  Future<void> destroy() async {
    if (_unavailable) return;
    try {
      await _channel.invokeMethod<void>('destroy');
    } on MissingPluginException {
      _unavailable = true;
    } on PlatformException {
      // The windows go with the runner either way.
    }
  }
}
