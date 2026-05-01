# Native FireSim

Clean native Windows rewrite prototype for FireSim's core idea: an interactive fire/smoke sandbox shown through a Win32 window. The default launcher uses a safe CPU preview; CUDA remains available only behind explicit opt-in flags.

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

The default interactive app uses the safe CPU preview path. It does not launch live CUDA kernels.

To opt into the experimental live CUDA backend:

```powershell
.\build\NativeFireSim.exe --allow-live-cuda
```

## Verification

Build, collect diagnostics, and render a safe CPU proof frame:

```powershell
.\scripts\verify.ps1
```

Render only the safe CPU smoke frame:

```powershell
.\build\NativeFireSim.exe --smoke-test
```

That writes:

`out/cpu-smoke-test-frame.bmp`

CUDA diagnostics only, without simulation kernels:

```powershell
.\build\NativeFireSim.exe --diagnostics
```

Explicit CUDA smoke test:

```powershell
.\build\NativeFireSim.exe --cuda-smoke-test
```

## Controls

- Right mouse drag: orbit the camera in the safe preview and CUDA opt-in modes.
- Mouse wheel: zoom the camera.
- Click the fire, smoke, wind, or turbulence gizmo to select that tool.
- `1`: fire/fuel source; left-drag injects hot flame at the cursor.
- `2`: smoke source; left-drag injects cold soot/smoke at the cursor.
- `3`: wind; left-drag left/right to steer plume advection.
- `4`: turbulence; left-drag up/down to change breakup intensity.
- `G`: show/hide gizmos.
- Arrow left/right: steer wind.
- Arrow up/down: raise/lower turbulence.
- `R`: reset the fire fields.
- `Esc`: quit.

## Current Scope

This is a native first-pass renderer/sandbox, not a final physics solver. It currently separates the parts that matter for the bigger product:

- CUDA simulation step
- orbit-camera CUDA volume renderer
- safe CPU preview renderer
- native Windows presentation
- copied visual target image
- interactive input
- projected gizmos for fire, smoke, wind, turbulence, and world axes
- ballistic ember particles with wind coupling

The live CUDA path is opt-in. The desktop launcher opens the safe CPU preview so a shortcut click does not run heavy display-GPU kernels.

Next hardening steps are real 3D voxel fields, pressure projection, Direct3D interop, video/frame export, and benchmark-driven tuning against physical burn references.

See:

- `docs/crash-analysis.md`
- `docs/physics-architecture.md`

## Desktop Launcher

`C:\Users\alexf\Desktop\FireSim.lnk` still opens the existing launcher script, but that script now starts this native executable instead of the old WebGPU/Vite app. The old web launcher body is backed up beside it as:

`C:\Users\alexf\Documents\Codex\2026-04-24\my-storage-is-really-bad-right\launch-firesim.web-v2.backup.ps1`
