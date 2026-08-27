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

// The top-level runner window that owns the Flutter view, or null.
HWND TopLevelOf(flutter::PluginRegistrarWindows* registrar);

// Registers |name| against |proc| once per process. Returns false only if the
// registration itself failed.
bool EnsureWindowClass(const wchar_t* name, WNDPROC proc);

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
