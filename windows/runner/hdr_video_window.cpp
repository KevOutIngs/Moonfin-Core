#include "hdr_video_window.h"

#include <flutter/standard_method_codec.h>

#include <string>

#include "hdr_window_support.h"

namespace {

constexpr const wchar_t kWindowClassName[] = L"MOONFIN_HDR_VIDEO";

// Where a hidden video window is parked instead of SW_HIDE. Hiding a window
// with a live D3D11 swapchain stalls mpv's presentation queue, and mpv paces
// audio against video, so the whole file goes silent - parking off-screen
// clips the window away while presentation carries on.
constexpr int kParkedOrigin = -32000;

int ReadDwmMode() {
  wchar_t value[8] = {};
  const DWORD length = GetEnvironmentVariableW(
      L"MOONFIN_HDR_DWM", value, static_cast<DWORD>(std::size(value)));
  if (length == 0 || length >= std::size(value)) {
    return 0;
  }
  const int mode = _wtoi(value);
  return (mode >= 1 && mode <= 4) ? mode : 0;
}

}  // namespace

HdrVideoWindow::HdrVideoWindow(flutter::BinaryMessenger* messenger,
                               flutter::PluginRegistrarWindows* registrar,
                               HWND top_level)
    : top_level_(top_level), dwm_mode_(ReadDwmMode()) {
  hdr_window_support::Log(L"HdrVideoWindow ctor: dwm_mode=%d top_level=%p",
                          dwm_mode_, top_level_);
  if (registrar != nullptr && registrar->GetView() != nullptr) {
    flutter_view_ = registrar->GetView()->GetNativeWindow();
  }

  // Position sync is driven from the head of FlutterWindow::MessageHandler
  // plus its heartbeat timer - not from a registered window-proc delegate,
  // whose chain stops at the first plugin that claims a message.

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

  // Dart has not laid anything out yet when this runs - the handle is needed
  // before the widget that would measure the video rect can exist - so fall
  // back to the whole client area rather than the empty default. A zero-area
  // window would be handed straight to mpv as `wid`, and its D3D11 context
  // fails CreateSwapChainForHwnd on one, which marks the session permanently
  // failed before the first frame.
  if (geometry_.right <= geometry_.left || geometry_.bottom <= geometry_.top) {
    GetClientRect(top_level_, &geometry_);
  }

  if (behind()) {
    // A top-level window directly behind the runner window, which is given
    // per-pixel DWM transparency so the Flutter frame composites over the
    // video with real alpha. WS_EX_NOACTIVATE keeps focus on the runner,
    // WS_EX_TOOLWINDOW keeps it out of the taskbar and alt-tab.
    const RECT screen =
        hdr_window_support::ClientRectInScreenSpace(top_level_);
    window_ = CreateWindowEx(
        WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, kWindowClassName, L"", WS_POPUP,
        screen.left, screen.top, screen.right - screen.left,
        screen.bottom - screen.top, nullptr, nullptr, GetModuleHandle(nullptr),
        nullptr);
    if (window_ == nullptr) {
      hdr_window_support::Log(L"behind Create failed: %lu", GetLastError());
      return 0;
    }
    const bool composed =
        hdr_window_support::ApplyTransparencyComposition(top_level_, dwm_mode_);
    hdr_window_support::Log(
        L"behind Create: hwnd=%p at (%ld,%ld)-(%ld,%ld), composition(%d)=%d",
        window_, screen.left, screen.top, screen.right, screen.bottom,
        dwm_mode_, composed);
    return reinterpret_cast<int64_t>(window_);
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
  if (behind()) {
    PlaceBehind(false);
    return;
  }
  SetWindowPos(window_, HWND_TOP, x, y, width, height, SWP_NOACTIVATE);
}

void HdrVideoWindow::SetVisible(bool visible) {
  if (window_ == nullptr) {
    return;
  }

  if (visible) {
    if (behind()) {
      // No separate ShowWindow: showing a popup hoists it over the runner and
      // only PlaceBehind's insert-after puts it back, so the one call that
      // does both atomically is the one to use.
      PlaceBehind(true);
    } else {
      ShowWindow(window_, SW_SHOWNOACTIVATE);
      SetWindowPos(window_, HWND_TOP, geometry_.left, geometry_.top,
                   geometry_.right - geometry_.left,
                   geometry_.bottom - geometry_.top, SWP_NOACTIVATE);
    }
    return;
  }

  // Parked off-screen rather than hidden - see kParkedOrigin.
  SetWindowPos(window_, nullptr, kParkedOrigin, kParkedOrigin,
               geometry_.right - geometry_.left,
               geometry_.bottom - geometry_.top,
               SWP_NOZORDER | SWP_NOACTIVATE);
}

void HdrVideoWindow::PlaceBehind(bool show) {
  if (window_ == nullptr || top_level_ == nullptr) {
    return;
  }
  // Minimised: the client rect is meaningless, so park until restore.
  if (IsIconic(top_level_)) {
    SetWindowPos(window_, nullptr, kParkedOrigin, kParkedOrigin, 0, 0,
                 SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    return;
  }

  // The video rect Dart reports is in client coordinates; a top-level window
  // is positioned in screen space, and inserted directly below the runner so
  // nothing can slot between them.
  RECT client = geometry_;
  POINT origin = {client.left, client.top};
  ClientToScreen(top_level_, &origin);
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  UINT flags = SWP_NOACTIVATE;
  if (show) {
    flags |= SWP_SHOWWINDOW;
  }

  SetLastError(0);
  const BOOL ok = SetWindowPos(window_, top_level_, origin.x, origin.y, width,
                               height, flags);
  if (ok == FALSE) {
    // This runs on the half-second heartbeat, so only failures are worth a
    // line - a healthy session would otherwise write to disk twice a second.
    hdr_window_support::Log(L"PlaceBehind failed: err=%lu", GetLastError());
  }
}

void HdrVideoWindow::SyncPosition() {
  if (window_ == nullptr || top_level_ == nullptr) {
    return;
  }

  // Monitor-crossing detection lives here, ahead of the arrangement gate,
  // because the invariant it compensates - mpv in `wid` mode negotiates the
  // swapchain colorspace once, at creation - holds for the child arrangement
  // exactly as for the behind one. Dart owns the response: a resize nudge
  // proved insufficient (ResizeBuffers keeps the colorspace decided at
  // creation), so the backend recreates the renderer, which is an
  // mpv-property dance only it can run.
  const HMONITOR monitor =
      MonitorFromWindow(top_level_, MONITOR_DEFAULTTONEAREST);
  if (last_monitor_ != nullptr && monitor != last_monitor_ &&
      channel_ != nullptr) {
    channel_->InvokeMethod("monitorChanged", nullptr);
    hdr_window_support::Log(L"monitor crossed - asked Dart to renegotiate");
  }
  last_monitor_ = monitor;

  if (behind()) {
    PlaceBehind(false);
  }
}

void HdrVideoWindow::Destroy() {
  if (window_ != nullptr) {
    if (behind()) {
      hdr_window_support::RevertTransparencyComposition(top_level_);
    }
    DestroyWindow(window_);
    window_ = nullptr;
  }
}
