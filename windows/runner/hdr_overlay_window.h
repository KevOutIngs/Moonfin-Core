#ifndef RUNNER_HDR_OVERLAY_WINDOW_H_
#define RUNNER_HDR_OVERLAY_WINDOW_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <cstdint>
#include <memory>
#include <vector>

// The player controls, drawn over the HDR video window.
//
// Phase 0 established that nothing shows through the Flutter surface on
// Windows - ten techniques, every one of them blank - so the controls cannot
// simply be left where they are with the video behind them. What does work is
// UpdateLayeredWindow: it is the only Win32 API that gives genuine per-pixel
// alpha over an arbitrary window, which is what the player's scrim gradients
// need and what a colour key could never reproduce.
//
// Flutter renders the control chrome off-screen and pushes it here as
// premultiplied pixels, covering the whole player. Readback cost tracks area,
// so splitting the chrome into top and bottom bands and leaving the clear
// middle alone would be roughly 4x cheaper again - see the measurements in
// docs/windows-hdr-output-plan.md. That split is not implemented: the chrome
// builders return Positioned widgets and the centre transport controls sit
// between the bands, so it needs the player's own layout refactored first.
class HdrOverlayWindow {
 public:
  HdrOverlayWindow(flutter::BinaryMessenger* messenger,
                   flutter::PluginRegistrarWindows* registrar);
  ~HdrOverlayWindow();

  HdrOverlayWindow(const HdrOverlayWindow&) = delete;
  HdrOverlayWindow& operator=(const HdrOverlayWindow&) = delete;

  // Re-derives the window's screen position from the client rect it was last
  // given. The overlay is top-level, so it is positioned in screen space and
  // does not follow the runner window on its own when that window is dragged.
  void SyncPosition();

 private:
  void HandleMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Blits |pixels| - premultiplied RGBA, row-primary, as Flutter's
  // ImageByteFormat.rawRgba produces it - into the overlay, creating and
  // sizing it as needed. |rect| is in client coordinates of the top-level.
  bool Push(const RECT& rect, const std::vector<uint8_t>& pixels, int width,
            int height);
  void Hide();

  // Drops the cached GDI objects. They are rebuilt on the next push.
  void ReleaseSurface();

  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND top_level_ = nullptr;
  HWND window_ = nullptr;
  bool visible_ = false;

  // The DIB and its DC are kept between pushes and rebuilt only when the size
  // changes. Recreating them per frame meant committing and kernel-zeroing
  // ~30 MB, then taking a soft fault on every one of its ~7,400 pages while
  // writing the pixels - several milliseconds a frame, on the thread that
  // pumps the Win32 message loop.
  HDC memory_dc_ = nullptr;
  HBITMAP bitmap_ = nullptr;
  HGDIOBJ previous_bitmap_ = nullptr;
  void* bits_ = nullptr;
  int width_ = 0;
  int height_ = 0;

  // Last client rect, so SyncPosition can re-derive the screen origin.
  RECT client_rect_ = {};
};

#endif  // RUNNER_HDR_OVERLAY_WINDOW_H_
