#include "hdr_video_window.h"

#include <flutter/standard_method_codec.h>

#include <string>

namespace {

constexpr const wchar_t kWindowClassName[] = L"MOONFIN_HDR_VIDEO";

int GetInt(const flutter::EncodableMap& map, const char* key, int fallback) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it != map.end()) {
    if (const auto* value = std::get_if<int>(&it->second)) {
      return *value;
    }
    if (const auto* value = std::get_if<int64_t>(&it->second)) {
      return static_cast<int>(*value);
    }
  }
  return fallback;
}

bool GetBool(const flutter::EncodableMap& map, const char* key, bool fallback) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it != map.end()) {
    if (const auto* value = std::get_if<bool>(&it->second)) {
      return *value;
    }
  }
  return fallback;
}

}  // namespace

HdrVideoWindow::HdrVideoWindow(flutter::BinaryMessenger* messenger,
                               flutter::PluginRegistrarWindows* registrar) {
  if (registrar != nullptr && registrar->GetView() != nullptr) {
    flutter_view_ = registrar->GetView()->GetNativeWindow();
    top_level_ = GetAncestor(flutter_view_, GA_ROOT);
  }

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
    SetGeometry(GetInt(map, "x", 0), GetInt(map, "y", 0),
                GetInt(map, "width", 0), GetInt(map, "height", 0));
    result->Success();
    return;
  }

  if (method == "setVisible") {
    SetVisible(GetBool(map, "visible", false));
    result->Success();
    return;
  }

  if (method == "destroy") {
    Destroy();
    result->Success();
    return;
  }

  if (method == "getState") {
    result->Success(State());
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

  static bool class_registered = false;
  if (!class_registered) {
    WNDCLASS window_class = {};
    window_class.lpfnWndProc = HdrVideoWindow::WndProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.lpszClassName = kWindowClassName;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    // mpv paints every pixel through its own swapchain, so a background brush
    // would only ever be a flash of the wrong colour on resize.
    window_class.hbrBackground = nullptr;
    if (RegisterClass(&window_class) == 0) {
      return 0;
    }
    class_registered = true;
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

  // WS_EX_TRANSPARENT keeps the window out of hit-testing, so clicks fall
  // through to the Flutter view underneath, where the player's widgets are
  // still laid out at the same coordinates. That is what lets input, focus and
  // keyboard keep working untouched while the video is drawn on top.
  window_ = CreateWindowEx(
      WS_EX_TRANSPARENT | WS_EX_NOPARENTNOTIFY, kWindowClassName, L"",
      WS_CHILD | WS_CLIPSIBLINGS, geometry_.left, geometry_.top,
      geometry_.right - geometry_.left, geometry_.bottom - geometry_.top,
      top_level_, nullptr, GetModuleHandle(nullptr), nullptr);
  if (window_ == nullptr) {
    return 0;
  }

  // Above the Flutter view. The controls that used to be composited over the
  // video by Flutter now live in the layered overlay windows instead.
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
  visible_ = visible;
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
  visible_ = false;
}

flutter::EncodableValue HdrVideoWindow::State() const {
  flutter::EncodableMap state;
  state[flutter::EncodableValue("created")] =
      flutter::EncodableValue(window_ != nullptr);
  state[flutter::EncodableValue("visible")] =
      flutter::EncodableValue(visible_ && window_ != nullptr);
  state[flutter::EncodableValue("hwnd")] =
      flutter::EncodableValue(reinterpret_cast<int64_t>(window_));
  state[flutter::EncodableValue("x")] = flutter::EncodableValue(
      static_cast<int64_t>(geometry_.left));
  state[flutter::EncodableValue("y")] = flutter::EncodableValue(
      static_cast<int64_t>(geometry_.top));
  state[flutter::EncodableValue("width")] = flutter::EncodableValue(
      static_cast<int64_t>(geometry_.right - geometry_.left));
  state[flutter::EncodableValue("height")] = flutter::EncodableValue(
      static_cast<int64_t>(geometry_.bottom - geometry_.top));
  return flutter::EncodableValue(state);
}

// static
LRESULT CALLBACK HdrVideoWindow::WndProc(HWND window, UINT message,
                                         WPARAM wparam,
                                         LPARAM lparam) noexcept {
  switch (message) {
    // mpv owns every pixel, so erasing would only flicker.
    case WM_ERASEBKGND:
      return 1;
    // Belt and braces alongside WS_EX_TRANSPARENT: never take activation away
    // from the Flutter view, which is where input is still handled.
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    default:
      break;
  }
  return DefWindowProc(window, message, wparam, lparam);
}
