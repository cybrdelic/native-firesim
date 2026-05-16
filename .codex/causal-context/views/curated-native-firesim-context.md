# Causal Context View: native firesim cuda worker nist calibration validation d3d shared viewport fire settings volume metrics lab-grade gpu risk benchmark build

## Operational Thesis
Relevant state centers on The NIST calibration runner resolves a manifest to geometry, calibration CSV, target envelopes, output directory, and only launches CUDA validation with explicit risk acceptance.; Native FireSim presents live fire through a process-isolated CUDA worker rather than by running CUDA kernels inside the UI process.; The build produces a native Win32 C++17/CUDA17 executable targeting RTX 4060 Laptop GPU compute capability 8.9 and linking D3D11/DXGI/D3DCompiler..

## Relevant Frames

### `native-firesim.mechanism.nist-calibration-runner`

- score: `96`
- type/status/confidence: `mechanism` / `verified` / `0.92`
- state: The NIST calibration runner resolves a manifest to geometry, calibration CSV, target envelopes, output directory, and only launches CUDA validation with explicit risk acceptance.
- mechanism: calibration_run := verify_dataset(manifest) -> if risk_accepted then native_validation(...) else write_plan
- parents: native-firesim.dataset.nist-fcd-methanol-r1, native-firesim.operator.validation-metrics, native-firesim.constraint.gpu-kernel-risk-gate
- interventions: run scripts/run-nist-calibration.ps1 -PlanOnly and inspect calibration-run-plan.json, run with -RunGpuKernels without -AcceptBugcheckRisk and verify it blocks, run with fake missing manifest file and verify path resolution fails before CUDA
- abstractions: pipeline-orchestrator, verification-surface, risk-gated experiment
- evidence:
  - `source` scripts/run-nist-calibration.ps1:16 — Default manifest path points to NIST FCD methanol pool-fire dataset.
  - `source` scripts/run-nist-calibration.ps1:56 — Runner invokes verify-lab-grade before CUDA validation.
  - `source` scripts/run-nist-calibration.ps1:62 — Without RunGpuKernels, runner writes a plan and does not launch CUDA.
  - `observation` out/validation/NIST_FCD_Methanol_1m_Pool_R1/calibration-run-plan.json — Plan generated with readyToRunCuda=false and explicit reason.

### `native-firesim.pipeline.ui-to-worker-to-viewport`

- score: `92`
- type/status/confidence: `mechanism` / `inferred` / `0.85`
- state: Native FireSim presents live fire through a process-isolated CUDA worker rather than by running CUDA kernels inside the UI process.
- mechanism: visible_frame := ui_present(copy(shared_fp16_d3d11_texture(worker_render(step(settings)))))
- parents: native-firesim.contract.shared-viewport-buffer, native-firesim.mechanism.worker-lifecycle-watchdog, native-firesim.mechanism.cuda-volume-step, native-firesim.presentation.d3d-ui-compositor
- interventions: run NativeFireSim.exe with default worker path and inspect out/worker-events.log, do(disable_cuda_worker) and verify the viewport reports no live CUDA frame instead of synthesizing motion, simulate stale worker heartbeat and verify UI status changes without killing the UI process
- abstractions: pipeline-orchestrator, crash-boundary, dynamic expansion target
- evidence:
  - `source` README.md:3 — README states the main viewport starts an isolated CUDA worker and receives real 3D volume frames through shared memory.
  - `source` src/main.cpp:3454 — WinMain routes diagnostics, worker benchmark, cuda worker, validation, smoke test, and default interactive UI.
  - `source` src/main.cpp:3496 — Default interactive path starts the CUDA worker when enabled.
  - `source` src/main.cpp:3555 — Main loop copies worker frames and falls back to explicit no-live-frame state when stale.

### `native-firesim.build.native-cuda-d3d11-target`

- score: `87`
- type/status/confidence: `constraint` / `observed` / `0.88`
- state: The build produces a native Win32 C++17/CUDA17 executable targeting RTX 4060 Laptop GPU compute capability 8.9 and linking D3D11/DXGI/D3DCompiler.
- mechanism: NativeFireSim.exe := cmake(CXX17, CUDA17, arch=89, src/main.cpp + src/fire_cuda.cu, d3d11/dxgi/d3dcompiler)
- interventions: change CMAKE_CUDA_ARCHITECTURES and verify build target changes, remove d3d11 link and verify linker failure at D3D integration points, run scripts/verify.ps1 -DiagnosticsOnly after toolchain changes
- abstractions: runtime-configuration, build contract, platform constraint
- evidence:
  - `source` CMakeLists.txt:3 — Project declares CXX and CUDA languages.
  - `source` CMakeLists.txt:12 — CUDA architecture is set to 89 for RTX 4060 Laptop GPU.
  - `source` CMakeLists.txt:14 — NativeFireSim executable includes main.cpp, fire_cuda.cu, and fire_cuda.h.
  - `source` CMakeLists.txt:24 — Target links user32, winmm, d3d11, dxgi, and d3dcompiler.

### `native-firesim.benchmark.completed-worker-frame`

- score: `83`
- type/status/confidence: `observation` / `observed` / `0.85`
- state: The worker benchmark measures completed CUDA/D3D frames and writes a JSON report with timing breakdowns rather than queue-submission timing.
- mechanism: worker_benchmark_report := time(completed_worker_frames) + sampled_gpu_breakdown
- parents: native-firesim.mechanism.cuda-volume-step, native-firesim.presentation.d3d-ui-compositor
- interventions: run --worker-benchmark with explicit GPU risk acceptance and inspect worker-benchmark.json, compare benchmark output before and after changing raymarch steps, assert timingMode states completed-frame timing rather than queued submissions
- abstractions: verification-surface, performance probe, intervention measurement
- evidence:
  - `source` README.md:91 — README documents completed-frame worker benchmark command.
  - `source` src/main.cpp:2064 — runWorkerBenchmark parses benchmark arguments and output dir.
  - `source` src/main.cpp:2194 — Benchmark samples FireCudaFrameMetrics after live timing.
  - `source` src/main.cpp:2240 — Report records timingMode as live frames timed without metrics, with GPU breakdown sampled after live timing.

### `native-firesim.contract.shared-viewport-buffer`

- score: `81`
- type/status/confidence: `constraint` / `observed` / `0.91`
- state: SharedViewportBuffer is the ABI between the UI process and the CUDA worker.
- mechanism: handoff_valid := magic/version/buildStamp/displayFormat match && frameSequence is stable_even && texture_slot is acquireable
- parents: native-firesim.build.native-cuda-d3d11-target
- interventions: change kSharedViewportVersion and verify stale mappings are reset, corrupt buildStamp in a fixture and assert initializeSharedViewport resets the buffer, force an odd frameSequence and verify UI refuses the candidate frame
- abstractions: state-contract, shared-memory contract, worker boundary
- evidence:
  - `source` src/main.cpp:45 — Shared viewport magic, version, display format, and name are constants.
  - `source` src/main.cpp:85 — SharedViewportBuffer contains frame sequence, worker status, settings, timing, texture handles, and status text.
  - `source` src/main.cpp:1689 — initializeSharedViewport creates/maps the named buffer and resets incompatible mappings.
  - `source` src/main.cpp:1747 — writeWorkerSettings sends FireSettings through the shared buffer.

### `native-firesim.mechanism.cuda-volume-step`

- score: `79`
- type/status/confidence: `mechanism` / `inferred` / `0.84`
- state: The CUDA backend advances and renders a 3D fire volume from FireSettings through field advection, reaction, pressure projection, lighting, raymarching, and packing.
- mechanism: frame_pixels, metrics := pack(raymarch(light(project(react(advect(fields, settings))))))
- parents: native-firesim.contract.fire-settings, native-firesim.operator.validation-metrics
- interventions: run smoke test with accepted GPU risk and compare cuda-smoke-test-frame.bmp to expected nonblank output, set renderDebugMode to isolate velocity/reaction/smoke channels and inspect output metrics, reduce pressure iterations in a branch and verify divergenceAfter metrics worsen
- abstractions: transformation-mechanism, physics state transition, renderer pipeline
- evidence:
  - `source` src/fire_cuda.cu:845 — advectReactKernel updates combustion-related scalar channels.
  - `source` src/fire_cuda.cu:1089 — divergenceKernel begins pressure projection mechanics.
  - `source` src/fire_cuda.cu:1105 — sorPressureKernel performs weighted red/black pressure relaxation.
  - `source` src/fire_cuda.cu:1706 — renderKernel raymarches volume fields into a frame.
  - `source` src/fire_cuda.cu:2926 — fireCudaStepAndRenderMeasured exposes measured frame stepping.

### `native-firesim.operator.validation-metrics`

- score: `79`
- type/status/confidence: `observation` / `observed` / `0.9`
- state: Validation mode converts CUDA simulation frames into metrics, CSV rows, BMP frames, and a JSON report.
- mechanism: validation_artifacts := summarize(fireCudaStepAndRenderMeasured(settings), target_envelopes, calibration_sidecars)
- parents: native-firesim.mechanism.cuda-volume-step, native-firesim.dataset.nist-fcd-methanol-r1
- interventions: run --validation with explicit GPU risk acceptance and inspect validation-report.json, tighten validation-targets.csv and verify validationOk flips when metrics exceed envelopes, remove calibration sidecar and assert comparison CSV is missing or degraded
- abstractions: observation-operator, verification-surface, calibration bridge
- evidence:
  - `source` src/fire_cuda.h:16 — FireCudaFrameMetrics declares divergence, timing, scalar totals, flame height, optical depth, and heat-release proxy fields.
  - `source` src/main.cpp:3048 — Validation mode chooses frame count and output paths.
  - `source` src/main.cpp:3071 — Validation metrics CSV header includes solver, render, scalar, and divergence columns.
  - `source` src/main.cpp:3292 — Validation report writes validationOk from stability and artifact-writing checks.

### `native-firesim.constraint.gpu-kernel-risk-gate`

- score: `74`
- type/status/confidence: `constraint` / `observed` / `0.9`
- state: Live CUDA kernel paths are intentionally blocked unless the caller explicitly supplies GPU run and bugcheck-risk acceptance flags.
- mechanism: allow_gpu_kernels := has(--allow-gpu-kernels) && has(--accept-bugcheck-risk)
- parents: native-firesim.mechanism.cuda-volume-step
- interventions: run validation without --accept-bugcheck-risk and assert safety-stop output is written, set FIRESIM_ACCEPT_BUGCHECK_RISK=1 and verify PowerShell runner accepts the risk gate, ensure diagnostics/input-stress paths remain available without GPU kernel launch
- abstractions: runtime-configuration, safety interlock, experiment gate
- evidence:
  - `source` scripts/verify.ps1:46 — verify.ps1 skips smoke and validation unless RunGpuKernels is set.
  - `source` scripts/verify.ps1:50 — verify.ps1 throws unless bugcheck risk is accepted for GPU kernel verification.
  - `source` scripts/run-nist-calibration.ps1:83 — NIST calibration runner blocks GPU validation unless bugcheck risk is accepted.
  - `source` src/main.cpp:1503 — writeGpuSafetyStop writes instructions for explicit GPU override.

### `native-firesim.presentation.d3d-ui-compositor`

- score: `70`
- type/status/confidence: `mechanism` / `inferred` / `0.82`
- state: The UI compositor copies the latest shared worker FP16 texture into the D3D display path and overlays operator UI/status.
- mechanism: swapchain_frame := compose(displaySimTexture(copy_worker_slot), uiTexture(status_overlay(settings, worker_status)))
- parents: native-firesim.contract.shared-viewport-buffer, native-firesim.contract.fire-settings
- interventions: feed a fixed worker texture slot and checksum displayed pixels, force no fresh worker frame and verify UI status renders no-live-CUDA-frame state, toggle clean viewport mode and verify overlay state changes without altering simulation frame
- abstractions: renderer-or-presentation, observation projection, operator UX
- evidence:
  - `source` src/main.cpp:1069 — copyD3DWorkerFrame imports and copies the worker frame.
  - `source` src/main.cpp:655 — UI drawing writes worker status text into the overlay.
  - `source` src/main.cpp:729 — UI status distinguishes CUDA 3D volume from worker-waiting state.
  - `source` src/main.cpp:3568 — Present is dirty when worker frame, overlay state, or no-live-frame state changes.

### `native-firesim.contract.fire-settings`

- score: `62`
- type/status/confidence: `constraint` / `observed` / `0.89`
- state: FireSettings is the control vector that maps UI inputs and worker settings into CUDA simulation and rendering parameters.
- mechanism: sim_params := clamp_and_copy(FireSettings, frame_dimensions, grid_dimensions, camera_basis)
- interventions: vary one FireSettings field and record which metrics or pixels change, set reset=1 and verify field reset path executes, clamp raymarchSteps above maximum and verify kernel uses bounded value
- abstractions: state-contract, control vector, intervention surface
- evidence:
  - `source` src/fire_cuda.h:52 — FireSettings defines dt, input state, wind, turbulence, camera, raymarch, ember, debug, and exposure controls.
  - `source` src/main.cpp:196 — sameFireSettings lists fields that define settings equality.
  - `source` src/main.cpp:3549 — Main loop writes worker settings without gizmos to the worker.

### `native-firesim.dataset.nist-fcd-methanol-r1`

- score: `58`
- type/status/confidence: `entity` / `verified` / `0.93`
- state: NIST_FCD_Methanol_1m_Pool_R1 provides the real-dataset calibration anchor for HRR, derived fuel mass, gas channels, radiant heat flux, and smoke extinction.
- mechanism: calibration_claim_scope := manifest(source, hashes, geometry, measurement_channels, derived_channels, target_envelopes)
- interventions: rerun verify-lab-grade.ps1 -RequireRealDataset after changing manifest or calibration CSV, change calibrationCsvSha256 and verify hash check fails, delete a declared measurement column and verify data coverage fails
- abstractions: initial-condition-generator, calibration dataset, ground-truth anchor
- evidence:
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json:3 — Manifest identifies experimentId and claim scope.
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json:33 — Manifest pins calibration and raw CSV SHA-256 hashes.
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/validation-targets.csv:4 — Target envelopes include calibration shape RMSE metrics.
  - `observation` out/lab-grade-readiness.json — Real dataset preflight passed with failCount=0 and warnCount=0.

### `native-firesim.mechanism.worker-lifecycle-watchdog`

- score: `55`
- type/status/confidence: `mechanism` / `observed` / `0.88`
- state: The UI process supervises the CUDA worker with heartbeat age, frame freshness, stale-kill, restart backoff, and visible status.
- mechanism: worker_status := f(process_alive, heartbeat_age, frame_age, restart_count, exit_code)
- parents: native-firesim.contract.shared-viewport-buffer
- interventions: kill worker process and verify worker-exited event plus restart behavior, freeze heartbeatTickMs and assert stale kill after kWorkerKillStaleMs, force repeated worker exits and verify restart cooldown after kWorkerRestartLimit
- abstractions: runtime-configuration, verification-surface, fault-containment mechanism
- evidence:
  - `source` src/main.cpp:55 — Worker stale-frame, heartbeat, kill, restart-window, and restart-limit constants are defined.
  - `source` src/main.cpp:1682 — appendRuntimeEvent writes out/worker-events.log.
  - `source` src/main.cpp:1825 — startCudaWorker creates the worker process with explicit CUDA-risk flags.
  - `source` src/main.cpp:1909 — serviceCudaWorkerWatchdog updates UI status and handles stale worker recovery.

### `native-firesim.verification.lab-grade-preflight`

- score: `45`
- type/status/confidence: `observation` / `verified` / `0.96`
- state: The lab-grade preflight currently verifies required docs, real dataset manifest, geometry, CSV coverage, channel metadata, hashes, and source fields with zero warnings.
- mechanism: preflight_ok := all(file_checks, manifest_checks, geometry_checks, csv_checks, hash_checks)
- parents: native-firesim.dataset.nist-fcd-methanol-r1
- interventions: rerun scripts/verify-lab-grade.ps1 -RequireRealDataset, remove a required dataset hash and confirm failCount increases, add an unbacked claimed channel and confirm coverage or metadata checks fail
- abstractions: verification-surface, evidence promotion gate, dataset integrity check
- evidence:
  - `command` powershell -ExecutionPolicy Bypass -File .\scripts\verify-lab-grade.ps1 -RequireRealDataset — Exited 0 with lab-grade preflight ok; warnings=0.
  - `observation` out/lab-grade-readiness.json — failCount=0, warnCount=0, direct measured channels with data=8, declared channels with data=10.
  - `source` scripts/verify-lab-grade.ps1:177 — Script parses manifest and emits structured checks.
  - `source` scripts/verify-lab-grade.ps1:248 — Script reads calibration CSV and validates channel coverage.

## Unknowns
Promote low-confidence or hypothesis frames only after inspecting the cited evidence or running an intervention/test.
