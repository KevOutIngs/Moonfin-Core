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
// See docs/windows-hdr-output-plan.md. The controls that used to sit over the
// video in the Flutter surface move to hdr_overlay_window, because Phase 0
// established that nothing shows through the Flutter surface.
class HdrVideoWindow {
 public:
  // |registrar| supplies the Flutter view, whose HWND this window is parented
  // beside and whose style has to be corrected - see the WS_CLIPSIBLINGS note
  // in Create().
  HdrVideoWindow(flutter::BinaryMessenger* messenger,
                 flutter::PluginRegistrarWindows* registrar);
  ~HdrVideoWindow();

  HdrVideoWindow(const HdrVideoWindow&) = delete;
  HdrVideoWindow& operator=(const HdrVideoWindow&) = delete;

 private:
  void HandleMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Creates the child window if it does not exist. Returns its HWND as an
  // integer for Dart to hand to mpv as `wid`, or 0 on failure.
  int64_t Create();
  void SetGeometry(int x, int y, int width, int height);
  void SetVisible(bool visible);
  void Destroy();
  flutter::EncodableValue State() const;

  // Puts the keyboard back on the Flutter view after this window is created or
  // shown. Only the pixels moved to the native window; every key still has to
  // reach the widgets.
  void RestoreFocusToFlutterView();

  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // The top-level runner window, and the Flutter view inside it. The video
  // window is a sibling of the view, parented to the top level, so it inherits
  // the runner's geometry, DPI and lifetime handling.
  HWND top_level_ = nullptr;
  HWND flutter_view_ = nullptr;
  HWND window_ = nullptr;

  RECT geometry_ = {};
  bool visible_ = false;
};

#endif  // RUNNER_HDR_VIDEO_WINDOW_H_
