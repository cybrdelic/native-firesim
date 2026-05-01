# Native FireSim

Clean native Windows rewrite prototype for FireSim's core idea: an interactive fire/smoke sandbox rendered locally with CUDA and shown through a Win32 window.

The generated image reference is copied into:

`assets/reference-fire-room.png`

That image is the visual target for this milestone: dark white room, bright volumetric flame, thick layered smoke, ember detail, heat glow, and floor reflections.

## Build

From this folder:

```powershell
cmd /c "`"C:\VSBuildTools\VC\Auxiliary\Build\vcvars64.bat`" && cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release"
```

## Run

```powershell
.\build\NativeFireSim.exe
```

## Verification

Render an offscreen CUDA proof frame:

```powershell
.\build\NativeFireSim.exe --smoke-test
```

That writes:

`out/smoke-test-frame.bmp`

## Controls

- Right mouse drag: orbit the camera.
- Mouse wheel: zoom the camera.
- `1`: fire/fuel source gizmo; left-drag injects hot fuel.
- `2`: smoke source gizmo; left-drag injects cold soot/smoke.
- `3`: wind gizmo; left-drag left/right to steer plume advection.
- `4`: turbulence gizmo; left-drag up/down to change breakup intensity.
- `G`: show/hide gizmos.
- Arrow left/right: steer wind.
- Arrow up/down: raise/lower turbulence.
- `R`: reset the fire fields.
- `Esc`: quit.

## Current Scope

This is a native first-pass renderer/sandbox, not a final physics solver. It already separates the parts that matter for the bigger product:

- CUDA simulation step
- orbit-camera CUDA volume renderer
- native Windows presentation
- copied visual target image
- interactive input
- projected gizmos for fire, smoke, wind, turbulence, and world axes
- ballistic ember particles with wind coupling

The live window defaults are capped at 960x540, 36 ray steps, and 30 FPS to avoid hammering the display GPU from a desktop shortcut.

Next hardening steps are real 3D voxel fields, pressure projection, Direct3D interop, video/frame export, and benchmark-driven tuning against physical burn references.

## Desktop Launcher

`C:\Users\alexf\Desktop\FireSim.lnk` still opens the existing launcher script, but that script now starts this native executable instead of the old WebGPU/Vite app. The old web launcher body is backed up beside it as:

`C:\Users\alexf\Documents\Codex\2026-04-24\my-storage-is-really-bad-right\launch-firesim.web-v2.backup.ps1`
