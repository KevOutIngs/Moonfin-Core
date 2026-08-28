#ifndef RUNNER_HDR_WINDOW_SUPPORT_H_
#define RUNNER_HDR_WINDOW_SUPPORT_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/plugin_registrar_windows.h>

#include <string>

// What the two native HDR windows have in common.
//
// hdr_video_window and hdr_overlay_window are different windows with different
// jobs - one is a child hosting mpv's swapchain, the other a layered top-level
// carrying the controls - but they are both companions to the Flutter view,
// and they arrived with the same four blocks copied between them. Keeping one
// copy matters most for the click-through behaviour: a fix applied to one file
// would otherwise silently not reach the other, and that behaviour is what
// keeps the player's mouse input working at all.
namespace hdr_window_support {

// Readers for a method call's argument map.
int GetInt(const flutter::EncodableMap& map, const char* key, int fallback);
bool GetBool(const flutter::EncodableMap& map, const char* key, bool fallback);

// Registers |name| against |proc| once per process. Returns false only if the
// registration itself failed.
bool EnsureWindowClass(const wchar_t* name, WNDPROC proc);

// The top-level window's client area in screen coordinates - what a
// behind-the-window companion has to cover to line up with the Flutter view.
RECT ClientRectInScreenSpace(HWND top_level);

// Makes the top-level window composite with per-pixel alpha against whatever
// sits behind it, per `technique`:
//   1  DwmExtendFrameIntoClientArea(-1) - the classic sheet-of-glass call
//   2  SetWindowCompositionAttribute ACCENT_ENABLE_TRANSPARENTGRADIENT
//   3  both
//   4  accent state 6, past the documented enum - flutter_native_view's call
//
// Phase 0 concluded none of these worked, but every one of those tests
// sampled over opaque Flutter content - the home screen's poster backdrop, or
// the player route's black ModalBarrier - so the question was never actually
// asked. flutter_acrylic ships transparent Flutter windows on Windows with
// these same calls, which is why they get a second, valid test.
bool ApplyTransparencyComposition(HWND top_level, int technique);

// Puts the window back to normal opaque composition.
void RevertTransparencyComposition(HWND top_level);

// Appends a printf-style line to %TEMP%\moonfin_hdr_dwm.log. The runner is
// detached from any console, so this is the only way to see what the native
// half actually did while the DWM experiment runs.
void Log(const wchar_t* format, ...);

// The window procedure both companions use.
//
// The load-bearing case is WM_NCHITTEST returning HTTRANSPARENT. Neither
// window may take a hit test: the widgets that handle the click are in the
// Flutter view underneath, still laid out at the same coordinates - only the
// pixels moved. WS_EX_TRANSPARENT covers this for a layered top-level window
// but not for a child, where hit-testing walks the child chain and stops at
// the first window regardless. Without this the video window swallows every
// mouse event and the player looks dead while the keyboard still works,
// because keyboard follows focus, which never moved.
LRESULT CALLBACK ClickThroughWndProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) noexcept;

}  // namespace hdr_window_support

#endif  // RUNNER_HDR_WINDOW_SUPPORT_H_
