#include "hdr_alpha_probe.h"

#include <dwmapi.h>

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

  const BOOL ok = set_composition_attribute(top_level, &data);
  FreeLibrary(user32);
  return ok != FALSE;
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
    case Technique::kOff:
      break;
  }
  return L"off";
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
    switch (value[0]) {
      case L'1':
        return Technique::kBlurBehind;
      case L'2':
        return Technique::kColorKey;
      case L'3':
        return Technique::kDwmBlurBehind;
      case L'4':
        return Technique::kTransparent;
      default:
        return Technique::kOff;
    }
  }();
  return cached;
}

StandInWindow::~StandInWindow() {
  if (window_ != nullptr) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
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

  RECT client = {};
  GetClientRect(top_level, &client);

  window_ = CreateWindowEx(
      0, kStandInClassName, L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
      client.left, client.top, client.right - client.left,
      client.bottom - client.top, top_level, nullptr, GetModuleHandle(nullptr),
      nullptr);
  if (window_ == nullptr) {
    return false;
  }

  top_level_ = top_level;
  flutter_view_ = flutter_view;

  // Beneath the Flutter view. A child HWND composites above the Flutter
  // surface by default, which is the whole reason this question is hard.
  SetWindowPos(window_, HWND_BOTTOM, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

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
    case Technique::kOff:
      break;
  }

  return true;
}

void StandInWindow::SyncGeometry() {
  if (window_ == nullptr || top_level_ == nullptr) {
    return;
  }
  RECT client = {};
  GetClientRect(top_level_, &client);
  MoveWindow(window_, client.left, client.top, client.right - client.left,
             client.bottom - client.top, TRUE);
  SetWindowPos(window_, HWND_BOTTOM, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
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
