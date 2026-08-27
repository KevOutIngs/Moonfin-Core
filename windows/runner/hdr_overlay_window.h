#ifndef RUNNER_HDR_OVERLAY_WINDOW_H_
#define RUNNER_HDR_OVERLAY_WINDOW_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <map>
#include <memory>
#include <string>
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
// premultiplied pixels. Cost tracks area - 19.2 ms for a whole 4K window
// against 4.9 ms for a 3814x500 band - so the controls are pushed as separate
// bands and the clear middle of the screen is never read back at all. The
// full-window band exists only for dialogs, which sit between the bands.
//
// See docs/windows-hdr-output-plan.md.
class HdrOverlayWindow {
 public:
  HdrOverlayWindow(flutter::BinaryMessenger* messenger,
                   flutter::PluginRegistrarWindows* registrar);
  ~HdrOverlayWindow();

  HdrOverlayWindow(const HdrOverlayWindow&) = delete;
  HdrOverlayWindow& operator=(const HdrOverlayWindow&) = delete;

 private:
  // One layered window per band. Bands are addressed by name from Dart
  // ("top", "bottom", "full") rather than by index, so adding one later does
  // not renumber the others.
  struct Band {
    HWND window = nullptr;
    bool visible = false;
  };

  void HandleMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Creates the band's window if needed, moves it to |rect| in client
  // coordinates of the top-level window, and blits |pixels| into it.
  // |pixels| is premultiplied RGBA, row-primary, as Flutter's
  // ImageByteFormat.rawRgba produces it.
  bool Push(const std::string& id, const RECT& rect,
            const std::vector<uint8_t>& pixels, int width, int height);
  void Hide(const std::string& id);
  void DestroyAll();

  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::map<std::string, Band> bands_;
  HWND top_level_ = nullptr;

  // Where the keyboard has to stay: showing an owned window can shift focus,
  // and the widgets behind these pixels are the ones expecting the keys.
  HWND flutter_view_ = nullptr;
};

#endif  // RUNNER_HDR_OVERLAY_WINDOW_H_
