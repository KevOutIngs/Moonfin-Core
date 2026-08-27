# Phase 0 results — native HDR video output on Windows

Gate for [windows-hdr-output-plan.md](windows-hdr-output-plan.md). Nothing in Phase 1
starts until all four questions have a written answer.

| # | Question | Answer |
|---|---|---|
| 1 | Does the shipped libmpv have `gpu-next`, `gpu-api=d3d11`, `target-colorspace-hint`? | **PASS** |
| 2 | Is `wid` settable after `mpv_initialize`? | **PASS** |
| 3 | Does HDR actually reach the display? | **PASS** |
| 4 | Can the Flutter window get per-pixel alpha over that window? | *spike built, awaiting a run on real hardware* |

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

### Running it

```powershell
$env:MOONFIN_HDR_Q4 = "1"
.\build\windows\x64\runner\Release\moonfin.exe
```

Open any video. The player screen goes transparent, so the test pattern shows where the
Flutter UI does not paint. Look at the scrim behind the top bar and the bottom controls:
a smooth fade means pass, a hard edge or a flat wash means fail. `MOONFIN_HDR_Q4=0` or
unset restores normal rendering.
