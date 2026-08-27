import 'package:flutter/material.dart';

import 'hdr_alpha_probe_io.dart'
    if (dart.library.js_interop) 'hdr_alpha_probe_web.dart' as impl;

/// Phase 0, question 4 of `docs/windows-hdr-output-plan.md`: can the Flutter
/// window get per-pixel alpha over the native video window?
///
/// It is the gate that can stop the plan, and it cannot be answered by the
/// standalone `native/hdr_probe` tool, because it is a question about
/// Flutter's own rendering surface. So it is asked inside the real app.
///
/// The runner half lives in `windows/runner/hdr_alpha_probe.{h,cpp}` and reads
/// the same `MOONFIN_HDR_Q4` environment variable, where it stands in for the
/// future mpv window with a child HWND painting a test pattern. This half
/// stops the player screen from painting over that rect.
///
/// Both halves are inert unless the variable is set.
///
/// | Value | Technique |
/// |---|---|
/// | `1` | `SetWindowCompositionAttribute` + `ACCENT_ENABLE_BLURBEHIND` |
/// | `2` | `WS_EX_LAYERED` + `LWA_COLORKEY` |
/// | `3` | `DwmEnableBlurBehindWindow`, null region |
/// | `4` | `SetWindowCompositionAttribute` + `TRANSPARENTGRADIENT` |
abstract class HdrAlphaProbe {
  /// Zero when off, otherwise the technique the runner applied.
  static final int mode = impl.readMode();

  static bool get isActive => mode != 0;

  /// What the player paints over the video rect while the probe runs.
  ///
  /// Nothing, so the stand-in window shows through - except under the colour
  /// key, which has to actually be painted for it to key anything out.
  /// Mirrors `kColorKeyValue` in `hdr_alpha_probe.h`.
  static Color get videoRectColor =>
      mode == 2 ? const Color(0xFF010001) : Colors.transparent;
}
