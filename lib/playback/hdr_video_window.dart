import 'package:flutter/services.dart';

/// Dart side of `windows/runner/hdr_video_window.cpp`: the window mpv renders
/// HDR video into.
///
/// The runner owns nothing but the window's lifetime and geometry. mpv creates
/// and owns the D3D11 swapchain once it is handed the HWND as `wid`, which is
/// what makes `target-colorspace-hint` able to tag anything - on the shared
/// texture path there is no swapchain to tag, which is the whole reason this
/// exists. See docs/windows-hdr-output-plan.md.
class HdrVideoWindow {
  static const MethodChannel _channel = MethodChannel('moonfin/hdr_video');

  int? _handle;
  Rect? _geometry;
  bool _visible = false;
  bool _unavailable = false;

  /// The HWND, once created. Null until [create] succeeds.
  int? get handle => _handle;

  bool get isCreated => _handle != null;

  /// Creates the window and returns its HWND, or null if it could not be
  /// created. Safe to call repeatedly; the second call returns the same
  /// handle.
  Future<int?> create() async {
    if (_handle != null) return _handle;
    if (_unavailable) return null;
    try {
      final handle = await _channel.invokeMethod<int>('create');
      if (handle == null || handle == 0) return null;
      _handle = handle;
      return handle;
    } on MissingPluginException {
      // Not a Windows build, or the runner predates the channel.
      _unavailable = true;
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Moves the window to [rect], in physical pixels relative to the top-level
  /// window's client area.
  Future<void> setGeometry(Rect rect) async {
    if (_handle == null) return;
    if (_geometry == rect) return;
    _geometry = rect;
    try {
      await _channel.invokeMethod<void>('setGeometry', {
        'x': rect.left.round(),
        'y': rect.top.round(),
        'width': rect.width.round(),
        'height': rect.height.round(),
      });
    } on PlatformException {
      // Geometry is pushed again on the next layout, so a dropped update
      // corrects itself.
    }
  }

  Future<void> setVisible(bool visible) async {
    if (_handle == null || _visible == visible) return;
    _visible = visible;
    try {
      await _channel.invokeMethod<void>('setVisible', {'visible': visible});
    } on PlatformException {
      _visible = !visible;
    }
  }

  Future<void> destroy() async {
    if (_handle == null) return;
    _handle = null;
    _geometry = null;
    _visible = false;
    try {
      await _channel.invokeMethod<void>('destroy');
    } on PlatformException {
      // The window goes with the runner either way.
    }
  }
}
