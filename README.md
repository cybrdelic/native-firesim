# Native FireSim

Clean native Windows rewrite prototype for FireSim's core idea: a CUDA fire/smoke solver with a native Win32 operator shell. The main app viewport does not submit custom CUDA kernels directly. It starts an isolated CUDA worker process and receives real 3D volume frames through shared memory. There is no animated simulation fallback in the main viewport.

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

The main app opens the operator UI and starts the isolated CUDA worker by default. The primary UI process never owns CUDA initialization or kernel submission. The worker boundary is intentional: the primary UI cannot be allowed to be the CUDA crash surface. If the worker exits or stops publishing fresh frames, the viewport stays alive and shows an explicit no-live-CUDA-frame state instead of faking motion.

The runtime now includes production-style worker lifecycle controls:

- stable seqlock handoff for UI settings sent to the worker
- worker heartbeat and frame-age monitoring
- stale-worker termination after `7200 ms`
- restart backoff after repeated worker exits
- visible worker status in the viewport status rail
- event log at `out/worker-events.log`

## Verification

Build, collect diagnostics, and stress the native UI clamps without launching CUDA kernels:

```powershell
.\scripts\verify.ps1
```

Build and collect CUDA diagnostics without launching simulation kernels:

```powershell
.\scripts\verify.ps1 -DiagnosticsOnly
```

Check that benchmark/calibration files have lab-grade structure and provenance fields without launching CUDA kernels:

```powershell
.\scripts\verify-lab-grade.ps1
```

When admitting a real measured burn dataset, require non-template source, license, uncertainty, and populated measurement channels:

```powershell
.\scripts\verify-lab-grade.ps1 -RequireRealDataset
```

The default real-dataset gate uses the imported NIST FCD `Methanol_1m_Pool_R1` benchmark when present:

```powershell
.\scripts\import-nist-fcd-methanol-r1.ps1
.\scripts\verify-lab-grade.ps1 -RequireRealDataset
```

Run the full GPU smoke and validation gates only when you are intentionally testing the driver crash path:

```powershell
.\scripts\verify.ps1 -RunGpuKernels -AcceptBugcheckRisk
```

Render only the CUDA smoke frame:

```powershell
.\build\NativeFireSim.exe --smoke-test --allow-gpu-kernels --accept-bugcheck-risk
```

That writes:

`out/cuda-smoke-test-frame.bmp`

Run the CUDA validation harness:

```powershell
.\build\NativeFireSim.exe --validation --allow-gpu-kernels --accept-bugcheck-risk
```

Run the completed-frame worker benchmark for the live CUDA/D3D path:

```powershell
.\build\NativeFireSim.exe --worker-benchmark --warmup-frames=8 --benchmark-frames=16 --output-dir=out\worker-benchmark --allow-gpu-kernels --accept-bugcheck-risk
```

Run validation against an external target envelope:

```powershell
.\build\NativeFireSim.exe --validation --targets=benchmarks\reference-fire-room-envelope.csv --allow-gpu-kernels --accept-bugcheck-risk
```

Run the manifest-driven NIST FCD calibration runner. This verifies the real dataset first, launches the bounded CUDA validation path only with explicit risk acceptance, then writes experiment-scoped metrics, a sim-vs-measured CSV, JSON, PNG, and GIF:

```powershell
.\scripts\run-nist-calibration.ps1 -RunGpuKernels -AcceptBugcheckRisk
```

That writes:

- `out/validation/NIST_FCD_Methanol_1m_Pool_R1/validation-metrics.csv`
- `out/validation/NIST_FCD_Methanol_1m_Pool_R1/calibration-comparison.csv`
- `out/validation/NIST_FCD_Methanol_1m_Pool_R1/validation-report.json`
- `out/validation/NIST_FCD_Methanol_1m_Pool_R1/sim-vs-nist-comparison.png`
- `out/validation/NIST_FCD_Methanol_1m_Pool_R1/sim-vs-nist-hrr.gif`
- `out/validation/NIST_FCD_Methanol_1m_Pool_R1/validation-frame.bmp`
- `out/validation/NIST_FCD_Methanol_1m_Pool_R1/validation-app-frame.bmp`

The lower-level native executable still accepts direct sidecars for custom runs:

```powershell
.\build\NativeFireSim.exe --validation --manifest=benchmarks\nist-fcd\methanol-1m-pool-r1\manifest.json --calibration=benchmarks\nist-fcd\methanol-1m-pool-r1\calibration.csv --geometry=benchmarks\nist-fcd\methanol-1m-pool-r1\geometry.json --targets=benchmarks\nist-fcd\methanol-1m-pool-r1\validation-targets.csv --output-dir=out\validation\NIST_FCD_Methanol_1m_Pool_R1 --pool-fire-calibration --allow-gpu-kernels --accept-bugcheck-risk
```

CUDA diagnostics only, without simulation kernels:

```powershell
.\build\NativeFireSim.exe --diagnostics
```

`--cuda-smoke-test` is kept as an alias for `--smoke-test`.

## Controls

- Right mouse drag: orbit controls are preserved in the shell UI.
- Mouse wheel: zoom the camera.
- Click the left toolbar to select fire, smoke, wind, or turbulence.
- Drag the right panel sliders to tune wind and turbulence.
- The main process sends controls to the CUDA worker over shared memory. If no worker frame is fresh, the viewport does not synthesize a fake simulation frame.
- `1`: fire/fuel source; left-drag injects hot flame at the cursor.
- `2`: smoke source; left-drag injects cold soot/smoke at the cursor.
- `3`: wind.
- `4`: turbulence.
- `G`: show/hide viewport overlays.
- Arrow left/right: steer wind.
- Arrow up/down: raise/lower turbulence.
- `R`: reset the fire fields.
- `Esc`: quit.

## Current Scope

The main app path is process-isolated: no custom CUDA kernels are submitted by the primary viewport process. The CUDA worker owns the real 3D volume simulation and renderer, accumulates linear HDR CUDA radiance, writes FP16 radiance directly into a mapped D3D11 surface, copies that private CUDA interop texture into the shared keyed-mutex viewport texture exposed through `Local\NativeFireSimViewportFrameV6`, and is stopped when the UI exits. The CUDA solver architecture is:

- CUDA 3D MAC-style simulation step with staggered velocity, weighted red/black pressure projection, heat, fuel vapor, oxygen, and soot channels
- GPU fuel-bed state seeded as broken material chunks with char, ash, pyrolysis release, oxygen-limited heat release, soot formation, soot oxidation, and radiative cooling terms
- flame-front progress variable and LES-style scalar turbulence-energy closure coupled into buoyancy and breakup
- clamped MacCormack/BFECC correction over transported scalar fields to reduce numerical smearing
- orbit-camera CUDA volume renderer that raymarches the 3D fields into an HDR float buffer with white-hot blackbody cores, Beer-Lambert extinction, particle-size-derived soot absorption/scattering, colder gray/black smoke, volume self-shadowing, emitter scattering, domain-warped volume sampling, ACES display tonemapping, dithering, and reflective floor response
- target-room scene model with a shallow tray, dark reflective floor, smoky wall staining, ceiling fixtures, left-side glass, vignetting, and reference material response
- native Windows presentation
- copied visual target image
- interactive input
- native viewport UI with a tool rail, field controls, and viewport overlays
- ballistic ember particles with wind coupling
- 300 FPS presentation target with immediate D3D present and no quality-mode downgrade
- sparse HDR ember splats instead of full-screen per-pixel ember loops
- cached per-frame camera basis for CUDA ray generation instead of per-pixel trigonometry
- completed-frame worker benchmark for the CUDA/D3D path so FPS compares finished frames instead of queued submissions
- CUDA validation metrics for divergence before/after projection, scalar totals, char/ash/pyrolysis/progress/turbulence/soot-optical totals, flame height, optical depth, heat-release proxy, invalid cells, and GPU solve/render timing
- optional benchmark target envelopes via `--targets=<csv>`, manifest provenance via `--manifest=<json>`, experiment-scoped outputs via `--output-dir=<dir>`, and measured burn sidecars via `--calibration=<csv> --geometry=<json>` for calibration against HRR, derived mass loss, smoke optical depth, radiant heat flux, thermocouples, IR, video-derived plume height, and geometry data

The CUDA backend has one canonical runtime configuration: requested 384x240 simulation grid, capped internally to 176x208x128, 104 raymarch steps, 176 ember samples, neutral black/gray soot, reduced floor glow, and target-room shading. It uses 40 weighted red/black pressure iterations, early ray termination, bounded z-sliced volume launches, bounded row-sliced raymarch launches, an internal HDR radiance buffer, and direct FP16 D3D11 surface publication without an intermediate CUDA FP16 staging buffer. Metrics collection is only enabled by the validation path. The main app process does not call this path; the worker does.

Next hardening steps are explicit interprocess GPU fence/semaphore publication, video/frame export, calibrated material constants from a real burn dataset, sparse brick allocation for inactive volume regions, and replacing the fixed SOR projection with a residual-targeted multigrid or PCG solve.

See:

- `docs/crash-analysis.md`
- `docs/physics-architecture.md`
- `docs/reference-target.md`
- `docs/gpu-engineering.md`
- `docs/lab-grade-roadmap.md`
- `docs/infrastructure-hardening-plan.md`

## Desktop Launcher

`C:\Users\alexf\Desktop\FireSim.lnk` opens:

`C:\Users\alexf\Documents\Codex\2026-04-30\all-right-so-i-want-you\native-firesim\launch-firesim.ps1`

By default it opens the native app with the isolated CUDA worker enabled, so the viewport can display the real 3D volume while the UI process remains outside CUDA. The old April launcher path delegates to this script so stale calls still work. GPU flags are accepted only with `-SmokeTest` or `-Validation`.

The old web launcher body is backed up beside it as:

`C:\Users\alexf\Documents\Codex\2026-04-24\my-storage-is-really-bad-right\launch-firesim.web-v2.backup.ps1`
