# GPU Engineering Policy

NativeFireSim treats GPU work as production kernel code, not shader toy code. A bad user-mode launch should not bugcheck Windows, but this project has already triggered NVIDIA's WDDM driver path, so the codebase now follows stricter rules.

## Kernel Rules

1. No recursive device functions.
2. No CUDA kernels with unknown stack size warnings.
3. Every kernel has explicit launch bounds.
4. Heavy kernels have one job. Raymarching, tonemapping, overlays, metrics, and solver passes are separate launches.
5. Simulation kernels stay bounded by fixed grid caps, fixed pressure iterations, and fixed raymarch caps.
6. Every launch is followed by `cudaGetLastError`.
7. The main viewport process never submits custom CUDA kernels; live CUDA runs in the worker process.
8. Long GPU runs are opt-in behind both `--allow-gpu-kernels` and `--accept-bugcheck-risk`.
9. Validation metrics are opt-in so the batch validation path pays for reductions, not the main app.
10. Heavy 3D and raymarch kernels are submitted in bounded slices so WDDM never receives one large monolithic frame kernel.

## Current Risk Controls

- CUDA separable compilation is disabled because all device code lives in one CUDA translation unit.
- CUDA line info is enabled for debugger/profiler attribution.
- The raymarch cap is 72 samples per pixel.
- Raymarching writes CUDA `float4` HDR radiance first; `tonemapKernel` performs ACES display mapping and dithering before the BGRA display copy.
- Embers and gizmos run in `overlayKernel`, outside `renderKernel`.
- 3D volume work is sliced into 12-z-layer kernel windows.
- Raymarch and overlay work are sliced into 36-row frame windows.
- There is one canonical runtime configuration: 384x240 requested grid, 72 raymarch steps, and 176 embers.
- The recursive `smoothstepf` helper was replaced with a non-recursive inverted-edge implementation.
- The main app starts an isolated CUDA worker for real 3D volume frames and falls back to safe animated replay if worker frames are stale.
- The shared frame transport is `Local\NativeFireSimViewportFrameV1`.
- UI-to-worker settings use an odd/even sequence counter so the worker does not consume a torn settings struct.
- Worker frames are considered stale after `2200 ms`; worker heartbeat is stale after `3400 ms`; a worker that exceeds `7200 ms` without heartbeat is terminated.
- Worker restarts are limited to three per minute before cooldown.
- Worker lifecycle events are appended to `out/worker-events.log`.
- GPU smoke/validation commands are blocked unless the caller explicitly accepts bugcheck risk.

## Safe Verification

Use this for normal development:

```powershell
.\scripts\verify.ps1 -DiagnosticsOnly
```

That path builds, runs lint/slop checks, runs CUDA diagnostics, and runs input stress. It does not launch simulation kernels.

Use this only when intentionally testing the NVIDIA driver path:

```powershell
.\scripts\verify.ps1 -RunGpuKernels -AcceptBugcheckRisk
```

After any risky run, query recent system events for `BugCheck`, `Display`, `nvlddmkm`, `NVIDIA`, `WHEA`, `Kernel-Power`, and event IDs `41`, `1001`, `4101`, `17`, `18`, and `19`.

## Next Hardening Targets

1. Replace shared CPU BGRA frames with Direct3D/CUDA external-memory textures and GPU semaphores.
2. Add temporal resolve so the sliced raymarcher can accumulate more samples across frames without increasing per-kernel watchdog residency.
3. Replace atomic velocity forcing with staged force buffers.
4. Replace red/black SOR with a bounded multigrid or PCG pressure solve.
5. Add optional per-kernel synchronization for crash reproduction sessions only.
6. Add Nsight Compute resource snapshots for registers, local memory, occupancy, and spills.
