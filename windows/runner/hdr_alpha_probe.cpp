#include "hdr_alpha_probe.h"

#include <dwmapi.h>

#include <cstdarg>
#include <cstdio>
#include <cwchar>
#include <iterator>
#include <string>

namespace hdr_alpha_probe {

namespace {

constexpr const wchar_t kStandInClassName[] = L"MOONFIN_HDR_Q4_STANDIN";

// SetWindowCompositionAttribute is undocumented, so the shapes it takes are
// declared here rather than coming from a header. Same layout flutter_acrylic
// and every other Windows transparency package uses.
enum AccentState {
  ACCENT_DISABLED = 0,
  ACCENT_ENABLE_GRADIENT = 1,
  ACCENT_ENABLE_TRANSPARENTGRADIENT = 2,
  ACCENT_ENABLE_BLURBEHIND = 3,
  ACCENT_ENABLE_ACRYLICBLURBEHIND = 4,
  ACCENT_ENABLE_HOSTBACKDROP = 5,
  // Past the documented end of the enum. flutter_native_view uses exactly
  // this to show an embedded HWND through the Flutter window.
  ACCENT_INVALID_STATE = 6,
};

struct AccentPolicy {
  int accent_state;
  int accent_flags;
  unsigned int gradient_color;
  int animation_id;
};

struct WindowCompositionAttributeData {
  int attribute;
  void* data;
  size_t size;
};

// WCA_ACCENT_POLICY
constexpr int kAccentPolicyAttribute = 19;

using SetWindowCompositionAttributePtr =
    BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);

// Appends a line to %TEMP%\moonfin_hdr_q4.log. The probe runs detached from a
// console, so this is the only way to tell "the call failed" from "the call
// succeeded and changed nothing".
void Log(const wchar_t* format, ...) {
  wchar_t path[MAX_PATH] = {};
  if (GetTempPathW(static_cast<DWORD>(std::size(path)), path) == 0) {
    return;
  }
  wcsncat_s(path, L"moonfin_hdr_q4.log", _TRUNCATE);

  FILE* file = nullptr;
  if (_wfopen_s(&file, path, L"a, ccs=UTF-8") != 0 || file == nullptr) {
    return;
  }
  va_list args;
  va_start(args, format);
  vfwprintf(file, format, args);
  va_end(args);
  fwprintf(file, L"\n");
  fclose(file);
}

bool ApplyAccentPolicy(HWND top_level, AccentState state) {
  HMODULE user32 = LoadLibraryW(L"user32.dll");
  if (user32 == nullptr) {
    return false;
  }
  auto set_composition_attribute =
      reinterpret_cast<SetWindowCompositionAttributePtr>(
          GetProcAddress(user32, "SetWindowCompositionAttribute"));
  if (set_composition_attribute == nullptr) {
    FreeLibrary(user32);
    return false;
  }

  AccentPolicy policy = {};
  policy.accent_state = static_cast<int>(state);
  // 2 = draw the gradient colour on all edges. Without it the colour below is
  // ignored and the window keeps the system tint.
  policy.accent_flags = 2;
  // AABBGGRR, fully transparent, so the child window shows through unmodified.
  policy.gradient_color = 0x00000000;
  policy.animation_id = 0;

  WindowCompositionAttributeData data = {};
  data.attribute = kAccentPolicyAttribute;
  data.data = &policy;
  data.size = sizeof(policy);

  SetLastError(0);
  const BOOL ok = set_composition_attribute(top_level, &data);
  const DWORD error = GetLastError();
  FreeLibrary(user32);
  Log(L"SetWindowCompositionAttribute(state %d, flags %d, colour %08X) -> %d, "
      L"GetLastError %lu",
      policy.accent_state, policy.accent_flags, policy.gradient_color, ok,
      error);
  return ok != FALSE;
}

// The "sheet of glass" call: negative margins pull the entire client area into
// DWM's composited region, which is what lets a window be alpha-blended per
// pixel rather than just tinted.
bool ExtendFrameIntoClientArea(HWND top_level) {
  MARGINS margins = {-1, -1, -1, -1};
  const HRESULT hr = DwmExtendFrameIntoClientArea(top_level, &margins);
  Log(L"DwmExtendFrameIntoClientArea(-1) -> 0x%08lX", hr);
  return SUCCEEDED(hr);
}

bool ApplyColorKey(HWND top_level) {
  const LONG_PTR style = GetWindowLongPtr(top_level, GWL_EXSTYLE);
  SetLastError(0);
  if (SetWindowLongPtr(top_level, GWL_EXSTYLE, style | WS_EX_LAYERED) == 0 &&
      GetLastError() != 0) {
    return false;
  }
  return SetLayeredWindowAttributes(top_level, kColorKeyValue, 0,
                                    LWA_COLORKEY) != FALSE;
}

bool ApplyDwmBlurBehind(HWND top_level) {
  // A negative-extent region is the documented way to say "the whole window".
  HRGN region = CreateRectRgn(0, 0, -1, -1);
  DWM_BLURBEHIND blur = {};
  blur.dwFlags = DWM_BB_ENABLE | DWM_BB_BLURREGION;
  blur.fEnable = TRUE;
  blur.hRgnBlur = region;
  const HRESULT hr = DwmEnableBlurBehindWindow(top_level, &blur);
  DeleteObject(region);
  return SUCCEEDED(hr);
}

// The owner's client area, in screen coordinates - what a top-level stand-in
// has to cover to line up with where the Flutter view draws.
RECT ClientRectInScreenSpace(HWND top_level) {
  RECT client = {};
  GetClientRect(top_level, &client);
  POINT origin = {client.left, client.top};
  ClientToScreen(top_level, &origin);
  return RECT{origin.x, origin.y, origin.x + (client.right - client.left),
              origin.y + (client.bottom - client.top)};
}

// Whether the stand-in is a top-level window rather than a child HWND. Only
// top-level windows can be alpha-blended against each other by DWM, so every
// technique with a real chance of passing uses one.
bool UsesTopLevelStandIn(Technique technique) {
  return technique == Technique::kTopLevelBehind ||
         technique == Technique::kAcrylicDisabled ||
         technique == Technique::kAcrylicExtendFrame ||
         technique == Technique::kAccentState6 ||
         technique == Technique::kLayeredOverlay;
}

const wchar_t* TechniqueName(Technique technique) {
  switch (technique) {
    case Technique::kBlurBehind:
      return L"1  SetWindowCompositionAttribute / ACCENT_ENABLE_BLURBEHIND";
    case Technique::kColorKey:
      return L"2  WS_EX_LAYERED / LWA_COLORKEY  (stopgap, expect hard edges)";
    case Technique::kDwmBlurBehind:
      return L"3  DwmEnableBlurBehindWindow, null region";
    case Technique::kTransparent:
      return L"4  SetWindowCompositionAttribute / TRANSPARENTGRADIENT";
    case Technique::kSanityOnTop:
      return L"5  control - stand-in on top, no transparency at all";
    case Technique::kTopLevelBehind:
      return L"6  separate top-level window behind a transparent Flutter window";
    case Technique::kAcrylicDisabled:
      return L"7  flutter_acrylic's own call: ACCENT_DISABLED, flags 2";
    case Technique::kAcrylicExtendFrame:
      return L"8  mode 7 plus DwmExtendFrameIntoClientArea(-1)";
    case Technique::kAccentState6:
      return L"9  flutter_native_view's call: accent state 6, flags 2";
    case Technique::kLayeredOverlay:
      return L"10 UpdateLayeredWindow scrim over the stand-in - no Flutter";
    case Technique::kOff:
      break;
  }
  return L"off";
}

// The alpha a player scrim would have at a given height: opaque-ish black at
// the very top and the very bottom, fading to nothing across the middle. This
// is the shape a colour key cannot reproduce and the whole reason mode 2 was
// never acceptable.
BYTE ScrimAlphaAt(int y, int height) {
  const int band = height / 4;
  if (band <= 0) {
    return 0;
  }
  if (y < band) {
    // 180 at the top edge down to 0 at the band's lower edge.
    return static_cast<BYTE>(180 - (180 * y) / band);
  }
  if (y >= height - band) {
    const int into = y - (height - band);
    return static_cast<BYTE>((180 * into) / band);
  }
  return 0;
}

// Colour bars across the top, then a black-to-white ramp. The bars show
// whether colour survives the composite at all; the ramp is the one that
// matters, because a scrim gradient laid over it is exactly the case a binary
// colour key cannot reproduce.
void PaintTestPattern(HDC dc, const RECT& client) {
  const int width = client.right - client.left;
  const int height = client.bottom - client.top;
  if (width <= 0 || height <= 0) {
    return;
  }

  const int bars_height = height * 2 / 5;
  const COLORREF bars[] = {
      RGB(255, 255, 255), RGB(255, 255, 0), RGB(0, 255, 255),
      RGB(0, 255, 0),     RGB(255, 0, 255), RGB(255, 0, 0),
      RGB(0, 0, 255),     RGB(0, 0, 0),
  };
  const int bar_count = static_cast<int>(std::size(bars));

  for (int i = 0; i < bar_count; ++i) {
    RECT bar = {client.left + width * i / bar_count, client.top,
                client.left + width * (i + 1) / bar_count,
                client.top + bars_height};
    HBRUSH brush = CreateSolidBrush(bars[i]);
    FillRect(dc, &bar, brush);
    DeleteObject(brush);
  }

  for (int x = 0; x < width; ++x) {
    const int value = width > 1 ? (x * 255) / (width - 1) : 0;
    const BYTE level = static_cast<BYTE>(value);
    RECT column = {client.left + x, client.top + bars_height,
                   client.left + x + 1, client.bottom};
    HBRUSH brush = CreateSolidBrush(RGB(level, level, level));
    FillRect(dc, &column, brush);
    DeleteObject(brush);
  }

  std::wstring label = L"MOONFIN_HDR_Q4 stand-in video window\n";
  label += TechniqueName(SelectedTechnique());
  label +=
      L"\nA plain child HWND under the Flutter view. If you can read this, the"
      L"\nFlutter surface is letting it through.";

  RECT text = {client.left + 24, client.top + 24, client.right - 24,
               client.top + bars_height - 24};
  SetBkMode(dc, TRANSPARENT);
  // Drawn twice, offset, so it stays readable over both the white bar and the
  // black one.
  SetTextColor(dc, RGB(0, 0, 0));
  DrawText(dc, label.c_str(), -1, &text, DT_LEFT | DT_TOP | DT_NOCLIP);
  OffsetRect(&text, -1, -1);
  SetTextColor(dc, RGB(255, 255, 255));
  DrawText(dc, label.c_str(), -1, &text, DT_LEFT | DT_TOP | DT_NOCLIP);
}

}  // namespace

Technique SelectedTechnique() {
  static const Technique cached = [] {
    wchar_t value[16] = {};
    const DWORD capacity = static_cast<DWORD>(std::size(value));
    const DWORD length =
        GetEnvironmentVariableW(L"MOONFIN_HDR_Q4", value, capacity);
    if (length == 0 || length >= capacity) {
      return Technique::kOff;
    }
    // Parse the whole string, not the first character - mode 10 exists now.
    const int mode = _wtoi(value);
    switch (mode) {
      case 1:
        return Technique::kBlurBehind;
      case 2:
        return Technique::kColorKey;
      case 3:
        return Technique::kDwmBlurBehind;
      case 4:
        return Technique::kTransparent;
      case 5:
        return Technique::kSanityOnTop;
      case 6:
        return Technique::kTopLevelBehind;
      case 7:
        return Technique::kAcrylicDisabled;
      case 8:
        return Technique::kAcrylicExtendFrame;
      case 9:
        return Technique::kAccentState6;
      case 10:
        return Technique::kLayeredOverlay;
      default:
        return Technique::kOff;
    }
  }();
  return cached;
}

StandInWindow::~StandInWindow() {
  if (overlay_ != nullptr) {
    DestroyWindow(overlay_);
    overlay_ = nullptr;
  }
  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
}

bool StandInWindow::CreateLayeredOverlay(const RECT& screen) {
  const int width = screen.right - screen.left;
  const int height = screen.bottom - screen.top;
  if (width <= 0 || height <= 0) {
    return false;
  }

  // Called again on every resize, because the window is still settling into
  // its final size when Attach runs.
  if (overlay_ == nullptr) {
    overlay_ = CreateWindowEx(
        WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT,
        kStandInClassName, L"", WS_POPUP | WS_VISIBLE, screen.left, screen.top,
        width, height, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
    if (overlay_ == nullptr) {
      Log(L"overlay CreateWindowEx failed, GetLastError %lu", GetLastError());
      return false;
    }
  } else {
    MoveWindow(overlay_, screen.left, screen.top, width, height, FALSE);
  }

  // Top-down 32-bit DIB. UpdateLayeredWindow wants premultiplied alpha, and
  // the scrim is pure black, so the colour channels stay at zero whatever the
  // alpha is - premultiplying black by anything is still black.
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
    Log(L"overlay CreateDIBSection failed");
    return false;
  }

  auto* pixels = static_cast<BYTE*>(bits);
  for (int y = 0; y < height; ++y) {
    const BYTE alpha = ScrimAlphaAt(y, height);
    for (int x = 0; x < width; ++x) {
      BYTE* pixel = pixels + (static_cast<size_t>(y) * width + x) * 4;
      pixel[0] = 0;      // blue, premultiplied
      pixel[1] = 0;      // green
      pixel[2] = 0;      // red
      pixel[3] = alpha;  // alpha
    }
  }

  // A fully opaque white block in the middle, standing in for a control that
  // is not translucent, so the same capture shows both cases at once.
  const int block_top = height / 2 - height / 20;
  const int block_bottom = height / 2 + height / 20;
  for (int y = block_top; y < block_bottom; ++y) {
    for (int x = width / 4; x < width / 4 + width / 8; ++x) {
      BYTE* pixel = pixels + (static_cast<size_t>(y) * width + x) * 4;
      pixel[0] = 255;
      pixel[1] = 255;
      pixel[2] = 255;
      pixel[3] = 255;
    }
  }

  HDC memory_dc = CreateCompatibleDC(screen_dc);
  HGDIOBJ previous = SelectObject(memory_dc, bitmap);

  POINT destination = {screen.left, screen.top};
  SIZE size = {width, height};
  POINT source = {0, 0};
  BLENDFUNCTION blend = {};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;

  SetLastError(0);
  const BOOL ok =
      UpdateLayeredWindow(overlay_, screen_dc, &destination, &size, memory_dc,
                          &source, 0, &blend, ULW_ALPHA);
  Log(L"UpdateLayeredWindow(%dx%d) -> %d, GetLastError %lu", width, height, ok,
      GetLastError());

  SelectObject(memory_dc, previous);
  DeleteDC(memory_dc);
  DeleteObject(bitmap);
  ReleaseDC(nullptr, screen_dc);
  return ok != FALSE;
}

bool StandInWindow::Attach(HWND top_level, HWND flutter_view) {
  const Technique technique = SelectedTechnique();
  if (technique == Technique::kOff || top_level == nullptr ||
      flutter_view == nullptr) {
    return false;
  }

  static bool class_registered = false;
  if (!class_registered) {
    WNDCLASS window_class = {};
    window_class.lpfnWndProc = StandInWindow::WndProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.lpszClassName = kStandInClassName;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    // No background brush - WM_PAINT covers every pixel.
    window_class.hbrBackground = nullptr;
    if (RegisterClass(&window_class) == 0) {
      return false;
    }
    class_registered = true;
  }

  top_level_ = top_level;
  flutter_view_ = flutter_view;

  if (UsesTopLevelStandIn(technique)) {
    const RECT screen = ClientRectInScreenSpace(top_level);
    window_ = CreateWindowEx(
        WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, kStandInClassName, L"",
        WS_POPUP | WS_VISIBLE, screen.left, screen.top,
        screen.right - screen.left, screen.bottom - screen.top, nullptr,
        nullptr, GetModuleHandle(nullptr), nullptr);
  } else {
    RECT client = {};
    GetClientRect(top_level, &client);
    window_ = CreateWindowEx(
        0, kStandInClassName, L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
        client.left, client.top, client.right - client.left,
        client.bottom - client.top, top_level, nullptr,
        GetModuleHandle(nullptr), nullptr);
  }
  if (window_ == nullptr) {
    Log(L"CreateWindowEx failed, technique %d, GetLastError %lu",
        static_cast<int>(technique), GetLastError());
    return false;
  }

  // Without WS_CLIPSIBLINGS on the Flutter view, its swapchain present paints
  // straight over any overlapping sibling, and nothing ever sends the sibling
  // a WM_PAINT to put it back. That alone made the control come up empty, so
  // it has to be set before any result here means anything.
  const LONG_PTR view_style = GetWindowLongPtr(flutter_view, GWL_STYLE);
  if ((view_style & WS_CLIPSIBLINGS) == 0) {
    SetWindowLongPtr(flutter_view, GWL_STYLE, view_style | WS_CLIPSIBLINGS);
    SetWindowPos(flutter_view, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                     SWP_FRAMECHANGED);
    Log(L"added WS_CLIPSIBLINGS to the Flutter view");
  }

  SyncGeometry();

  Log(L"technique %d attached: top-level %p, flutter view %p, stand-in %p",
      static_cast<int>(technique), top_level, flutter_view, window_);

  switch (technique) {
    case Technique::kBlurBehind:
      ApplyAccentPolicy(top_level, ACCENT_ENABLE_BLURBEHIND);
      break;
    case Technique::kTransparent:
      ApplyAccentPolicy(top_level, ACCENT_ENABLE_TRANSPARENTGRADIENT);
      break;
    case Technique::kColorKey:
      ApplyColorKey(top_level);
      break;
    case Technique::kDwmBlurBehind:
      ApplyDwmBlurBehind(top_level);
      break;
    case Technique::kTopLevelBehind:
      ApplyAccentPolicy(top_level, ACCENT_ENABLE_TRANSPARENTGRADIENT);
      break;
    case Technique::kAcrylicExtendFrame:
      ExtendFrameIntoClientArea(top_level);
      [[fallthrough]];
    case Technique::kAcrylicDisabled:
      ApplyAccentPolicy(top_level, ACCENT_DISABLED);
      break;
    case Technique::kAccentState6:
      ApplyAccentPolicy(top_level, ACCENT_INVALID_STATE);
      break;
    case Technique::kLayeredOverlay: {
      // Flutter plays no part here. Both windows go topmost so the capture
      // sees the scrim composited over the bars and nothing else.
      const RECT screen = ClientRectInScreenSpace(top_level);
      SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      if (CreateLayeredOverlay(screen)) {
        SetWindowPos(overlay_, HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      }
      break;
    }
    // The control applies nothing on purpose.
    case Technique::kSanityOnTop:
    case Technique::kOff:
      break;
  }

  return true;
}

void StandInWindow::SyncGeometry() {
  if (window_ == nullptr || top_level_ == nullptr) {
    return;
  }

  // Re-ordering the stand-in can itself produce a WM_WINDOWPOSCHANGED on the
  // owner, which is what calls this.
  if (syncing_) {
    return;
  }
  syncing_ = true;

  const Technique technique = SelectedTechnique();
  if (UsesTopLevelStandIn(technique)) {
    // Track the owner's client area in screen space, and stay immediately
    // behind it in the top-level z-order. Deliberately not an owned window:
    // an owned window is always drawn above its owner, which is the opposite
    // of what this needs.
    const RECT screen = ClientRectInScreenSpace(top_level_);
    if (technique == Technique::kLayeredOverlay) {
      // Flutter is not part of this test, so both windows stay above
      // everything and the overlay is refitted to the settled size.
      SetWindowPos(window_, HWND_TOPMOST, screen.left, screen.top,
                   screen.right - screen.left, screen.bottom - screen.top,
                   SWP_NOACTIVATE);
      if (CreateLayeredOverlay(screen)) {
        SetWindowPos(overlay_, HWND_TOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      }
      syncing_ = false;
      return;
    }
    SetWindowPos(window_, top_level_, screen.left, screen.top,
                 screen.right - screen.left, screen.bottom - screen.top,
                 SWP_NOACTIVATE);
  } else {
    RECT client = {};
    GetClientRect(top_level_, &client);
    MoveWindow(window_, client.left, client.top, client.right - client.left,
               client.bottom - client.top, TRUE);
    // The control sits on top, everything else beneath the Flutter view.
    SetWindowPos(window_,
                 technique == Technique::kSanityOnTop ? HWND_TOP : HWND_BOTTOM,
                 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }

  syncing_ = false;
}

// static
LRESULT CALLBACK StandInWindow::WndProc(HWND window, UINT message,
                                        WPARAM wparam,
                                        LPARAM lparam) noexcept {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT: {
      PAINTSTRUCT paint = {};
      HDC dc = BeginPaint(window, &paint);
      RECT client = {};
      GetClientRect(window, &client);
      PaintTestPattern(dc, client);
      EndPaint(window, &paint);
      // Only the first few, so the log stays readable.
      static int paints = 0;
      if (++paints <= 5) {
        Log(L"stand-in painted (%d), client %ldx%ld, visible %d", paints,
            client.right - client.left, client.bottom - client.top,
            IsWindowVisible(window));
      }
      return 0;
    }
    // Never take focus - the Flutter view owns input.
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    default:
      break;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

}  // namespace hdr_alpha_probe
