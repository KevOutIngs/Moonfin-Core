# Phase 0 results — native HDR video output on Windows

Gate for [windows-hdr-output-plan.md](windows-hdr-output-plan.md). Nothing in Phase 1
starts until all four questions have a written answer.

| # | Question | Answer |
|---|---|---|
| 1 | Does the shipped libmpv have `gpu-next`, `gpu-api=d3d11`, `target-colorspace-hint`? | **PASS** |
| 2 | Is `wid` settable after `mpv_initialize`? | **PASS** |
| 3 | Does HDR actually reach the display? | **PASS** |
| 4 | Can the Flutter window get per-pixel alpha over that window? | **FAIL** |

**The gate is not met.** Q1-Q3 all pass — the HDR half of the plan works, on the libmpv that
ships today. Q4 does not, and per the plan that stops Phases 1-4. See
[the re-scope](#re-scope) at the end.

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
| `7` | `flutter_acrylic`'s own call, `ACCENT_DISABLED` flags 2 | 0/15 | **FAIL** — window goes translucent, but against the wallpaper |
| `8` | mode 7 + `DwmExtendFrameIntoClientArea(-1)` | 0/15 | **FAIL** — same |
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

### The Flutter window *can* be transparent — that is not what blocks this

An earlier version of this document concluded "the Flutter surface on Windows is opaque".
That was wrong, and `flutter_acrylic` is the counter-example that prompted the re-test: it
makes real Flutter apps translucent on Windows every day.

Modes `7` and `8` use its actual call rather than the guesses in modes 1 and 4 —
`ACCENT_DISABLED` with flags `2` and a zero gradient colour, on
`GetAncestor(view, GA_ROOT)`, mode 8 adding `DwmExtendFrameIntoClientArea` with margins of
`-1`. Every call returns success, now logged:

```
DwmExtendFrameIntoClientArea(-1) -> 0x00000000
SetWindowCompositionAttribute(state 0, flags 2, colour 00000000) -> 1, GetLastError 0
```

And it works. The window goes translucent and the desktop shows through the player UI.

**What it composites against is the problem.** The stand-in still scores 0/15 in modes 7 and
8, under conditions that leave no room for doubt:

- The stand-in paints correctly — `PrintWindow` on it returns the exact bar sequence
  white, yellow, cyan, green, magenta, red, blue, black.
- A top-level stand-in does composite on screen — forced `HWND_TOPMOST`, it scores **12/15**.
- It was directly behind the Flutter window at capture time — verified with
  `GetWindow(moonfin, GW_HWNDNEXT)` returning the stand-in's own handle in the same run.

So a transparent Flutter window over a confirmed-visible window, with the two adjacent in
the z-order, and none of the pattern comes through. What comes through instead is **blurred**,
while the stand-in is sharp. That is the signature of DWM's backdrop: accent, acrylic and
mica all sample the *desktop wallpaper*, not the application windows underneath. They make a
window translucent against the shell, not against whatever happens to sit behind it.

Which is exactly the wrong kind of transparency here. The video window is an application
window, so it is precisely what a backdrop effect ignores.

The one arrangement that would give true per-pixel alpha over an arbitrary window is the
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
