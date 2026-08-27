# Native HDR video output on Windows

## Context

Windows playback looks flat and low-contrast next to Plex. The cause is structural, not a
tuning problem: `media_kit_video`'s Windows renderer allocates the video texture as
`DXGI_FORMAT_B8G8R8A8_UNORM` (`angle_surface_manager.cc:195`) and mpv draws into it through
the OpenGL render API under ANGLE. Flutter then composites that into its own 8-bit sRGB
swapchain. Every HDR10 / HDR10+ / HLG / DV stream is tone-mapped down to 8-bit BT.709 before
it reaches the screen.

`--target-colorspace-hint`, the option that actually produces HDR passthrough, only works on
the Wayland, D3D11 and winvk contexts — where mpv owns the swapchain. It cannot work through
the render API, because there mpv has no swapchain to tag. So HDR requires mpv to render into
its own D3D11 window, outside Flutter's compositor.

Two existing facts make this cheaper than it first appears:

- The project already ships **shinchiro's libmpv** via its own media-kit fork
  (`pubspec.yaml:214-223`). Those builds include libplacebo and the D3D11 context, so
  `gpu-next` + `target-colorspace-hint` are very likely already in the DLL that ships today.
- `windows/runner/native_game.cpp` is a working precedent for a runner-hosted native
  subsystem with its own channels, registrar and window-proc hook.

**Scope decision.** This plan covers *all* Windows playback through the main backend, engaged
automatically with no user-facing setting — chosen over the narrower fullscreen-only variant.

**A concern worth stating once, then proceeding.** Flutter on Windows has no platform-view
API. A child HWND always composites *above* the Flutter surface, so controls-over-video does
not come for free the way it does on Android TV, and the player's controls rely on translucent
scrims and gradients (`video_player_screen.dart:4215, 4511, 4556`) that a binary colour-key
cannot reproduce. Combined with "all playback, no setting", a regression would reach every
Windows user with no escape hatch. The plan therefore (a) puts a hard go/no-go gate in Phase 0
before any integration work, and (b) keeps a non-user-facing kill switch
(`--dart-define=MOONFIN_WIN_HDR=0` plus automatic fallback), which satisfies "no setting" while
retaining a way out.

Outcome: real HDR10 output on Windows, plus `gpu-next`'s better tone-mapping, scaling and
Dolby Vision RPU handling on SDR displays as a side effect.

---

## Architecture

One rendering path on Windows, decided once at process start — not swapped mid-session. This
matters because the backend is a process-lifetime GetIt singleton
(`playback_module.dart:297`) and `VideoControllerConfiguration` is immutable after
construction, so a mid-session swap would mean a second backend and a `setBackend` dance. The
native window works on SDR displays too (mpv tone-maps as today, only better), so no probe is
needed to choose it.

```
top-level runner window  (Win32Window, owns everything)
├── mpv video window     ← child HWND, D3D11 HDR swapchain, gpu-next
│                          positioned to the video rect pushed from Dart
└── Flutter view HWND    ← controls, OSD, dialogs
                           needs per-pixel alpha over the video rect
```

mpv renders subtitles itself on Windows already (`_enableNativeSubtitleRendering()`,
`media_kit_player_backend.dart:1786-1798` re-enables `sub-ass` at runtime), so subtitles come
along inside the native window and only the control chrome needs the overlay.

---

## Phase 0 — Go/no-go spike

Nothing else starts until these four answers are in. Timebox: a few days.

1. **Does the shipped libmpv have `gpu-next`?** Load `libmpv-2.dll` from
   `build/windows/x64/libmpv/`, `mpv_set_option_string(ctx, "vo", "gpu-next")`, check for
   error. Also confirm `gpu-api=d3d11` and that `target-colorspace-hint` is a known option.
2. **Is `wid` settable after `mpv_initialize`?** media_kit applies all properties *after*
   init (`real.dart:2319-2364` is the only pre-init block). Android TV sets `wid` at runtime
   successfully (`native_video_view.dart`), but Windows may differ. If it is not runtime-
   settable, the fallback is a pre-init `extraOptions` map added to `PlayerConfiguration` in
   the existing media-kit fork — cheap, since `media_kit_video` and
   `media_kit_libs_windows_video` are already forked at the same ref.
3. **Does HDR actually reach the display?** Standalone harness: mpv into a bare HWND with
   `vo=gpu-next gpu-api=d3d11 target-colorspace-hint=yes`, Windows display in HDR mode. Verify
   with the TV/monitor OSD and Windows' HDR indicator.
4. **Can the Flutter window get per-pixel alpha over that window?** The hard one. Evaluate in
   this order, stopping at the first that works:
   - `SetWindowCompositionAttribute` with `ACCENT_ENABLE_BLURBEHIND` / transparent gradient
     (the technique `flutter_acrylic` uses).
   - `WS_EX_LAYERED` + `SetLayeredWindowAttributes(..., LWA_COLORKEY)` — **known to degrade
     the gradients**, acceptable only as a stopgap.
   - `WS_EX_NOREDIRECTIONBITMAP` + DirectComposition, which needs the Flutter swapchain in our
     visual tree. Almost certainly out of reach without engine work.

**Gate:** if (4) yields nothing that preserves the scrim gradients, stop and re-scope to
fullscreen-only with an on-demand overlay, or to the tone-mapping-only work. Do not proceed to
Phase 2 on a colour-key result.

---

## Phase 1 — Native HDR video window (C++)

New files `windows/runner/hdr_video_window.{h,cpp}`, modelled directly on
`native_game.{h,cpp}`.

- Register from `flutter_window.cpp:194`, next to `native_game_`, via
  `engine()->GetRegistrarForPlugin("HdrVideo")`. Follow `native_game.cpp:62-107` for
  acquiring the top-level HWND (`GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT)`)
  and for `RegisterTopLevelWindowProcDelegate`.
- Method channel `moonfin/hdr_video`: `create` (returns the HWND as an int), `setGeometry`,
  `setVisible`, `destroy`, `getState`.
- Create a borderless child HWND parented to the Flutter view, the way
  `in_app_webview_manager.cpp:108-115` does. Own window class, `DefWindowProc`.
- Do **not** create a D3D11 device here — mpv creates and owns its swapchain once given `wid`.
  The runner only owns window lifetime and geometry.
- Private window messages start at `WM_APP + 2` (`WM_APP + 1` is taken by
  `native_game.cpp:58`).

Build wiring:
- `windows/runner/CMakeLists.txt:9-18` — add `hdr_video_window.cpp`.
- `windows/runner/CMakeLists.txt:37` — add `target_link_libraries(${BINARY_NAME} PRIVATE "d3d11.lib" "dxgi.lib")`.
- Mind `/WX` and `_HAS_EXCEPTIONS=0` from `windows/CMakeLists.txt:38-44`. Use raw COM with
  `HRESULT` checks, not C++/WinRT, or you will need the same escape hatch
  `flutter_inappwebview_windows/windows/CMakeLists.txt:182-194` uses.
- `build-windows.ps1` and the Inno script need no changes — `[Files] Source: "$ReleaseDir\*"`
  already ships whatever CMake installs.

---

## Phase 2 — Dart plumbing

**Prerequisite cleanups, do these first:**
- `audiobook_player_view.dart:128` uses `useNativeVideoSurface` as an "is Android TV" shorthand
  to force `setVolume(100.0)`. Re-gate it to `isAndroid && isTV` before widening anything, or
  it will fight the desktop volume restore at `video_player_screen.dart:743-746`.
- `video_player_screen.dart:828` is unreachable (`isMobilePlayback` requires `isAndroid && !isTV`,
  `useNativeVideoSurface` requires `isAndroid && isTV`). Remove it.
- Do **not** widen `PlatformDetection.useNativeVideoSurface` (`platform_detection.dart:351`)
  by adding an `isWindows` term to `isTV` — `isTV` is user-overridable on desktop
  (`canOverrideInterfaceLayout`, `:79`), so any Windows user picking the TV layout would
  activate it. Add a separate `useNativeHdrWindow => isWindows && !_hdrWindowDisabled` getter.

**Backend** (`media_kit_player_backend.dart`):
- Extend the `_useNativeSurface` branch at `:479-497` to cover the new getter, with Windows
  values: `vo=null` at init, `force-window=yes`, `hwdec` left at mpv's default, then
  `vo=gpu-next`, `gpu-api=d3d11`, `target-colorspace-hint=yes` once the HWND exists.
- Reuse the `VideoController` suppression at `:497-511` verbatim — setting
  `isVideoControllerAttached = true` and completing `videoControllerCompleter` is the
  load-bearing media_kit hack and is pure Dart, platform-neutral.
- Revive `_onNativeHandleReady` / `_notifyNativeHandleReady` (`:178, 411, 635, 1241-1255`),
  currently orphaned since iOS PiP moved to AetherEngine. It already hands out the raw
  `mpv_handle*` and is exactly the right shape here. Supply it from
  `playback_module.dart:297`.
- Set the HDR-relevant mpv properties that media_kit's own init actively works against:
  it applies `dither=no`, `scale=bilinear`, `dscale=bilinear`, `hdr-compute-peak=no` and
  `sigmoid-upscaling=no` to every native platform (`real.dart:2389-2412`). These are Android
  performance defaults and are wrong for a desktop HDR path. Override them after init.
- Add `target-colorspace-hint`, `target-prim`, `target-peak`, `gpu-api` and `hdr-compute-peak`
  to `_allowedMpvKeys` (`:1053-1080`) — they are silently dropped from custom mpv.conf today.

**Widget tree:**
- New branch in `_buildVideoSurface()` (`video_player_screen.dart:3862`), between the Media3
  and media_kit cases, returning a geometry-reporting widget instead of `Video`.
- Same branch in `live_tv_player_screen.dart:1552-1600` and `live_tv_mini_player.dart:264-317`.
  These three share the singleton `Player`, so all three must move together — the native window
  is simply repositioned to whichever rect is live.
- Consider collapsing the three duplicated ladders behind `PlayerBackend.buildView(...)`,
  following the existing `HtmlVideoBackend.buildView` precedent
  (`video_player_screen.dart:3888`). Optional, but the drift between the three is already real
  (Live TV has no `onVoReady`, so it loses subtitles across a VO swap).
- The geometry widget pushes its rect down on every layout change, the way
  `custom_platform_view.cc:299-326` does. Use a `LayoutBuilder` +
  `RenderBox.localToGlobal`, debounced.
- Port `_subtitleActive` / `_syncSubtitleActive` / `_onVoReady`
  (`video_player_screen.dart:686, 756, 2167, 3808, 3817`) — the `vo=null → gpu-next` swap
  tears down mpv's sub renderer and drops the active `sid`, on Windows exactly as on Android.
- Replicate `Video(pauseUponEnteringBackgroundMode:)`, which is `true` on Windows today
  (`:3928-3929`), or drop it deliberately.

**Overlay:** per the decision to build it simple and measure, start with the Flutter window
transparent for the whole session. Then measure whether the content's HDR10 static metadata
actually reaches the display in that configuration — an always-present overlay forces DWM into
composed-flip, which is what mpv issue #10628 is about. If it measurably matters, add
show-on-controls-visible as a follow-up; the controls already auto-hide, so the state exists.

---

## Phase 3 — Geometry and lifecycle correctness

The video window now tracks window geometry, so two existing bugs stop being cosmetic:

- **F11 bypasses the player.** `app.dart:735-740` toggles fullscreen from the global keyboard
  handler; the `if (_isPlayerRoute()) return false;` bail-out at `:739` guards only the
  back-key branch. `_isDesktopFullscreen` and `_syncAutoHdrSwitching()` never run. Fix.
- **No OS-initiated fullscreen listener.** `_VideoPlayerScreenState` mixes in `WindowListener`
  (`:104`) but overrides only `onWindowFocus` (`:1176`). Add `onWindowEnterFullScreen` /
  `onWindowLeaveFullScreen` and re-run `_syncDesktopFullscreenState()`.

Also:
- `win32_window.cpp:200-208` resizes only the single tracked `child_content_` on `WM_SIZE`.
  The video window needs its own geometry handling.
- Do not hang HDR logic off `didChangeAppLifecycleState` — the comment at
  `video_player_screen.dart:1210-1215` records that fullscreen toggles report `hidden` on some
  configurations.
- `window_manager` owns the top-level HWND for fullscreen/always-on-top. Verify it does not
  fight the child window on transitions.

---

## Phase 4 — Diagnostics and fallback

- Add an **HDR output** row to the playback info sheet, next to the existing
  `row(l10n.hdr, _getHdrType(video))` at `video_player_screen.dart:1601`. Show
  active / inactive plus the reason: display not in HDR mode, `gpu-next` unavailable, window
  creation failed, content is SDR.
- On any failure in window creation or the `vo` swap, fall back to the existing texture path
  for the rest of the session and record the reason. No toast, no dialog.
- New l10n keys go in `lib/l10n/app_en.arb` only — `flutter gen-l10n` back-fills every other
  locale with the English string. Regenerate and commit `app_localizations*.dart`.

---

## Risks

| Risk | Mitigation |
|---|---|
| Per-pixel alpha over the video proves unattainable | Phase 0 gate (4). Re-scope rather than ship a colour-key UI. |
| `wid` not runtime-settable on Windows | Pre-init `extraOptions` in the existing media-kit fork. |
| Live TV mini player is inline and can be overlapped by dialogs | It shares the singleton Player, so it moves with the others; geometry sync handles the small rect. Watch for dialogs drawn over it. |
| `gpu-next` absent from the shipped DLL | Phase 0 gate (1). Fallback is a newer shinchiro build in the already-forked libs package. |
| Multi-monitor / mixed HDR-SDR setups | `getHdrState` already resolves per-monitor from window position (`flutter_window.cpp:108`). Re-evaluate on monitor change. |
| Flutter UI is SDR against an HDR desktop, so controls look dim | Expected; matches every other Windows app. Tune scrim opacity if it reads badly. |

---

## Verification

**Phase 0** — standalone harness only, no app integration. Each of the four questions gets a
written yes/no before Phase 1 starts.

**Per-phase, on real hardware** (an HDR10 display and an SDR display):
1. `flutter build windows --release` via `.\build-windows.ps1`, then run the installer output.
2. Play an HDR10 title, an HDR10+ title, a DV Profile 8.1 title, a DV Profile 5 title and an
   SDR title. For each: check the new HDR-output diagnostics row, and confirm the display's own
   HDR indicator engages.
3. Compare DV P5 against today's build specifically — libplacebo handles the RPU, so the
   wrong-hue problem should resolve.
4. Geometry: windowed → fullscreen → windowed, F11, Alt+Enter, title-bar double-click, Win+Up,
   drag between monitors, DPI change, minimise/restore. The video window must track the rect
   in every case.
5. Controls: scrim gradients over video, seek bar, track selector dialog, OSD auto-hide.
6. Live TV full player and mini player, including transitions between them.
7. Confirm trailers, media-bar previews and home-row previews still render — they own separate
   `Player` instances (`trailer_player_screen.dart:101`, `media_bar.dart:1534`,
   `home_screen.dart:1738`) and must be unaffected.
8. Kill switch: `--dart-define=MOONFIN_WIN_HDR=0` restores the texture path exactly.

**Automated:** `flutter test`. Extend `test/playback/media_kit_player_backend_passthrough_test.dart`
for the new property block, and add a first `test/util/auto_hdr_switcher_test.dart` — none
exists today.

**Regression sweep:** Windows ARM64 build (`.\build-windows.ps1 -Architecture arm64`), since
the libmpv and ANGLE archives differ per architecture.
