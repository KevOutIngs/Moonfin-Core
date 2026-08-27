#include "hdr_window_support.h"

#include <set>

namespace hdr_window_support {

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

HWND TopLevelOf(flutter::PluginRegistrarWindows* registrar) {
  if (registrar == nullptr || registrar->GetView() == nullptr) {
    return nullptr;
  }
  return GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT);
}

bool EnsureWindowClass(const wchar_t* name, WNDPROC proc) {
  static std::set<std::wstring> registered;
  if (registered.count(name) != 0) {
    return true;
  }
  WNDCLASS window_class = {};
  window_class.lpfnWndProc = proc;
  window_class.hInstance = GetModuleHandle(nullptr);
  window_class.lpszClassName = name;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  // Neither window ever wants a background brush: mpv paints every pixel of
  // one through its own swapchain, and UpdateLayeredWindow owns the whole
  // surface of the other. A brush would only be a flash of the wrong colour.
  window_class.hbrBackground = nullptr;
  if (RegisterClass(&window_class) == 0) {
    return false;
  }
  registered.insert(name);
  return true;
}

LRESULT CALLBACK ClickThroughWndProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) noexcept {
  switch (message) {
    // Both windows own every pixel they show, so erasing only flickers.
    case WM_ERASEBKGND:
      return 1;
    // Send the hit test on to the window underneath - see the header.
    case WM_NCHITTEST:
      return HTTRANSPARENT;
    // Never take activation from the Flutter view either.
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    default:
      break;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

}  // namespace hdr_window_support
