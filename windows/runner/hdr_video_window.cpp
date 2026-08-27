#include "hdr_video_window.h"

#include <flutter/standard_method_codec.h>

#include <string>

#include "hdr_window_support.h"

namespace {

constexpr const wchar_t kWindowClassName[] = L"MOONFIN_HDR_VIDEO";

}  // namespace

HdrVideoWindow::HdrVideoWindow(flutter::BinaryMessenger* messenger,
                               flutter::PluginRegistrarWindows* registrar) {
  if (registrar != nullptr && registrar->GetView() != nullptr) {
    flutter_view_ = registrar->GetView()->GetNativeWindow();
  }
  top_level_ = hdr_window_support::TopLevelOf(registrar);

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "moonfin/hdr_video",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethod(call, std::move(result));
  });
}

HdrVideoWindow::~HdrVideoWindow() { Destroy(); }

void HdrVideoWindow::HandleMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap empty;
  const flutter::EncodableMap& map = args != nullptr ? *args : empty;
  const std::string& method = call.method_name();

  if (method == "create") {
    const int64_t handle = Create();
    if (handle == 0) {
      result->Error("create_failed", "could not create the video window");
      return;
    }
    result->Success(flutter::EncodableValue(handle));
    return;
  }

  if (method == "setGeometry") {
    SetGeometry(hdr_window_support::GetInt(map, "x", 0),
                hdr_window_support::GetInt(map, "y", 0),
                hdr_window_support::GetInt(map, "width", 0),
                hdr_window_support::GetInt(map, "height", 0));
    result->Success();
    return;
  }

  if (method == "setVisible") {
    SetVisible(hdr_window_support::GetBool(map, "visible", false));
    result->Success();
    return;
  }

  if (method == "destroy") {
    Destroy();
    result->Success();
    return;
  }

  result->NotImplemented();
}

int64_t HdrVideoWindow::Create() {
  if (window_ != nullptr) {
    return reinterpret_cast<int64_t>(window_);
  }
  if (top_level_ == nullptr) {
    return 0;
  }
  if (!hdr_window_support::EnsureWindowClass(
          kWindowClassName, hdr_window_support::ClickThroughWndProc)) {
    return 0;
  }

  // Without WS_CLIPSIBLINGS on the Flutter view, its swapchain present paints
  // straight over any overlapping sibling and nothing ever sends the sibling a
  // WM_PAINT to put it back. That silently produced a full round of false
  // results during the Phase 0 spike, so it is set before the window exists
  // rather than after.
  if (flutter_view_ != nullptr) {
    const LONG_PTR view_style = GetWindowLongPtr(flutter_view_, GWL_STYLE);
    if ((view_style & WS_CLIPSIBLINGS) == 0) {
      SetWindowLongPtr(flutter_view_, GWL_STYLE, view_style | WS_CLIPSIBLINGS);
      SetWindowPos(flutter_view_, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                       SWP_FRAMECHANGED);
    }
  }

  // Dart has not laid anything out yet when this runs - the handle is needed
  // before the widget that would measure the video rect can exist - so fall
  // back to the whole client area rather than the empty default. A zero-area
  // window would be handed straight to mpv as `wid`, and its D3D11 context
  // fails CreateSwapChainForHwnd on one, which marks the session permanently
  // failed before the first frame.
  if (geometry_.right <= geometry_.left || geometry_.bottom <= geometry_.top) {
    GetClientRect(top_level_, &geometry_);
  }

  // WS_EX_TRANSPARENT and the shared window proc's HTTRANSPARENT keep this
  // window out of hit-testing, so clicks fall through to the Flutter view
  // underneath where the player's widgets are still laid out. That is what
  // lets input, focus and keyboard keep working untouched.
  window_ = CreateWindowEx(
      WS_EX_TRANSPARENT | WS_EX_NOPARENTNOTIFY, kWindowClassName, L"",
      WS_CHILD | WS_CLIPSIBLINGS, geometry_.left, geometry_.top,
      geometry_.right - geometry_.left, geometry_.bottom - geometry_.top,
      top_level_, nullptr, GetModuleHandle(nullptr), nullptr);
  if (window_ == nullptr) {
    return 0;
  }

  // Above the Flutter view. The controls that used to be composited over the
  // video by Flutter now live in the layered overlay window instead.
  SetWindowPos(window_, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  return reinterpret_cast<int64_t>(window_);
}

void HdrVideoWindow::SetGeometry(int x, int y, int width, int height) {
  geometry_ = RECT{x, y, x + width, y + height};
  if (window_ == nullptr || width <= 0 || height <= 0) {
    return;
  }
  SetWindowPos(window_, HWND_TOP, x, y, width, height, SWP_NOACTIVATE);
}

void HdrVideoWindow::SetVisible(bool visible) {
  if (window_ == nullptr) {
    return;
  }
  ShowWindow(window_, visible ? SW_SHOWNOACTIVATE : SW_HIDE);
  if (visible) {
    SetWindowPos(window_, HWND_TOP, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

void HdrVideoWindow::Destroy() {
  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
}
