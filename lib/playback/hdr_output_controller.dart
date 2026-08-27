import 'package:flutter/foundation.dart';

import '../util/platform_detection.dart';
import 'hdr_video_window.dart';

/// Why native HDR output is or is not running, for the playback info sheet.
enum HdrOutputReason {
  /// Running: HDR is reaching the display untouched.
  active,
  notWindows,
  disabledByPreference,
  displayNotInHdrMode,
  contentIsSdr,

  /// The window could not be created, or mpv would not take it. Sticky for
  /// the session, and the texture path carries on.
  failed,
}

/// What the decode side reported, mapped to the names users know.
///
/// mpv does not expose the Dolby Vision *profile* number, so that half comes
/// from the server's `VideoRangeType` and is carried alongside. What mpv does
/// report is what actually got decoded, which is what the engage decision has
/// to be based on - server metadata can be absent or wrong.
enum HdrInputFormat {
  sdr,
  hdr10,
  hdr10Plus,
  hlg,
  dolbyVision;

  /// From mpv's `video-params/gamma` and `video-params/primaries`.
  ///
  /// Every HDR transfer function reaching libplacebo comes out as `pq` or
  /// `hlg`; Dolby Vision Profile 5 included, because libplacebo applies the
  /// RPU and converts IPT to BT.2020 PQ before this is readable. So this
  /// distinguishes HDR from SDR reliably, and the finer label is refined by
  /// the server metadata in [describe].
  static HdrInputFormat fromVideoParams(String? gamma, String? primaries) {
    final transfer = gamma?.toLowerCase() ?? '';
    if (transfer == 'pq' || transfer == 'st2084') {
      return HdrInputFormat.hdr10;
    }
    if (transfer == 'hlg') {
      return HdrInputFormat.hlg;
    }
    // bt.2020 primaries with an SDR curve is wide-gamut SDR, not HDR, and
    // must not trigger an HDR display switch.
    return HdrInputFormat.sdr;
  }

  bool get isHdr => this != HdrInputFormat.sdr;
}

/// A snapshot for the diagnostics row in the playback info sheet.
@immutable
class HdrOutputStatus {
  const HdrOutputStatus({
    required this.reason,
    this.input = HdrInputFormat.sdr,
    this.serverRangeType,
  });

  final HdrOutputReason reason;
  final HdrInputFormat input;

  /// Jellyfin's `VideoRangeType`, which is where the Dolby Vision profile
  /// number comes from since mpv does not expose it.
  final String? serverRangeType;

  bool get isActive => reason == HdrOutputReason.active;

  /// What is actually going to the display. Always HDR10 when active: DXGI
  /// carries only static HDR10 metadata, so there is no HDR10+ or Dolby
  /// Vision passthrough on Windows for a normal application. libplacebo
  /// applies the dynamic metadata or the RPU and folds the result into HDR10,
  /// which is the best available - not a shortcut.
  String get output => isActive ? 'HDR10 (PQ, BT.2020)' : 'SDR';
}

/// Decides whether mpv gets its own window, and owns that window's lifetime.
///
/// The decision is made once and then sticks for the process. `Player` and
/// `VideoController` are built once in the `MediaKitPlayerBackend` factory and
/// registered as a startup singleton, so there is no clean way to swap paths
/// per item — and there is no need to. Once engaged, SDR content in the native
/// window is not a regression: mpv renders it, and with `gpu-next` renders it
/// better than the texture path does.
class HdrOutputController {
  HdrOutputController({HdrVideoWindow? window})
    : window = window ?? HdrVideoWindow();

  final HdrVideoWindow window;

  HdrOutputStatus _status = const HdrOutputStatus(
    reason: HdrOutputReason.contentIsSdr,
  );
  HdrOutputStatus get status => _status;

  bool get isEngaged => _engaged;
  bool _engaged = false;

  /// Set when creating the window or handing it to mpv failed. Sticky, so a
  /// broken configuration is not retried on every item.
  bool _failed = false;

  /// Decides and, if the answer is yes, creates the window.
  ///
  /// Returns the HWND to hand mpv as `wid`, or null to stay on the texture
  /// path. [engageMpv] is called with the handle and must return false if mpv
  /// refused it, so the failure is recorded rather than leaving a black window
  /// on screen.
  Future<int?> maybeEngage({
    required bool preferenceEnabled,
    required bool displayInHdrMode,
    required HdrInputFormat input,
    String? serverRangeType,
    required Future<bool> Function(int handle) engageMpv,
  }) async {
    HdrOutputStatus statusFor(HdrOutputReason reason) => HdrOutputStatus(
      reason: reason,
      input: input,
      serverRangeType: serverRangeType,
    );

    if (_engaged) {
      _status = statusFor(HdrOutputReason.active);
      return window.handle;
    }

    if (!PlatformDetection.supportsNativeHdrWindow) {
      _status = statusFor(HdrOutputReason.notWindows);
      return null;
    }
    if (_failed) {
      _status = statusFor(HdrOutputReason.failed);
      return null;
    }
    if (!preferenceEnabled) {
      _status = statusFor(HdrOutputReason.disabledByPreference);
      return null;
    }
    if (!input.isHdr) {
      _status = statusFor(HdrOutputReason.contentIsSdr);
      return null;
    }
    if (!displayInHdrMode) {
      // Switching the display is the auto-HDR preference's job, and it runs
      // before this. If it is off, or the display refused, there is nothing
      // useful to send.
      _status = statusFor(HdrOutputReason.displayNotInHdrMode);
      return null;
    }

    final handle = await window.create();
    if (handle == null) {
      _failed = true;
      _status = statusFor(HdrOutputReason.failed);
      return null;
    }

    if (!await engageMpv(handle)) {
      _failed = true;
      await window.destroy();
      _status = statusFor(HdrOutputReason.failed);
      return null;
    }

    _engaged = true;
    _status = statusFor(HdrOutputReason.active);
    return handle;
  }

  /// Records what the current item is, without changing engagement. Keeps the
  /// diagnostics row honest once the session is already engaged.
  void observe({
    required HdrInputFormat input,
    String? serverRangeType,
  }) {
    _status = HdrOutputStatus(
      reason: _status.reason,
      input: input,
      serverRangeType: serverRangeType,
    );
  }

  Future<void> dispose() => window.destroy();
}
