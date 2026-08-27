#ifndef RUNNER_HDR_ALPHA_PROBE_H_
#define RUNNER_HDR_ALPHA_PROBE_H_

#include <windows.h>

// Phase 0, question 4 of docs/windows-hdr-output-plan.md: can the Flutter
// window get per-pixel alpha over a sibling child HWND?
//
// This is the gate that can stop the whole plan, and it cannot be answered by
// the standalone native/hdr_probe tool - it is a question about Flutter's own
// rendering surface, so it has to be asked inside the real app.
//
// The probe stands in for the future mpv video window: a borderless child HWND
// beneath the Flutter view, painting a fixed test pattern. What matters is not
// whether the pattern shows through, but whether the player's translucent
// scrim gradients still read as gradients over it.
//
// Compiled into every build but completely inert unless MOONFIN_HDR_Q4 is set
// in the environment, so release builds are unaffected.
namespace hdr_alpha_probe {

// Selected by the MOONFIN_HDR_Q4 environment variable. The plan evaluates
// these in order and stops at the first that works.
enum class Technique {
  // Not set, or set to 0. Nothing is created and nothing is altered.
  kOff = 0,
  // SetWindowCompositionAttribute + ACCENT_ENABLE_BLURBEHIND, the technique
  // flutter_acrylic uses. Named first by the plan. Note that it really does
  // blur what is behind the window, which would blur the video - use kTransparent
  // below for the unblurred form of the same call.
  kBlurBehind = 1,
  // WS_EX_LAYERED + LWA_COLORKEY. Known to degrade the gradients: the key is
  // binary, so a scrim fading from 70% to 0% turns into a hard edge where its
  // alpha crosses the key. Present to confirm that failure, not to ship.
  kColorKey = 2,
  // DwmEnableBlurBehindWindow over a null region.
  kDwmBlurBehind = 3,
  // SetWindowCompositionAttribute + ACCENT_ENABLE_TRANSPARENTGRADIENT. Not in
  // the plan's list, but it is the same call as kBlurBehind without the blur,
  // so it is the variant most likely to actually pass.
  kTransparent = 4,
  // Not a candidate - a control. The stand-in goes ON TOP of the Flutter view
  // and no transparency is applied at all, so the test pattern must be
  // visible. If it is not, the probe itself is broken and every other result
  // here is void.
  kSanityOnTop = 5,
  // The stand-in is a separate top-level window sitting directly behind the
  // Flutter window, rather than a child HWND inside it, with the Flutter
  // window made transparent by the same accent policy as kTransparent.
  //
  // Win32 has no per-pixel alpha between sibling child HWNDs - each child
  // composites opaquely into its parent's redirection surface, which is why
  // 1, 3 and 4 cannot work no matter which attribute is set. DWM does
  // composite top-level windows with alpha, so this is the one arrangement
  // where the question can come back yes.
  kTopLevelBehind = 6,
};

// Reads MOONFIN_HDR_Q4 once and caches it.
Technique SelectedTechnique();

// The colour the Flutter side must paint over the video rect under kColorKey.
// Kept away from pure black so ordinary black UI does not vanish with it.
// Mirrored in lib/ui/screens/playback/video_player_screen.dart.
constexpr COLORREF kColorKeyValue = RGB(1, 0, 1);

// The stand-in video window. Owns nothing but window lifetime and geometry -
// exactly the split Phase 1 plans for the real thing, where mpv creates and
// owns the swapchain once it is handed the HWND.
class StandInWindow {
 public:
  StandInWindow() = default;
  ~StandInWindow();

  StandInWindow(const StandInWindow&) = delete;
  StandInWindow& operator=(const StandInWindow&) = delete;

  // Creates the child window under |flutter_view| and applies the selected
  // transparency technique to |top_level|. A no-op returning false when the
  // technique is kOff.
  bool Attach(HWND top_level, HWND flutter_view);

  // Re-fits the child to the top-level client area. Call on WM_SIZE.
  void SyncGeometry();

 private:
  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

  HWND window_ = nullptr;
  HWND top_level_ = nullptr;
  HWND flutter_view_ = nullptr;
  bool syncing_ = false;
};

}  // namespace hdr_alpha_probe

#endif  // RUNNER_HDR_ALPHA_PROBE_H_
