# Intervention Plan: native FireSim CUDA worker shared viewport NIST calibration validation risk gate

These actions are designed to reduce uncertainty. Do not promote frames without recording the resulting observation.

## 1. `native-firesim.mechanism.nist-calibration-runner`

- status/confidence: `observed` / `0.88`
- state: calibration runner resolves a manifest into geometry, calibration CSV, target envelopes, output directory, and a risk-gated validation command
- mechanism: calibration_run := verify_dataset(manifest) -> if risk_accepted then native_validation(...) else write_plan
- discriminating question: Which stage boundary explains the final output when one stage is stubbed or disabled?
- intervention: `run_calibration_runner_plan_only_and_inspect_plan`
- risk class: `safe-local`
- observation to record: Record command/log/test/screenshot evidence tied to `scripts/run-nist-calibration.ps1`.

## 2. `native-firesim.pipeline.ui-to-worker-to-viewport`

- status/confidence: `inferred` / `0.85`
- state: interactive native viewport is a composed causal path from settings through isolated worker simulation, shared frame transport, and presentation
- mechanism: visible_frame := ui_present(copy(shared_texture(worker_render(step(settings)))))
- discriminating question: Which stage boundary explains the final output when one stage is stubbed or disabled?
- intervention: `run_default_app_and_inspect_worker_events_log`
- risk class: `manual-inspection`
- observation to record: Record command/log/test/screenshot evidence tied to `src/main.cpp`.

## 3. `native-firesim.contract.shared-viewport-buffer`

- status/confidence: `observed` / `0.9`
- state: shared viewport buffer is the ABI between a producer process and a presentation process
- mechanism: handoff_valid := magic/version/buildStamp/displayFormat match && frameSequence is stable_even && texture_slot is acquireable
- discriminating question: Which producer or consumer fails when the contract is intentionally violated?
- intervention: `corrupt_shared_abi_version_and_verify_mapping_reset`
- risk class: `fault-injection`
- observation to record: Record command/log/test/screenshot evidence tied to `src/main.cpp`.

## 4. `native-firesim.constraint.gpu-kernel-risk-gate`

- status/confidence: `observed` / `0.9`
- state: live GPU kernel paths are blocked unless explicit run and risk-acceptance flags are present
- mechanism: allow_gpu_kernels := has(--allow-gpu-kernels) && has(--accept-bugcheck-risk)
- discriminating question: If `native-firesim.mechanism.cuda-volume-step` is perturbed, does `live GPU kernel paths are blocked unless explicit run and risk-acceptance flags are present` change in the predicted direction?
- intervention: `run_validation_without_risk_flag_and_assert_safety_stop`
- risk class: `safe-local`
- observation to record: Record command/log/test/screenshot evidence tied to `src/main.cpp`.

## 5. `native-firesim.operator.validation-metrics`

- status/confidence: `observed` / `0.88`
- state: validation mode converts simulation frames into metrics, comparison CSVs, images, and a report
- mechanism: validation_artifacts := summarize(measured_step(settings), target_envelopes, calibration_sidecars)
- discriminating question: With raw state fixed, does changing only projection logic change the observable while solver state remains unchanged?
- intervention: `run_validation_with_explicit_gpu_risk_and_inspect_report`
- risk class: `gpu-risk`
- observation to record: Record command/log/test/screenshot evidence tied to `src/fire_cuda.cu`.

## 6. `native-firesim.presentation.d3d-ui-compositor`

- status/confidence: `inferred` / `0.82`
- state: presentation layer copies the latest shared worker texture into the display path and overlays operator UI or status
- mechanism: swapchain_frame := compose(display_texture(copy_worker_slot), ui_texture(status_overlay(settings, worker_status)))
- discriminating question: With observable state fixed, does this presentation surface produce stable pixels, DOM, or media?
- intervention: `feed_fixed_worker_texture_slot_and_checksum_displayed_pixels`
- risk class: `manual-inspection`
- observation to record: Record command/log/test/screenshot evidence tied to `src/main.cpp`.

## 7. `native-firesim.dataset.nist-fcd-benchmark`

- status/confidence: `observed` / `0.86`
- state: NIST FCD benchmark manifest anchors calibration claims with source, hashes, measurement channels, derived channels, and target envelopes
- mechanism: calibration_claim_scope := manifest(source, hashes, geometry, measurement_channels, derived_channels, target_envelopes)
- discriminating question: If one initial condition changes, do downstream observables change only through the predicted mechanism?
- intervention: `rerun_lab_grade_preflight_after_manifest_or_csv_change`
- risk class: `safe-local`
- observation to record: Record command/log/test/screenshot evidence tied to `benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json`.

## 8. `native-firesim.build.native-cuda-d3d11-target`

- status/confidence: `observed` / `0.86`
- state: build configuration produces a native C++/CUDA executable with D3D or platform graphics linkage
- mechanism: native_executable := build(cxx_sources, cuda_sources, gpu_architecture, platform_graphics_libraries)
- discriminating question: What observable result would falsify `build configuration produces a native C++/CUDA executable with D3D or platform graphics linkage`?
- intervention: `run_build_or_diagnostics_after_toolchain_change`
- risk class: `build-only`
- observation to record: Record command/log/test/screenshot evidence tied to `CMakeLists.txt`.

## 9. `native-firesim.mechanism.cuda-volume-step`

- status/confidence: `inferred` / `0.84`
- state: CUDA backend advances and renders a volume through advection, reaction, pressure projection, lighting, raymarching, and packing
- mechanism: frame_pixels, metrics := pack(raymarch(light(project(react(advect(fields, settings))))))
- discriminating question: Does a controlled input perturbation produce the predicted next-state delta?
- intervention: `run_smoke_test_with_explicit_gpu_risk_and_compare_nonblank_frame`
- risk class: `gpu-risk`
- observation to record: Record command/log/test/screenshot evidence tied to `src/fire_cuda.cu`.

## 10. `native-firesim.benchmark.completed-worker-frame`

- status/confidence: `observed` / `0.84`
- state: worker benchmark measures completed GPU/D3D frames and writes a timing report rather than queue-submission timing
- mechanism: worker_benchmark_report := time(completed_worker_frames) + sampled_gpu_breakdown
- discriminating question: If `native-firesim.mechanism.cuda-volume-step` is perturbed, does `worker benchmark measures completed GPU/D3D frames and writes a timing report rather than queue-submission timing` change in the predicted direction?
- intervention: `run_worker_benchmark_with_explicit_gpu_risk_and_inspect_json`
- risk class: `gpu-risk`
- observation to record: Record command/log/test/screenshot evidence tied to `src/main.cpp`.

## 11. `native-firesim.mechanism.worker-lifecycle-watchdog`

- status/confidence: `observed` / `0.86`
- state: host process supervises a worker with heartbeat age, frame freshness, stale kill, restart backoff, and visible status
- mechanism: worker_status := f(process_alive, heartbeat_age, frame_age, restart_count, exit_code)
- discriminating question: If `native-firesim.contract.shared-viewport-buffer` is perturbed, does `host process supervises a worker with heartbeat age, frame freshness, stale kill, restart backoff, and visible status` change in the predicted direction?
- intervention: `kill_worker_process_and_record_restart_or_status_event`
- risk class: `fault-injection`
- observation to record: Record command/log/test/screenshot evidence tied to `src/main.cpp`.

## 12. `semantic.verification-surface.scripts-run-nist-calibration.ps1`

- status/confidence: `inferred` / `0.74`
- state: scripts/run-nist-calibration.ps1 acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- discriminating question: What observable result would falsify `scripts/run-nist-calibration.ps1 acts as a verification-surface: can produce evidence about a mechanism under controlled conditions`?
- intervention: `run_probe_and_record_observation(scripts/run-nist-calibration.ps1)`
- risk class: `manual-inspection`
- observation to record: Record command/log/test/screenshot evidence tied to `scripts/run-nist-calibration.ps1`.
