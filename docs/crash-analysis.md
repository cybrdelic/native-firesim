# Crash Analysis

## Observed Failures

Three Windows bugchecks were recorded during live CUDA testing:

- `2026-04-30 22:06:38`: bugcheck `0x00000139`, dump `C:\Windows\Minidump\043026-30062-01.dmp`
- `2026-04-30 22:30:57`: bugcheck `0x000000d1`, dump `C:\Windows\Minidump\043026-17593-01.dmp`
- `2026-05-01 18:39:40`: bugcheck `0x000000d1`, dump `C:\Windows\Minidump\050126-21062-01.dmp`

The second crash happened while interacting with a gizmo in the live app. The May 1 crash happened after a live CUDA launch. `0xD1` is `DRIVER_IRQL_NOT_LESS_OR_EQUAL`, so this is a kernel/driver failure path, not a normal user-mode exception.

## Local Driver Snapshot

Before cleanup, `nvidia-smi` reported:

- GPU: NVIDIA GeForce RTX 4060 Laptop GPU
- Driver: `576.57`
- CUDA: `12.9`
- Driver model: WDDM

After the May 1 recovery pass:

- NVIDIA Studio notebook driver `581.57` was downloaded from NVIDIA and installed with clean/no-reboot flags.
- `nvidia-smi` now reports driver `581.57` and CUDA `13.0`.
- `Win32_VideoController` reports NVIDIA driver version `32.0.15.8157`, dated `2025-10-08`.
- The NVIDIA setup log reports the installation succeeded, with reboot required.
- Edge hardware acceleration policy is disabled in both HKCU and HKLM.
- Hardware-accelerated GPU scheduling is set disabled with `HwSchMode = 1`; reboot is required for this to take effect.

After reboot:

- Boot time: `2026-05-01 20:20:35`
- Pending reboot/file rename flags: clear
- `nvidia-smi`: driver `581.57`, GPU idle, `0 MiB` used, `0%` utilization
- Safe verifier: `scripts\verify.ps1` passed without FireSim simulation kernels
- Post-boot display/nvlddmkm/bugcheck event query: no matching events
- Minimal CUDA canary: `scripts\cuda-canary.cu` compiled and ran successfully with `deviceCount=1`, copied value `12345`
- Earlier reduced smoke run exited `0`
- Earlier reduced validation run exited `0` with `validationOk=true`
- Preview validation metrics: grid `104x112x72`, average solve `1.949756 ms`, average render `25.771320 ms`, max flame height `2.020937 m`, image max luma `0.983957`
- Post-smoke/validation display/nvlddmkm/bugcheck event query: no matching events
- Earlier reduced interactive launch stayed alive and responding after 10 seconds
- Interactive preview GPU state: driver `581.57`, `64C`, `P0`, `170 MiB`, `74%` utilization, no matching display/nvlddmkm/bugcheck events

Those preview commands were run before the two-flag safety gate. Current GPU runs require both `--allow-gpu-kernels` and `--accept-bugcheck-risk`.

Windows also logged repeated `WUDFRd failed to load` warnings for Intel audio / PCI devices around reboot. Those warnings happen during boot and are not enough by themselves to prove the root cause.

## Current Runtime Policy

The main app viewport no longer initializes CUDA or submits custom simulation/render kernels in the UI process. It starts an isolated CUDA worker process for the real 3D volume and receives frames through shared memory. If the worker exits, stalls, or does not publish a fresh frame, the UI remains alive and falls back to the animated replay preview. There is still no CPU fire simulator fallback. There is one canonical CUDA runtime configuration; the project no longer switches between lower-quality and reference-quality modes.

The worker contract now includes heartbeat and restart policy: frame stale after `2200 ms`, heartbeat stale after `3400 ms`, forced worker termination after `7200 ms`, and at most three restarts per minute before cooldown. The UI status rail shows the current worker state, and worker lifecycle events append to `out/worker-events.log`.

- no args: opens the UI process and starts the isolated CUDA worker for real 3D volume frames
- `--disable-cuda-worker`: opens the safe animated preview; no CUDA kernel launch
- `--cuda-worker --allow-gpu-kernels --accept-bugcheck-risk --parent-pid=<pid>`: internal worker process mode
- `--smoke-test` / `--cuda-smoke-test`: blocked unless `--allow-gpu-kernels --accept-bugcheck-risk` is present
- `--validation` / `--validate`: blocked unless `--allow-gpu-kernels --accept-bugcheck-risk` is present
- `--diagnostics`: CUDA/runtime/device query, no simulation kernel
- `scripts/verify.ps1`: build, lint, diagnostics, and input stress without simulation kernels
- `scripts/verify.ps1 -RunGpuKernels -AcceptBugcheckRisk`: smoke test plus validation with the explicit kernel and bugcheck-risk flags

The safety gate writes `out/gpu-safety-stop.txt` when it blocks a launch.

## May 1 Dump Analysis

The May 1 minidump was copied locally with an elevated helper and analyzed with `cdb.exe` from the Microsoft WinDbg package:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\analyze-dump-elevated.ps1 `
  -DumpPath C:\Windows\Minidump\050126-21062-01.dmp
```

The debugger result identifies NVIDIA's kernel display driver as the faulting module:

- dump: `C:\Windows\Minidump\050126-21062-01.dmp`
- local copy: `out\050126-21062-01.dmp`
- analysis output: `out\dump-analysis.txt`
- bugcheck: `DRIVER_IRQL_NOT_LESS_OR_EQUAL (d1)`
- read address: `0x80`
- IRQL: `2`
- faulting instruction: `nvlddmkm+db81f6`
- failure bucket: `AV_nvlddmkm!unknown_function`
- module: `nvlddmkm`
- image: `nvlddmkm.sys`
- active process at crash time: `msedge.exe`
- driver timestamp from `lmvm nvlddmkm`: `Mon May 19 22:26:57 2025`

The key stack segment is:

```text
nt!KeBugCheckEx
nt!KiBugCheckDispatch+0x69
nt!KiPageFault+0x468
nvlddmkm+0xdb81f6
nvlddmkm+0xdaea00
```

`PROCESS_NAME: msedge.exe` means Edge was the active user-mode process when the kernel fault was captured. It does not prove Edge caused the crash. The faulting code path is inside `nvlddmkm.sys`, which is shared by desktop composition, browser GPU acceleration, CUDA, and other GPU clients.

## Current Read

This is a driver/WDDM failure path, not a normal NativeFireSim user-mode exception. NativeFireSim can still be the trigger by submitting CUDA work that the NVIDIA kernel driver mishandles, but a user-mode C++ bug should not be able to directly reboot Windows. The UI process now stays outside CUDA, and the CUDA worker is the only live interactive compute owner. This improves process recovery and UI resilience, but it cannot make a faulty kernel-mode NVIDIA driver path impossible to bugcheck.

Do not increase grid size, pressure iterations, raymarch steps, or launch duration on this machine until the driver crash path is stabilized.

## NativeFireSim Trigger Found

The CUDA helper `smoothstepf(edge0, edge1, x)` used recursion when `edge1 < edge0`:

```cpp
return 1.0f - smoothstepf(edge1, edge0, x);
```

That pattern was used throughout the scalar, force, room, gizmo, and raymarch kernels. CUDA accepted the code, but `nvlink` reported that stack size for `resetScalarsKernel`, `advectReactKernel`, and `renderKernel` could not be statically determined. Those are exactly the long-running kernels most likely to stress the NVIDIA WDDM/CUDA path.

The helper is now non-recursive. It computes the lower/upper edge once and returns the inverted result without a device call back into itself. After that change, the safe verifier rebuilt the CUDA target without the previous unknown-stack `nvlink` warnings.

The renderer has also been split so the heavy raymarch kernel no longer draws embers, gizmos, or final display packing. Raymarching writes HDR CUDA radiance, then a separate tone-map kernel and overlay kernel finish the display frame. Heavy 3D kernels now launch through bounded 12-layer z windows, and raymarch/tonemap/overlay kernels launch through bounded 36-row frame windows. All CUDA kernels use explicit launch bounds, the internal raymarch cap is 72 steps, and the build no longer enables CUDA separable compilation because the project has a single CUDA translation unit.

This does not prove the NVIDIA driver cannot crash again. It does identify and remove the strongest NativeFireSim-side trigger found so far: recursive device code inside large kernels submitted to a driver path that already crashed in `nvlddmkm.sys`.
