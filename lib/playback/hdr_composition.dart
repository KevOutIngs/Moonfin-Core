import 'hdr_composition_stub.dart'
    if (dart.library.io) 'hdr_composition_io.dart' as impl;

/// How the native HDR video window is composited with the Flutter UI.
///
/// The default arrangement puts mpv's window *above* the Flutter view and
/// re-composites the UI over it through the layered overlay - workable, but
/// menus need the video stood down and everything runs through a per-frame
/// readback.
///
/// `MOONFIN_HDR_DWM=1..4` switches to the arrangement worth wanting: mpv in a
/// top-level window *behind* the runner window, which is given per-pixel DWM
/// transparency, so Flutter draws controls, dialogs and OSD natively over the
/// video with real alpha and no capture at all. Phase 0 wrote this off, but
/// every one of those tests sampled over opaque Flutter content - the home
/// screen's poster backdrop or the player route's black ModalBarrier - so the
/// question was never validly asked. The runner reads the same variable and
/// picks the matching window arrangement; this flag is what turns the Dart
/// side's capture machinery off and its backgrounds transparent.
abstract final class HdrComposition {
  /// 0 = overlay capture (default). 1..4 = DWM transparency technique.
  static final int dwmMode = impl.readDwmMode();

  /// Whether the video window sits behind a transparent Flutter window, so
  /// no capture or stand-down is needed.
  static bool get videoBehindFlutter => dwmMode != 0;
}
