# Phase 0 results — native HDR video output on Windows

Gate for [windows-hdr-output-plan.md](windows-hdr-output-plan.md). Nothing in Phase 1
starts until all four questions have a written answer.

| # | Question | Answer |
|---|---|---|
| 1 | Does the shipped libmpv have `gpu-next`, `gpu-api=d3d11`, `target-colorspace-hint`? | **PASS** |
| 2 | Is `wid` settable after `mpv_initialize`? | **PASS** |
| 3 | Does HDR actually reach the display? | **PASS** |
| 4 | Can the Flutter window get per-pixel alpha over that window? | **FAIL** — but see below |
| 4b | Can *anything* get per-pixel alpha over that window? | **PASS** — `UpdateLayeredWindow` |

**The gate is met, by a different architecture than the plan assumed.** Q1-Q3 pass: the HDR
half works on the libmpv that ships today. Q4 as written fails — the Flutter surface cannot
be made transparent, and ten techniques were tried. But the question behind Q4 is whether the
*controls* can be drawn over the video with real alpha, and that answer is yes:
`UpdateLayeredWindow` composites a scrim gradient over an arbitrary window correctly.

That inverts the architecture. Instead of the video going behind Flutter, the controls go in
front of the video, in a layered window of their own. See
[the revised architecture](#revised-architecture).

---

## Q1 — renderer options — PASS

`native/hdr_probe` built against `build/windows/x64/libmpv/libmpv-2.dll`, client API
version **2.5**. Every option the plan depends on parses:

```
PASS  vo=gpu-next                  libplacebo renderer
PASS  vo=gpu                       old renderer, what the texture path uses today
PASS  gpu-api=d3d11                D3D11 context, owns the swapchain
PASS  gpu-api=vulkan               alternative context that also supports the hint
PASS  target-colorspace-hint=yes   tags the swapchain
PASS  target-colorspace-hint=auto  newer tri-state form
PASS  tone-mapping=bt.2390         tone curve for the SDR fallback
PASS  hdr-compute-peak=yes         dynamic peak detection
PASS  target-contrast=inf          black point handling on OLED
PASS  dither-depth=auto            banding control
```

**Consequence:** the DLL Moonfin ships today is sufficient. The risk row "`gpu-next`
absent from the shipped DLL" is closed — no newer shinchiro build and no
`media_kit_libs_windows_video` work is needed.

## Q2 — `wid` timing — PASS

```
PASS  wid as pre-init option
PASS  wid as post-init property
PASS  vo=gpu-next swap after init
```

**Consequence:** `wid` is runtime-settable on Windows, so the Android TV pattern ports
directly — `vo=null` at init, then `wid` + `vo=gpu-next` once the HWND exists. The
`PlayerConfiguration.extraOptions` fallback is not needed, and `media_kit` itself does
not have to join `dependency_overrides`. The risk row "`wid` not runtime-settable" is
closed.

## Q3 — HDR to the display — PASS

Run against a 4K HDR10 ShadowPlay capture (`d3d11[p010]`, `bt.2020-ncl/bt.2020/pq/full`),
`vo=gpu-next gpu-api=d3d11 target-colorspace-hint=yes`:

```
current-vo                gpu-next
video-params/primaries    bt.2020
video-params/gamma        pq
video-params/sig-peak     49.26
video-params/max-luma     10000
hwdec-current             d3d11va

[vo/gpu-next/libplacebo] New swap chain configuration received from hint:
    format: R10G10B10A2_UNORM, color space: RGB_FULL_G2084_NONE_P2020
[vo/gpu-next/libplacebo] Dithering to 10 bit depth
```

**Consequence:** `target-colorspace-hint` reaches the swapchain and reconfigures it — 10-bit,
BT.2020 primaries, PQ transfer, no tone-map to SDR. This is the thing the texture path
structurally cannot do, and it works on the DLL that ships today. Worth re-running once on a
real HDR10 movie rather than a game capture, and watching the display's own HDR indicator,
but the negotiation above is the part that was in doubt.

## Q4 — per-pixel alpha over the video window — spike built

This is the hard gate, and the one that can stop the plan. See
[the Q4 spike](../windows/runner/hdr_alpha_probe.h) — it is compiled into the runner but
inert unless `MOONFIN_HDR_Q4` is set in the environment, so release builds are unaffected.

Per the plan, the techniques are tried in order and the first that works wins:

| `MOONFIN_HDR_Q4` | Technique | Verdict if it works |
|---|---|---|
| `1` | `SetWindowCompositionAttribute` + `ACCENT_ENABLE_BLURBEHIND` | **passes the gate** |
| `2` | `WS_EX_LAYERED` + `LWA_COLORKEY` | stopgap only — see below |
| `3` | `DwmEnableBlurBehindWindow`, null region | **passes the gate** |
| `4` | `SetWindowCompositionAttribute` + `ACCENT_ENABLE_TRANSPARENTGRADIENT` | **passes the gate** |

Mode `4` is not in the plan's list. It is the same call as mode `1` without the blur,
which matters: `ACCENT_ENABLE_BLURBEHIND` really does blur what is behind the window, so
even a passing result there would blur the video. Try `1` first because the plan names it
first, then `4`.

The spike parents a borderless child HWND beneath the Flutter view and paints a test
pattern into it — colour bars plus a smooth black-to-white ramp — standing in for the
mpv video window. What matters is not whether the pattern shows through, but whether the
player's translucent scrim gradients still read as gradients over it
(`video_player_screen.dart:4215, 4511, 4556`).

**A colour-key result does not pass.** `LWA_COLORKEY` is binary: every pixel matching the
key vanishes entirely, so a scrim that fades from 70% to 0% black turns into a hard edge
where its alpha crosses the key. Mode `2` exists to confirm that failure, not to ship.

If nothing here preserves the gradients, stop and re-scope — to fullscreen-only with an
on-demand overlay, or to the tone-mapping-only work that already stands on its own.

### Results

Measured by capturing the window and counting how many sample points in the colour-bar
band land on a pure bar colour — those colours appear nowhere in Moonfin's own UI, so a
hit means the stand-in is visible.

| Mode | Technique | Hits | Verdict |
|---|---|---|---|
| `5` | control — stand-in on top, no transparency | **30/35** | harness is sound |
| `1` | `ACCENT_ENABLE_BLURBEHIND` | 0/35 | **FAIL** |
| `3` | `DwmEnableBlurBehindWindow` | 0/35 | **FAIL** |
| `4` | `ACCENT_ENABLE_TRANSPARENTGRADIENT` | 0/35 | **FAIL** |
| `6` | separate top-level window behind | 0/35 | **FAIL** |
| `7` | `flutter_acrylic`'s call, `ACCENT_DISABLED` flags 2 | 0/15 | **FAIL** |
| `8` | mode 7 + `DwmExtendFrameIntoClientArea(-1)` | 0/15 | **FAIL** |
| `9` | `flutter_native_view`'s call, accent state 6 | 0/15 | **FAIL** |
| `10` | **`UpdateLayeredWindow` scrim above the stand-in** | — | **PASS** — gradients survive |
| — | control: top-level stand-in forced `HWND_TOPMOST` | **12/15** | top-level stand-ins do composite |

The stand-in is created, visible and painting in every mode — the probe log confirms it
each run. Nothing reaches the screen through the Flutter view.

**Read the control first.** The first round of this spike reported black screens for 1, 3
and 4, and every one of those results was worthless: the Flutter view HWND does not carry
`WS_CLIPSIBLINGS`, so its swapchain present painted straight over the stand-in, and nothing
ever sent the stand-in a `WM_PAINT` to put it back. The stand-in was being drawn once and
immediately erased. `Attach` now sets that style on the Flutter view, and only then does
the control light up. Any future run of this spike that cannot show mode `5` working is
measuring nothing.

**Mode `6` fails too**, confirmed by eye with nothing else fullscreen.

### What was tried, and one false alarm along the way

`flutter_acrylic` and `flutter_native_view` both make Windows transparency work in real
apps, so their exact calls were tried rather than guessed at:

| Mode | Call | Source |
|---|---|---|
| `7` | `ACCENT_DISABLED`, flags 2, colour 0 | `flutter_acrylic`'s `SetEffect` |
| `8` | mode 7 + `DwmExtendFrameIntoClientArea` margins `-1` | same, Win11 ≥ 22523 path |
| `9` | **accent state 6**, flags 2, colour 0 | `flutter_native_view`'s `SetWindowComposition(window_, 6, 0)` — past the documented end of the enum |

All applied to `GetAncestor(view, GA_ROOT)`, with the stand-in as a top-level window
directly behind, mirroring that package's `native_view_container_`. Every call returns
success, now logged:

```
DwmExtendFrameIntoClientArea(-1) -> 0x00000000
SetWindowCompositionAttribute(state 6, flags 2, colour 00000000) -> 1, GetLastError 0
```

**None of them changes anything on screen.** Every mode scores 0/15.

There was a false alarm here worth recording, because it nearly went into this document as a
finding. Modes 7-9 *looked* like they had worked — the player background stopped being flat
black and showed a soft blurred image, exactly what you would expect if the desktop were
coming through. It was Moonfin's own home-screen backdrop, the blurred poster preview,
which had simply finished loading. Sampling fixed screen points through the window returns a
uniform `70,70,70` — Moonfin's own UI, not wallpaper. **The window never became
transparent at all.**

The lesson is the same one the `WS_CLIPSIBLINGS` bug taught: in this spike, only the pure
bar colours count as evidence. They appear nowhere in Moonfin's UI. Anything judged by
"it looks different now" is worthless.

**The stand-in scores 0/15 in every mode**, under conditions that leave no room for doubt:

- The stand-in paints correctly — `PrintWindow` on it returns the exact bar sequence
  white, yellow, cyan, green, magenta, red, blue, black.
- A top-level stand-in does composite on screen — forced `HWND_TOPMOST`, it scores **12/15**.
- It was directly behind the Flutter window at capture time — verified with
  `GetWindow(moonfin, GW_HWNDNEXT)` returning the stand-in's own handle in the same run.

So a confirmed-visible window, directly behind, with every transparency call on the Flutter
window returning success — and not one pixel of the pattern reaches the screen. The Flutter
surface on Windows is opaque, and no accent state, DWM call or window style tried here
changes that.

## Revised architecture

Every technique above asks the same question: can the video window be seen *through* Flutter?
The answer is no, and no accent state changes it.

Mode `10` asks the opposite question, and Flutter takes no part in it. The stand-in plays the
mpv window. A second top-level window sits **above** it, `WS_EX_LAYERED`, filled by
`UpdateLayeredWindow` from a premultiplied ARGB bitmap carrying the same shape as the
player's scrims — alpha 180 at the top edge fading to 0 over the top quarter, mirrored at the
bottom, plus one fully opaque block to cover the other case.

**It works.** Sampling straight down the white bar, through the fading scrim:

```
y=0.08  ->  85     y=0.17  -> 120     y=0.23  -> 143
y=0.11  ->  97     y=0.20  -> 132     y=0.30  -> 171
```

A smooth ramp from dark to bright, which is exactly `255 * (1 - alpha/255)` as the scrim
fades out. Visually every bar is dark at its top edge and clean at its bottom, and the opaque
block renders solid. `UpdateLayeredWindow` returns 1.

This is the thing a colour key could never do, and the reason mode `2` was rejected. Real
per-pixel alpha over an arbitrary window does exist on Windows — just not through Flutter's
own surface.

```
mpv window        ← top-level, D3D11 HDR swapchain, gpu-next
└── layered window ← above it, controls as premultiplied ARGB, true alpha
```

**What this proves:** the compositing works, and gradients survive.

**What it does not prove**, and what a Phase 1 has to answer before any of this ships:

- ~~Can Flutter render the controls into that bitmap fast enough?~~ **Answered — yes, if the
  overlay is split into bands.** See below.
- Input. The layered window is `WS_EX_TRANSPARENT` here, so it is click-through. Real
  controls need clicks, wheel, keyboard, hit-testing and focus routed back into Flutter.
- Dialogs — the track selector, the info sheet — have to live in this arrangement too.
- Fullscreen, multi-monitor and DPI changes, for two windows instead of one.

None of these are the kind of unknown Q4 was. They are work, not a gate.

### Overlay throughput — PASS, and it settles the layout

`MOONFIN_HDR_Q4=11` replaces the app with a benchmark
(`lib/util/hdr_overlay_benchmark.dart`) that lays out a stand-in OSD — two scrim gradients,
a progress bar, a row of buttons — at each size and times
`RepaintBoundary.toImage()` followed by `toByteData(rawRgba)`, which is the readback that
would feed `UpdateLayeredWindow`. Twenty runs each, after three untimed warm-ups.

| Layout | Size | Per frame | Rate | Readback |
|---|---|---|---|---|
| whole window, 4K | 3814×1993 | 19.2 ms | 52 fps | 29.0 MB |
| whole window, 1080p | 1907×996 | 5.2 ms | 193 fps | 7.2 MB |
| **bottom band only, 4K** | 3814×500 | **4.9 ms** | **202 fps** | 7.3 MB |
| bottom band only, 1080p | 1907×250 | 1.5 ms | 645 fps | 1.8 MB |

Cost tracks area, as expected of a readback, and that is the design decision: **do not make
one overlay the size of the window.** Two layered windows, one per scrim band, with the clear
middle left out entirely, turn the worst case from 19.2 ms into 4.9 ms — 4K controls at over
200 fps, with the middle of the screen never read back at all. It also means the video window
is only overlapped where the controls actually are.

Two honest caveats on these numbers:

- Measured with the app otherwise idle. During real playback mpv is decoding and presenting
  4K HDR on the same GPU, so expect worse under contention. The headroom at 4.9 ms is wide
  enough that this looks survivable, but it has not been measured.
- The first table row is what a naive implementation would cost. It is included precisely
  because it is the one to avoid.

### What was left before mode 10 was tried

`flutter_native_view` is the one project that claims to do exactly this — arbitrary HWNDs
embedded under a Flutter window with widgets on top — and it is by the author of `media_kit`,
which this app already depends on. Its accent call alone does not reproduce the effect, so
whatever makes it work is in the rest of its setup: a dedicated container window, a subclass
proc on the embedded view, and `WS_EX_TRANSPARENT`/`WS_EX_LAYERED` toggled for hit-testing.
Porting that is real work on a base its own README calls unfinished — "general stability"
and "finalized API" are still open items, and the hit-test support is marked UNSTABLE.

It is also worth knowing what it would buy even if it worked. That package's own README
describes widget placement on top, not translucent widgets over the native view. Moonfin's
controls need gradient scrims, so "opaque widgets over an opaque video window" does not
clear the bar that sank the colour-key option in the first place.

The arrangement that would give true per-pixel alpha over an arbitrary window remains the
plan's own third option — `WS_EX_NOREDIRECTIONBITMAP` with DirectComposition, putting the
Flutter swapchain into a visual tree we own. The plan already called that "almost certainly
out of reach without engine work", and nothing found here changes that. It is a Flutter
engine change, not an app change.

## Re-scope

Q4 fails, so Phases 1-4 do not start. The plan named two fallbacks; only one of them
survives this result.

**Fullscreen-only with an on-demand overlay is dead too.** It assumed the controls could be
drawn over the video by a Flutter surface that Q4 has just shown to be opaque — as a child
window *and* as a top-level one. Drawing them in a separate window above the video hits the
same wall. The only way through would be to draw the player chrome natively instead of in
Flutter, which is a rewrite of the whole OSD, not a re-scope.

**What is left is the tone-mapping work, and it is worth doing on its own.** `gpu-next` and
libplacebo run through the render API as well, without owning a swapchain. That gives up HDR
passthrough but keeps the rest:

- **Dolby Vision Profile 5** — libplacebo handles the RPU, so the wrong-hue problem should
  resolve. This is the most visible single win.
- **Better tone-mapping** of HDR sources down to SDR, which is every HDR title on Windows
  today.
- **media_kit's Android defaults, undone.** It applies `dither=no`, `scale=bilinear`,
  `dscale=bilinear`, `hdr-compute-peak=no` and `sigmoid-upscaling=no` to every native
  platform (`real.dart:2389-2412`). These are phone performance defaults. `dither=no` in
  particular bands dark gradients on desktop.
- The mpv.conf allowlist additions already committed, which let a custom config reach these
  options at all.

None of it needs a native window, a second HWND, or any change to how Flutter composites,
so none of it carries the risk that sank the original scope.

**Still true and worth keeping from the original investigation:** the shipped libmpv has
everything needed for real HDR (Q1), `wid` is runtime-settable (Q2), and
`target-colorspace-hint` genuinely reconfigures the swapchain to 10-bit BT.2020 PQ (Q3). If
Flutter ever gains a transparent surface or a real platform view on Windows, this plan
becomes viable again with only Q4 to re-answer.

### Running it

```powershell
$env:MOONFIN_HDR_Q4 = "1"
.\build\windows\x64\runner\Release\moonfin.exe
```

Open any video. The player screen goes transparent, so the test pattern shows where the
Flutter UI does not paint. Look at the scrim behind the top bar and the bottom controls:
a smooth fade means pass, a hard edge or a flat wash means fail. `MOONFIN_HDR_Q4=0` or
unset restores normal rendering.

---

## Addendum — the DWM architecture works, and Q4's "opaque surface" was wrong

Validated end to end on hardware with `MOONFIN_HDR_DWM=2`: mpv in a top-level window
**behind** the runner window, the runner given per-pixel DWM transparency
(`SetWindowCompositionAttribute`, `ACCENT_ENABLE_TRANSPARENTGRADIENT`, gradient colour 0 —
flutter_acrylic's exact call), and Flutter drawing **everything natively over the video**:
controls, subtitle and audio pickers over the picture, volume OSD, dialogs, at full frame
rate, with real alpha, no capture, no readback.

Two findings unlocked it, both worth remembering:

**Every Phase 0 transparency test was invalid.** Each one sampled over opaque Flutter
content — the home screen's poster backdrop, or the player route's `barrierColor:
Colors.black` ModalBarrier painting under the page. The conclusion "the Flutter surface on
Windows is opaque" was never actually tested against a transparent frame, and it is false.

**The runner handle was wrong from the start.** The HDR windows are constructed during
`FlutterWindow::OnCreate`, *before* `SetChildContent` parents the Flutter view into the
runner — at that moment `GetAncestor(view, GA_ROOT)` returns the view itself. Everything
hung off that handle failed silently and differently: DWM transparency applied to a child
window (returns FALSE), z-order inserted relative to a child (the video landed *above* the
runner, covering the whole interface), position sync against the wrong rect. The child-mode
overlay arrangement worked by coincidence, because parenting to the view is visually
equivalent to parenting to the client area. The fix is passing `GetHandle()` explicitly.

The overlay-capture architecture remains the default and the fallback. Before the DWM
arrangement can replace it: engage it by default (and keep capture as the automatic
fallback when composition fails), teach Live TV and the mini player the same path, forward
the zoom modes to mpv, and re-verify the HDR swapchain still negotiates 10-bit PQ with the
transparent runner composited above it.
