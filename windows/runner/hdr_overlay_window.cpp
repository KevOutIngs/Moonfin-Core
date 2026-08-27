#include "hdr_overlay_window.h"

#include <flutter/standard_method_codec.h>

#include <cstring>

namespace {

constexpr const wchar_t kWindowClassName[] = L"MOONFIN_HDR_OVERLAY";

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

std::string GetString(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it != map.end()) {
    if (const auto* value = std::get_if<std::string>(&it->second)) {
      return *value;
    }
  }
  return std::string();
}

}  // namespace

HdrOverlayWindow::HdrOverlayWindow(
    flutter::BinaryMessenger* messenger,
    flutter::PluginRegistrarWindows* registrar) {
  if (registrar != nullptr && registrar->GetView() != nullptr) {
    flutter_view_ = registrar->GetView()->GetNativeWindow();
    top_level_ = GetAncestor(flutter_view_, GA_ROOT);
  }

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "moonfin/hdr_overlay",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethod(call, std::move(result));
  });
}

HdrOverlayWindow::~HdrOverlayWindow() { DestroyAll(); }

void HdrOverlayWindow::HandleMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const flutter::EncodableMap empty;
  const flutter::EncodableMap& map = args != nullptr ? *args : empty;
  const std::string& method = call.method_name();

  if (method == "push") {
    const std::string id = GetString(map, "id");
    const int width = GetInt(map, "width", 0);
    const int height = GetInt(map, "height", 0);
    const int x = GetInt(map, "x", 0);
    const int y = GetInt(map, "y", 0);

    const auto it = map.find(flutter::EncodableValue(std::string("bytes")));
    const std::vector<uint8_t>* pixels =
        it != map.end() ? std::get_if<std::vector<uint8_t>>(&it->second)
                        : nullptr;
    if (id.empty() || pixels == nullptr || width <= 0 || height <= 0) {
      result->Error("bad_args", "push needs id, bytes, width and height");
      return;
    }
    const size_t expected = static_cast<size_t>(width) *
                            static_cast<size_t>(height) * 4;
    if (pixels->size() < expected) {
      result->Error("short_buffer", "bytes is smaller than width * height * 4");
      return;
    }

    const RECT rect = {x, y, x + width, y + height};
    if (!Push(id, rect, *pixels, width, height)) {
      result->Error("push_failed", "could not update the overlay window");
      return;
    }
    result->Success();
    return;
  }

  if (method == "hide") {
    Hide(GetString(map, "id"));
    result->Success();
    return;
  }

  if (method == "destroy") {
    DestroyAll();
    result->Success();
    return;
  }

  result->NotImplemented();
}

bool HdrOverlayWindow::Push(const std::string& id, const RECT& rect,
                            const std::vector<uint8_t>& pixels, int width,
                            int height) {
  if (top_level_ == nullptr) {
    return false;
  }

  static bool class_registered = false;
  if (!class_registered) {
    WNDCLASS window_class = {};
    window_class.lpfnWndProc = HdrOverlayWindow::WndProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.lpszClassName = kWindowClassName;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.hbrBackground = nullptr;
    if (RegisterClass(&window_class) == 0) {
      return false;
    }
    class_registered = true;
  }

  // The band tracks a rect given in the top-level's client coordinates, but a
  // layered window is top-level itself and positioned in screen space.
  POINT origin = {rect.left, rect.top};
  ClientToScreen(top_level_, &origin);

  Band& band = bands_[id];
  if (band.window == nullptr) {
    // WS_EX_TRANSPARENT keeps the overlay out of hit-testing, so clicks pass
    // through to the Flutter view, where the real widgets still are.
    // WS_EX_NOACTIVATE keeps focus where it is.
    band.window = CreateWindowEx(
        WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW |
            WS_EX_TRANSPARENT,
        kWindowClassName, L"", WS_POPUP, origin.x, origin.y, width, height,
        top_level_, nullptr, GetModuleHandle(nullptr), nullptr);
    if (band.window == nullptr) {
      bands_.erase(id);
      return false;
    }
  }

  // Top-down 32-bit DIB, which is the layout UpdateLayeredWindow wants.
  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(info.bmiHeader);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  void* bits = nullptr;
  HDC screen_dc = GetDC(nullptr);
  HBITMAP bitmap =
      CreateDIBSection(screen_dc, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (bitmap == nullptr || bits == nullptr) {
    ReleaseDC(nullptr, screen_dc);
    return false;
  }

  // Flutter's ImageByteFormat.rawRgba is already premultiplied, which is what
  // AC_SRC_ALPHA needs, so the only difference is channel order: RGBA in,
  // BGRA out. Doing the swap here rather than in Dart keeps it off the UI
  // isolate, where it would land on every frame the controls are visible.
  auto* destination = static_cast<uint8_t*>(bits);
  const uint8_t* source = pixels.data();
  const size_t count = static_cast<size_t>(width) * static_cast<size_t>(height);
  for (size_t i = 0; i < count; ++i) {
    const size_t offset = i * 4;
    destination[offset + 0] = source[offset + 2];  // blue
    destination[offset + 1] = source[offset + 1];  // green
    destination[offset + 2] = source[offset + 0];  // red
    destination[offset + 3] = source[offset + 3];  // alpha
  }

  HDC memory_dc = CreateCompatibleDC(screen_dc);
  HGDIOBJ previous = SelectObject(memory_dc, bitmap);

  POINT destination_point = {origin.x, origin.y};
  SIZE size = {width, height};
  POINT source_point = {0, 0};
  BLENDFUNCTION blend = {};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;

  const BOOL ok = UpdateLayeredWindow(band.window, screen_dc,
                                      &destination_point, &size, memory_dc,
                                      &source_point, 0, &blend, ULW_ALPHA);

  SelectObject(memory_dc, previous);
  DeleteDC(memory_dc);
  DeleteObject(bitmap);
  ReleaseDC(nullptr, screen_dc);

  if (ok == FALSE) {
    return false;
  }

  if (!band.visible) {
    ShowWindow(band.window, SW_SHOWNOACTIVATE);
    band.visible = true;
    // WS_EX_NOACTIVATE should hold this, but showing an owned window is
    // exactly the kind of moment focus slips, and a player that ignores
    // space until you alt-tab is a miserable bug to chase.
    if (flutter_view_ != nullptr && GetActiveWindow() == top_level_) {
      SetFocus(flutter_view_);
    }
  }
  // Above the video window, which is a child of the top level, so staying
  // immediately above the owner is enough.
  SetWindowPos(band.window, HWND_TOP, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  return true;
}

void HdrOverlayWindow::Hide(const std::string& id) {
  if (id.empty()) {
    for (auto& entry : bands_) {
      if (entry.second.window != nullptr && entry.second.visible) {
        ShowWindow(entry.second.window, SW_HIDE);
        entry.second.visible = false;
      }
    }
    return;
  }
  const auto it = bands_.find(id);
  if (it == bands_.end() || it->second.window == nullptr) {
    return;
  }
  ShowWindow(it->second.window, SW_HIDE);
  it->second.visible = false;
}

void HdrOverlayWindow::DestroyAll() {
  for (auto& entry : bands_) {
    if (entry.second.window != nullptr) {
      DestroyWindow(entry.second.window);
    }
  }
  bands_.clear();
}

// static
LRESULT CALLBACK HdrOverlayWindow::WndProc(HWND window, UINT message,
                                           WPARAM wparam,
                                           LPARAM lparam) noexcept {
  switch (message) {
    // UpdateLayeredWindow owns the whole surface; there is nothing to erase
    // and nothing to paint on demand.
    case WM_ERASEBKGND:
      return 1;
    // Belt and braces with WS_EX_TRANSPARENT, which does work for a layered
    // top-level window. The controls drawn here are only pixels: the widgets
    // that handle the click are in the Flutter view underneath.
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    default:
      break;
  }
  return DefWindowProc(window, message, wparam, lparam);
}
