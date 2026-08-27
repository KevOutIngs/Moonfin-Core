# Native HDR video output on Windows — implementation plan

## Context

Windows playback tone-maps every HDR stream down to 8-bit SDR before it reaches the
screen. `media_kit_video` allocates the shared texture as `B8G8R8A8_UNORM` and mpv draws
into it through the OpenGL render API, so Flutter composites an already flattened frame.
`target-colorspace-hint` cannot fix that: it tags a swapchain, and on the render API mpv
owns none.

Phase 0 (`docs/windows-hdr-phase0-results.md`) answered the gate, and one answer changed
the architecture:

| | Question | Result |
|---|---|---|
| Q1 | Shipped libmpv has `gpu-next`, `gpu-api=d3d11`, `target-colorspace-hint` | **PASS** |
| Q2 | `wid` settable after `mpv_initialize` | **PASS** |
| Q3 | HDR reaches the display | **PASS** — `R10G10B10A2_UNORM`, `RGB_FULL_G2084_NONE_P2020` |
| Q4 | Video visible **through** the Flutter surface | **FAIL** — 10 techniques, all 0 hits |
| Q4b | Controls drawable **over** the video with real alpha | **PASS** — `UpdateLayeredWindow` |
| Q5 | Flutter can produce that bitmap fast enough | **PASS** — 4.9 ms at 4K, in bands |

So the original plan's architecture — video behind a transparent Flutter window — is dead.
The Flutter surface on Windows is opaque and no accent state, DWM call or window style
changes it. The working architecture is the inverse: **video in front, controls above it in
layered windows of their own.**

Binary probe evidence for the format work: the shipped `libmpv-2.dll` contains FFmpeg's DV
RPU parser (`dovi_rpuenc.c`, `DOVI_RPU_BUFFER`, RPU validation), libplacebo's
`apply_dolbyvision`, and HDR10+ `st2094-40`. Everything the format matrix below needs is
already in the DLL Moonfin ships.

**Decisions taken with the user:**
- Engage only when the display is in HDR mode **and** the content is HDR. SDR playback and
  SDR displays keep today's texture path untouched.
- A user-facing setting is acceptable, alongside the existing auto-HDR-switching preference.

---

## Architecture

```
top-level runner window  (Win32Window)
├── Flutter view HWND     ← invisible during HDR playback, but still laid out:
│                            it owns hit-testing, focus and keyboard
├── mpv video window      ← child HWND, WS_EX_TRANSPARENT, D3D11 HDR swapchain
└── overlay windows       ← top-level, WS_EX_LAYERED, UpdateLayeredWindow
    ├── top band             controls rendered off-screen by Flutter
    └── bottom band          and pushed as premultiplied ARGB
```

Three properties make this work, all measured in Phase 0:

**Input needs no routing.** The video window and the overlays are both `WS_EX_TRANSPARENT`,
so they are skipped for hit-testing and clicks fall through to the Flutter view underneath,
where the real player widgets are still laid out at the same coordinates. Focus, keyboard,
gamepad and hit-testing keep working exactly as today — the widgets are simply not the thing
being *displayed*. This removes what looked like the largest remaining risk.

**Bands, not a full-screen overlay.** Readback cost tracks area: 19.2 ms for the whole 4K
window versus 4.9 ms for a 3814×500 band. Two band overlays leave the middle of the screen
never read back, and leave the video window overlapped only where controls actually are.

**The video window is a child, not top-level.** Mode 5 proved a child HWND composites
correctly once `WS_CLIPSIBLINGS` is set on the Flutter view — which `hdr_alpha_probe.cpp`
already does and which must move into the real implementation. A child window inherits the
runner's geometry, lifetime and DPI handling; a top-level one would need all of it rebuilt.

**Engagement is sticky for the session.** `Player` and `VideoController` are constructed once
in the `MediaKitPlayerBackend` factory (`media_kit_player_backend.dart:409`) and registered as
a startup singleton (`di/modules/playback_module.dart:297`). Rather than swapping paths per
item, the first HDR title on an HDR display engages the native path and it stays engaged for
the process. SDR content in the native window is not a regression — mpv renders it, and with
`gpu-next` renders it better than today.

---

## HDR format matrix

Output is **always HDR10 (PQ, BT.2020)** when the display is in HDR mode. This is a platform
constraint worth stating plainly: DXGI carries only static HDR10 metadata, so **there is no
HDR10+ and no Dolby Vision passthrough on Windows for a normal application**. Dynamic
metadata is *applied* by libplacebo and folded into the HDR10 output, which is the correct
and best available behaviour — not a shortcut.

| Input | What libplacebo does | Output on HDR display | Output on SDR display |
|---|---|---|---|
| **HDR10** (ST 2086 + MaxCLL/FALL) | passthrough, static metadata forwarded | HDR10, untouched | tone-mapped, `tone-mapping=bt.2390` |
| **HDR10+** (ST 2094-40) | applies dynamic metadata per scene | HDR10 with dynamic tone curve baked in | tone-mapped using the dynamic metadata |
| **HLG** | converts HLG → PQ | HDR10 | tone-mapped |
| **DV Profile 5** (IPTPQc2, no HDR10 base) | applies the RPU, converts IPT → BT.2020 PQ | **HDR10** — this is "DV to HDR10" | tone-mapped from the corrected image |
| **DV Profile 7** (dual layer BL+EL+RPU) | base layer only, EL ignored, RPU applied | HDR10 | tone-mapped |
| **DV Profile 8.1** (HDR10-compatible base) | applies the RPU over the base | HDR10, better than base alone | tone-mapped |
| **DV Profile 8.2** (SDR-compatible base) | applies the RPU | HDR10 | tone-mapped |
| **DV Profile 8.4** (HLG-compatible base) | applies the RPU, HLG → PQ | HDR10 | tone-mapped |
| **SDR** | nothing | no HDR switch, SDR | SDR |

**Profile 5 is the headline fix.** Without RPU application a P5 stream decodes as raw IPT and
renders with the wrong hue — the washed-out green/magenta cast users see today. libplacebo's
`apply_dolbyvision` corrects it. This benefits SDR displays too, so it lands even for users
who never turn HDR on.

**Profile 7 FEL is out of scope.** The enhancement layer needs a dual-layer decode path that
neither FFmpeg nor libplacebo provides. Base-layer-only is what every open player does, and
for MEL discs the base layer is the full picture anyway.

---

## Phase 1 — mpv in its own D3D11 window (C++)

New `windows/runner/hdr_video_window.{h,cpp}`, modelled on `native_game.{h,cpp}`, which is
the working precedent for a runner-hosted subsystem with its own channel and window-proc
delegate.

- Register from `flutter_window.cpp` next to `native_game_`, via
  `engine()->GetRegistrarForPlugin("HdrVideo")`. Follow `native_game.cpp:62-107` for
  acquiring the top-level HWND and for `RegisterTopLevelWindowProcDelegate`.
- Method channel `moonfin/hdr_video`: `create` (returns the HWND as an int), `setGeometry`,
  `setVisible`, `destroy`, `getState`.
- Borderless child HWND, `WS_CHILD | WS_CLIPSIBLINGS`, extended style `WS_EX_TRANSPARENT` so
  it never takes hit-tests. Own window class, `DefWindowProc`.
- **Set `WS_CLIPSIBLINGS` on the Flutter view.** Without it the Flutter swapchain present
  paints straight over any sibling and nothing repaints it. This cost a full round of false
  Phase 0 results; the working code is in `hdr_alpha_probe.cpp`'s `Attach`.
- Do **not** create a D3D11 device — mpv creates and owns the swapchain once given `wid`.
- Private window messages start at `WM_APP + 2` (`WM_APP + 1` is taken by
  `native_game.cpp:58`).

Build wiring: add the source to `windows/runner/CMakeLists.txt`; `dwmapi.lib` is already
linked. Mind `/W4 /WX` and `_HAS_EXCEPTIONS=0` from `windows/CMakeLists.txt:38-44` — raw COM
with `HRESULT` checks, no C++/WinRT.

## Phase 2 — layered control overlays (C++ + Dart)

New `windows/runner/hdr_overlay_window.{h,cpp}`. Generalises the proven mode-10 code in
`hdr_alpha_probe.cpp` (`CreateLayeredOverlay`) into two managed band windows.

- Top-level, `WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT`.
- `UpdateLayeredWindow` with `ULW_ALPHA` and `BLENDFUNCTION{AC_SRC_OVER, 255, AC_SRC_ALPHA}`,
  fed a **premultiplied** BGRA top-down DIB.
- Channel `moonfin/hdr_overlay`: `configure(bands)`, `push(band, bytes, width, height)`,
  `hide`, `destroy`.

Dart side, new `lib/ui/screens/playback/hdr_overlay_renderer.dart`:

- Wrap the player's top chrome and bottom chrome in their own `RepaintBoundary`s.
- On each frame where the controls are visible, `toImage()` then
  `toByteData(format: rawRgba)`, convert straight → premultiplied, push over the channel.
- Reuse the benchmark's measured shape: `lib/util/hdr_overlay_benchmark.dart` already has the
  timing harness and should stay in the tree as a regression check.
- **Stop pushing when the controls are hidden.** The controls auto-hide already, so the
  steady state during playback is zero readback.
- **Dialogs** — the track selector and info sheet sit in the middle of the screen, outside
  both bands. When a dialog route is open, switch to a single full-window overlay. At 19.2 ms
  that is ~50 fps, which is ample for a static dialog, and it reverts to bands on dismiss.

## Phase 3 — backend and engagement (Dart)

`lib/playback/media_kit_player_backend.dart`:

- Add `PlatformDetection.useNativeHdrWindow` as its own getter. Do **not** widen
  `useNativeVideoSurface` (`platform_detection.dart:351`) — `isTV` is user-overridable on
  desktop (`canOverrideInterfaceLayout`, `:79`), so any Windows user picking the TV layout
  would activate it by accident.
- Engage: create the window, `wid=<hwnd>`, then `vo=gpu-next`, `gpu-api=d3d11`,
  `target-colorspace-hint=yes`. Q2 proved all three are runtime-settable.
- Revive `_onNativeHandleReady` / `_notifyNativeHandleReady` (`:178, 400, 635`), currently
  orphaned since iOS PiP moved to AetherEngine. It already hands out the raw `mpv_handle*`
  and is the right shape; supply it from `di/modules/playback_module.dart:297`.
- **Undo media_kit's Android defaults.** It applies `dither=no`, `scale=bilinear`,
  `dscale=bilinear`, `hdr-compute-peak=no` and `sigmoid-upscaling=no` to every native platform
  (`real.dart:2389-2412`). These are phone performance defaults; `dither=no` alone bands dark
  gradients on desktop. Override after init.
- Extend `_allowedMpvKeys` (`:1053`) with `gpu-api`, `gpu-context`, `target-inverse-tone-mapping`
  and `tone-mapping-visualize`. `target-colorspace-hint`, `target-peak`, `target-prim`,
  `hdr-compute-peak`, `dither` and `dither-depth` are already allowed.
- Reuse the `VideoController` suppression at `:497-511` verbatim — setting
  `isVideoControllerAttached = true` and completing `videoControllerCompleter` is the
  load-bearing media_kit hack and is platform-neutral.

Engagement decision, made once per session before the first HDR media opens:

1. Content is HDR — read `video-params/gamma` and `video-params/primaries` from mpv, not the
   server. `_getHdrType` (`video_player_screen.dart:7322`) reads Jellyfin's `VideoRangeType`
   and stays as the label source for the *profile number*, which mpv does not expose, but the
   engage/skip decision must come from what mpv actually decoded.
2. Display is in HDR mode — `AutoHdrSwitcher` already has this via the `moonfin/hdr_display`
   channel's `getHdrState` (`flutter_window.cpp`). Reuse it; do not add a second path.
3. New preference `nativeHdrOutput` next to `AutoHdrSwitchingBehavior`
   (`preference_constants.dart:133`), plus the `--dart-define=MOONFIN_WIN_HDR=0` kill switch.

## Phase 4 — widget tree and geometry

- New branch in `_buildVideoSurface()` (`video_player_screen.dart:3859`), between the Media3
  and media_kit cases, returning a geometry-reporting widget instead of `Video`.
- Same branch in `live_tv_player_screen.dart:1579` and `live_tv_mini_player.dart:297`. These
  three share the singleton `Player`, so they must move together — the native window is
  repositioned to whichever rect is live. Consider collapsing the three duplicated ladders
  behind `PlayerBackend.buildView(...)`, following the `HtmlVideoBackend.buildView` precedent;
  the drift between them is already real (Live TV has no `onVoReady`, so it loses subtitles
  across a VO swap).
- Geometry pushed on layout change via `LayoutBuilder` + `RenderBox.localToGlobal`, debounced.
- Port `_subtitleActive` / `_syncSubtitleActive` / `_onVoReady`
  (`video_player_screen.dart:686, 756, 2167, 3808`) — the `vo` swap tears down mpv's sub
  renderer and drops the active `sid`, on Windows exactly as on Android. mpv renders subtitles
  itself in the native window, so they come along inside it.

Two existing bugs stop being cosmetic once the window tracks geometry:

- **F11 bypasses the player.** `app.dart:735-740` toggles fullscreen from the global keyboard
  handler; the `if (_isPlayerRoute()) return false;` bail-out at `:739` guards only the
  back-key branch, so `_isDesktopFullscreen` and `_syncAutoHdrSwitching()` never run.
- **No OS-initiated fullscreen listener.** `_VideoPlayerScreenState` mixes in `WindowListener`
  (`:104`) but overrides only `onWindowFocus` (`:1176`). Add `onWindowEnterFullScreen` /
  `onWindowLeaveFullScreen` and re-run `_syncDesktopFullscreenState()`.

Also: `win32_window.cpp:200-208` resizes only the single tracked `child_content_` on `WM_SIZE`
— the video window needs its own pass, and `WM_WINDOWPOSCHANGED` rather than `WM_SIZE`, since
the overlays follow moves too. Do not hang HDR logic off `didChangeAppLifecycleState`; the
comment at `video_player_screen.dart:1210-1215` records that fullscreen toggles report
`hidden` on some configurations.

## Phase 5 — diagnostics and fallback

- Add an **HDR output** row to the playback info sheet next to the existing
  `row(l10n.hdr, _getHdrType(video))` (`video_player_screen.dart:1599`). Show input format
  and profile, output state, and on failure the reason: display not in HDR mode, `gpu-next`
  unavailable, window creation failed, content is SDR, disabled by preference.
- On any failure in window creation or the `vo` swap, fall back to the texture path for the
  rest of the session and record why. No toast, no dialog.
- New l10n keys go in `lib/l10n/app_en.arb` only — `flutter gen-l10n` back-fills every other
  locale with the English string. Regenerate and commit `app_localizations*.dart`.

---

## Verification

**Automated:** `flutter analyze`, `flutter test`. Extend
`test/playback/media_kit_player_backend_passthrough_test.dart` for the new property block, and
add a first `test/util/auto_hdr_switcher_test.dart` — none exists today.

**Throughput regression:** keep `MOONFIN_HDR_Q4=11`. Band readback must stay under ~8 ms at
4K; the run must also be repeated *during* 4K HDR playback, which Phase 0 did not measure and
is the one number that could still surprise us.

**On hardware, an HDR10 display and an SDR display**, via `.\build-windows.ps1` then the
installer output:

1. One title per row of the format matrix — HDR10, HDR10+, HLG, DV P5, DV P7, DV P8.1 and SDR.
   For each: the new diagnostics row reads correctly, and the display's own HDR indicator
   engages. **DV P5 against today's build is the specific comparison to make** — the wrong-hue
   problem should be gone.
2. Controls: scrim gradients over video, seek bar, track selector dialog, OSD auto-hide, and
   that clicks land on the right widget through both transparent windows.
3. Geometry: windowed → fullscreen → windowed, F11, Alt+Enter, title-bar double-click, Win+Up,
   drag between monitors, DPI change, minimise/restore.
4. Live TV full player and mini player, including transitions between them.
5. Trailers, media-bar previews and home-row previews still render — they own separate `Player`
   instances (`trailer_player_screen.dart:101`, `media_bar.dart:1534`, `home_screen.dart:1738`)
   and must be unaffected.
6. Kill switch and preference both restore the texture path exactly.

**Regression sweep:** Windows ARM64 (`.\build-windows.ps1 -Architecture arm64`) — the libmpv
and ANGLE archives differ per architecture.

---

## Risks

| Risk | Mitigation |
|---|---|
| Readback contends with 4K HDR decode on the same GPU | Measured idle only. Re-measure during playback first; bands give 4× headroom. Falls back to the texture path if it does not hold. |
| `vo` swap mid-session destabilises the singleton `Player` | Engagement is sticky for the process — engage once, never revert except to the texture path on failure. |
| Overlay and video window drift apart during fast resize | Both driven from one `WM_WINDOWPOSCHANGED` pass, as the probe already does. |
| Dialogs invisible between the bands | Full-window overlay while a dialog route is open, ~50 fps, static content. |
| DV P7 FEL detail lost | Out of scope, matches every open player; base layer is the whole picture for MEL. |
| HDR10+ dynamic metadata not passed to the display | Platform limit, not ours. libplacebo applies it and outputs HDR10, which is the best available. |
| Live TV mini player is inline and can be overlapped by dialogs | Shares the singleton `Player`, so it moves with the others; watch for dialogs drawn over it. |
