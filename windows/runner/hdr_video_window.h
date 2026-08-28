#ifndef RUNNER_HDR_VIDEO_WINDOW_H_
#define RUNNER_HDR_VIDEO_WINDOW_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

// The window mpv renders HDR video into, on Windows.
//
// media_kit's texture path allocates B8G8R8A8_UNORM and mpv draws into it
// through the OpenGL render API, so every HDR stream is flattened to 8-bit SDR
// before Flutter composites it. target-colorspace-hint cannot fix that: it tags
// a swapchain, and on the render API mpv owns none. So mpv needs a window of
// its own, which is what this creates - the runner owns lifetime and geometry,
// mpv creates and owns the D3D11 swapchain once it is handed the HWND.
//
// The window comes in two arrangements, chosen by the MOONFIN_HDR_DWM
// environment variable at startup:
//
//  - Default: a child HWND *above* the Flutter view. Flutter's UI is then
//    re-composited over the video by hdr_overlay_window, because nothing shows
//    through the Flutter view from below.
//  - MOONFIN_HDR_DWM=1..4: a top-level window *behind* the whole runner
//    window, with the runner window given per-pixel DWM transparency (see
//    hdr_window_support::ApplyTransparencyComposition for the techniques).
//    If that composition holds, Flutter draws everything - controls, dialogs,
//    OSD - natively over the video, and no capture is needed at all.
//
// See docs/windows-hdr-output-plan.md.
class HdrVideoWindow {
 public:
  // |top_level| is passed explicitly rather than derived from the registrar.
  // These windows are constructed during FlutterWindow::OnCreate, *before*
  // SetChildContent parents the Flutter view into the runner - at that moment
  // GetAncestor(view, GA_ROOT) is the view itself, and everything hung off it
  // silently went to the wrong window: DWM transparency applied to a child
  // (fails), z-order inserted relative to a child (video lands above the
  // runner), position sync against the wrong rect.
  HdrVideoWindow(flutter::BinaryMessenger* messenger,
                 flutter::PluginRegistrarWindows* registrar, HWND top_level);
  ~HdrVideoWindow();

  HdrVideoWindow(const HdrVideoWindow&) = delete;
  HdrVideoWindow& operator=(const HdrVideoWindow&) = delete;

  // Re-fits a behind-the-window video window to the runner's client area and
  // keeps it directly below in the z-order. Called from the runner's
  // WM_WINDOWPOSCHANGED, so it follows moves, resizes and z-order changes.
  // No-op in the child arrangement, where the window follows for free.
  void SyncPosition();

 private:
  void HandleMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  int64_t Create();
  void SetGeometry(int x, int y, int width, int height);
  void SetVisible(bool visible);
  void Destroy();

  // Places the behind-mode window at its screen rect, directly below the
  // runner window. |show| also makes it visible without activating it.
  void PlaceBehind(bool show);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  HWND top_level_ = nullptr;
  HWND flutter_view_ = nullptr;
  HWND window_ = nullptr;

  // Client-area rect of the video, as Dart reports it.
  RECT geometry_ = {};

  // 0 = child above (the default). 1..4 = top-level behind, with the matching
  // transparency technique applied to the runner window.
  int dwm_mode_ = 0;

  bool behind() const { return dwm_mode_ != 0; }
};

#endif  // RUNNER_HDR_VIDEO_WINDOW_H_
