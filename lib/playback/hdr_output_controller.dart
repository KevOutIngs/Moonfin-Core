import 'package:flutter/foundation.dart';

import 'hdr_video_window.dart';

/// Why native HDR output is or is not running, for the playback info sheet.
enum HdrOutputReason {
  /// Running: HDR is reaching the display untouched.
  active,
  disabledByPreference,
  displayNotInHdrMode,
  contentIsSdr,

  /// The window could not be created, or mpv would not take it. Sticky for
  /// the session, and the texture path carries on.
  failed,
}

/// A snapshot for the diagnostics row in the playback info sheet.
@immutable
class HdrOutputStatus {
  const HdrOutputStatus(this.reason);

  final HdrOutputReason reason;

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
  final HdrVideoWindow window = HdrVideoWindow();

  // One field, not three. `_engaged` and `_failed` were separate booleans that
  // were only ever set one line before the matching status, so they could not
  // disagree with it - they just had to be kept in step by hand on every
  // return path.
  HdrOutputStatus _status = const HdrOutputStatus(
    HdrOutputReason.contentIsSdr,
  );
  HdrOutputStatus get status => _status;

  bool get isEngaged => _status.reason == HdrOutputReason.active;

  /// Whether a previous attempt failed. Sticky, so a broken configuration is
  /// not retried on every item; the caller uses it to skip the work of even
  /// deciding.
  bool get hasFailed => _status.reason == HdrOutputReason.failed;

  /// Decides and, if the answer is yes, creates the window.
  ///
  /// Returns the HWND to hand mpv as `wid`, or null to stay on the texture
  /// path. [displayInHdrMode] is a callback rather than a value so the
  /// display-config enumeration behind it is not paid for SDR content, which
  /// is the common case. [engageMpv] must return false if mpv refused the
  /// handle, so the failure is recorded rather than leaving a black window on
  /// screen.
  Future<int?> maybeEngage({
    required bool preferenceEnabled,
    required bool isHdrContent,
    required Future<bool> Function() displayInHdrMode,
    required Future<bool> Function(int handle) engageMpv,
  }) async {
    if (isEngaged) {
      return window.handle;
    }
    if (hasFailed) {
      return null;
    }
    if (!preferenceEnabled) {
      _status = const HdrOutputStatus(HdrOutputReason.disabledByPreference);
      return null;
    }
    if (!isHdrContent) {
      _status = const HdrOutputStatus(HdrOutputReason.contentIsSdr);
      return null;
    }
    if (!await displayInHdrMode()) {
      // Switching the display is the auto-HDR preference's job, and it runs
      // before this. If it is off, or the display refused, there is nothing
      // useful to send.
      _status = const HdrOutputStatus(HdrOutputReason.displayNotInHdrMode);
      return null;
    }

    final handle = await window.create();
    if (handle == null) {
      _status = const HdrOutputStatus(HdrOutputReason.failed);
      return null;
    }

    if (!await engageMpv(handle)) {
      await window.destroy();
      _status = const HdrOutputStatus(HdrOutputReason.failed);
      return null;
    }

    _status = const HdrOutputStatus(HdrOutputReason.active);
    return handle;
  }
}

/// Whether what mpv decoded is HDR.
///
/// mpv is the better source than the server's `VideoRangeType`, which can be
/// missing or wrong — what matters is what actually decoded. But it cannot
/// answer for **Dolby Vision Profile 5**: that has no HDR10 base layer and
/// frequently no VUI transfer characteristic, so the picture is IPT and only
/// becomes BT.2020 PQ once libplacebo applies the RPU — which happens under
/// `gpu-next`, which is the very thing being decided. mpv reports a P5 title
/// as SDR right up until it stops being one.
///
/// BT.2020 primaries break that tie: IPT is carried on them, so they are
/// present even when the transfer characteristic is not. Wide-gamut SDR also
/// matches, and the cost of being wrong there is only that mpv tone-maps in
/// its own window rather than the texture, on a display already in HDR mode
/// since that is a precondition for reaching this at all.
bool isHdrVideoParams({required String? gamma, required String? primaries}) {
  final transfer = gamma?.toLowerCase() ?? '';
  if (transfer == 'pq' || transfer == 'st2084' || transfer == 'hlg') {
    return true;
  }
  return (primaries?.toLowerCase() ?? '').contains('2020');
}
