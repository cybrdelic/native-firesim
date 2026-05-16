# Causal Context View: native FireSim CUDA worker shared viewport NIST calibration validation risk gate

## Operational Thesis
Relevant state centers on calibration runner resolves a manifest into geometry, calibration CSV, target envelopes, output directory, and a risk-gated validation command; interactive native viewport is a composed causal path from settings through isolated worker simulation, shared frame transport, and presentation; shared viewport buffer is the ABI between a producer process and a presentation process.

## Relevant Frames

### `native-firesim.mechanism.nist-calibration-runner`

- score: `74`
- type/status/confidence: `mechanism` / `observed` / `0.88`
- state: calibration runner resolves a manifest into geometry, calibration CSV, target envelopes, output directory, and a risk-gated validation command
- mechanism: calibration_run := verify_dataset(manifest) -> if risk_accepted then native_validation(...) else write_plan
- parents: native-firesim.dataset.nist-fcd-benchmark, native-firesim.operator.validation-metrics, native-firesim.constraint.gpu-kernel-risk-gate
- interventions: run_calibration_runner_plan_only_and_inspect_plan, run_without_risk_acceptance_and_verify_gpu_validation_blocks, supply_missing_manifest_and_verify_resolution_fails_before_cuda
- abstractions: pipeline-orchestrator, verification-surface, risk-gated experiment, pipeline-orchestrator
- evidence:
  - `source` scripts/run-nist-calibration.ps1 — Matched calibration runner: scripts/run-nist-calibration.ps1
  - `source` scripts/run-nist-calibration.ps1:56 — Matched preflight before run: & (Join-Path $PSScriptRoot "verify-lab-grade.ps1") `
  - `source` scripts/run-nist-calibration.ps1:6 — Matched plan without kernels: [switch]$RunGpuKernels,

### `native-firesim.pipeline.ui-to-worker-to-viewport`

- score: `71`
- type/status/confidence: `mechanism` / `inferred` / `0.85`
- state: interactive native viewport is a composed causal path from settings through isolated worker simulation, shared frame transport, and presentation
- mechanism: visible_frame := ui_present(copy(shared_texture(worker_render(step(settings)))))
- parents: native-firesim.contract.shared-viewport-buffer, native-firesim.mechanism.worker-lifecycle-watchdog, native-firesim.mechanism.cuda-volume-step, native-firesim.presentation.d3d-ui-compositor
- interventions: run_default_app_and_inspect_worker_events_log, disable_worker_and_verify_no_live_frame_state, simulate_stale_worker_and_verify_ui_survives_with_status
- abstractions: pipeline-orchestrator, crash-boundary, dynamic expansion target
- evidence:
  - `source` src/main.cpp:86 — Matched shared buffer struct: struct SharedViewportBuffer {
  - `source` src/main.cpp:1726 — Matched shared memory mapping: g_sharedViewportMap = CreateFileMappingA(
  - `source` src/main.cpp:1858 — Matched worker spawn: bool startCudaWorker() {
  - `source` src/main.cpp:56 — Matched watchdog timing: constexpr unsigned long long kWorkerFrameStaleMs = 2200ull;
  - `source` src/fire_cuda.cu:791 — Matched volume update kernel: __global__ void __launch_bounds__(kCudaBlockThreads, 1) advectUKernel(float* out, const float* inU, const float* inV, const float* inW, SimParams p) {

### `native-firesim.contract.shared-viewport-buffer`

- score: `53`
- type/status/confidence: `constraint` / `observed` / `0.9`
- state: shared viewport buffer is the ABI between a producer process and a presentation process
- mechanism: handoff_valid := magic/version/buildStamp/displayFormat match && frameSequence is stable_even && texture_slot is acquireable
- parents: native-firesim.build.native-cuda-d3d11-target
- interventions: corrupt_shared_abi_version_and_verify_mapping_reset, force_odd_frame_sequence_and_verify_frame_is_rejected, change_display_format_and_verify_handoff_contract_breaks
- abstractions: state-contract, shared-memory contract, worker boundary, state-contract
- evidence:
  - `source` src/main.cpp:86 — Matched shared buffer struct: struct SharedViewportBuffer {
  - `source` src/main.cpp:1726 — Matched shared memory mapping: g_sharedViewportMap = CreateFileMappingA(
  - `source` src/main.cpp:93 — Matched frame handoff fields: volatile LONG frameSequence;

### `native-firesim.constraint.gpu-kernel-risk-gate`

- score: `48`
- type/status/confidence: `constraint` / `observed` / `0.9`
- state: live GPU kernel paths are blocked unless explicit run and risk-acceptance flags are present
- mechanism: allow_gpu_kernels := has(--allow-gpu-kernels) && has(--accept-bugcheck-risk)
- parents: native-firesim.mechanism.cuda-volume-step
- interventions: run_validation_without_risk_flag_and_assert_safety_stop, set_risk_env_override_and_verify_runner_accepts_gate, ensure_diagnostics_path_remains_available_without_gpu_kernel_launch
- abstractions: runtime-configuration, safety interlock, experiment gate, runtime-configuration
- evidence:
  - `source` src/main.cpp:1529 — Matched risk flag: const bool explicitRiskAllow = args.find("--accept-bugcheck-risk") != std::string::npos;
  - `source` src/main.cpp:1524 — Matched GPU run flag: const bool explicitKernelAllow = args.find("--allow-gpu-kernels") != std::string::npos;
  - `source` src/main.cpp:1529 — Matched blocked path: const bool explicitRiskAllow = args.find("--accept-bugcheck-risk") != std::string::npos;

### `native-firesim.operator.validation-metrics`

- score: `45`
- type/status/confidence: `observation` / `observed` / `0.88`
- state: validation mode converts simulation frames into metrics, comparison CSVs, images, and a report
- mechanism: validation_artifacts := summarize(measured_step(settings), target_envelopes, calibration_sidecars)
- parents: native-firesim.mechanism.cuda-volume-step, native-firesim.dataset.nist-fcd-benchmark
- interventions: run_validation_with_explicit_gpu_risk_and_inspect_report, tighten_target_envelope_and_verify_validation_status_changes, remove_calibration_sidecar_and_verify_comparison_artifact_degrades
- abstractions: observation-operator, verification-surface, calibration bridge, observation-operator
- evidence:
  - `source` src/fire_cuda.cu:2533 — Matched metrics contract: bool stepAndRenderInternal(std::uint32_t* bgraPixels, const FireSettings& settings, FireCudaFrameMetrics* metrics, bool writeD3DInterop, bool advanceSimulation) {
  - `source` src/main.cpp:3072 — Matched validation entrypoint: int runValidation(const std::string& args) {
  - `source` src/main.cpp:3086 — Matched validation artifacts: const std::string metricsPath = joinPath(outputDir, "validation-metrics.csv");

### `native-firesim.dataset.nist-fcd-benchmark`

- score: `42`
- type/status/confidence: `entity` / `observed` / `0.86`
- state: NIST FCD benchmark manifest anchors calibration claims with source, hashes, measurement channels, derived channels, and target envelopes
- mechanism: calibration_claim_scope := manifest(source, hashes, geometry, measurement_channels, derived_channels, target_envelopes)
- interventions: rerun_lab_grade_preflight_after_manifest_or_csv_change, change_declared_hash_and_verify_hash_check_fails, delete_declared_measurement_column_and_verify_data_coverage_fails
- abstractions: initial-condition-generator, calibration dataset, ground-truth anchor, initial-condition-generator
- evidence:
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json:3 — Matched NIST experiment identity: "experimentId":  "NIST_FCD_Methanol_1m_Pool_R1",
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json:32 — Matched dataset hashes: "geometrySha256":  "4d024b364e9aee63e5de9d63845809b1295172be6b2e1aa93bb51f6d3e676885",
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json:38 — Matched declared channels: "measurementChannels":  {

### `native-firesim.presentation.d3d-ui-compositor`

- score: `42`
- type/status/confidence: `mechanism` / `inferred` / `0.82`
- state: presentation layer copies the latest shared worker texture into the display path and overlays operator UI or status
- mechanism: swapchain_frame := compose(display_texture(copy_worker_slot), ui_texture(status_overlay(settings, worker_status)))
- parents: native-firesim.contract.shared-viewport-buffer, native-firesim.contract.fire-settings
- interventions: feed_fixed_worker_texture_slot_and_checksum_displayed_pixels, force_no_fresh_worker_frame_and_verify_no-live-frame_status, toggle_clean_viewport_mode_and_verify_overlay_only_changes
- abstractions: renderer-or-presentation, observation projection, operator UX, renderer-or-presentation
- evidence:
  - `source` src/main.cpp:1088 — Matched worker frame copy: bool copyD3DWorkerFrame() {
  - `source` CMakeLists.txt:26 — Matched D3D presentation: target_link_libraries(NativeFireSim PRIVATE user32 winmm d3d11 dxgi d3dcompiler)
  - `source` src/fire_cuda.cu:2126 — Matched operator overlay: __global__ void __launch_bounds__(kCudaBlockThreads, 1) overlayKernel(

### `native-firesim.build.native-cuda-d3d11-target`

- score: `40`
- type/status/confidence: `constraint` / `observed` / `0.86`
- state: build configuration produces a native C++/CUDA executable with D3D or platform graphics linkage
- mechanism: native_executable := build(cxx_sources, cuda_sources, gpu_architecture, platform_graphics_libraries)
- interventions: run_build_or_diagnostics_after_toolchain_change, change_gpu_architecture_and_verify_build_contract, remove_graphics_link_and_confirm_linker_or_startup_failure
- abstractions: runtime-configuration, build contract, platform constraint, runtime-configuration
- evidence:
  - `source` CMakeLists.txt — Matched native CMake target: CMakeLists.txt
  - `source` CMakeLists.txt:7 — Matched CUDA architecture: set(CMAKE_CUDA_STANDARD 17)
  - `source` CMakeLists.txt:26 — Matched graphics linkage: target_link_libraries(NativeFireSim PRIVATE user32 winmm d3d11 dxgi d3dcompiler)

### `native-firesim.benchmark.completed-worker-frame`

- score: `39`
- type/status/confidence: `observation` / `observed` / `0.84`
- state: worker benchmark measures completed GPU/D3D frames and writes a timing report rather than queue-submission timing
- mechanism: worker_benchmark_report := time(completed_worker_frames) + sampled_gpu_breakdown
- parents: native-firesim.mechanism.cuda-volume-step, native-firesim.presentation.d3d-ui-compositor
- interventions: run_worker_benchmark_with_explicit_gpu_risk_and_inspect_json, compare_benchmark_before_after_raymarch_step_change, assert_report_timing_mode_is_completed_frame_timing
- abstractions: verification-surface, performance probe, intervention measurement, verification-surface
- evidence:
  - `source` src/main.cpp:2097 — Matched benchmark entrypoint: int runWorkerBenchmark(const std::string& args) {
  - `source` src/main.cpp:2124 — Matched benchmark artifact: const std::string reportPath = joinPath(outputDir, "worker-benchmark.json");
  - `source` src/main.cpp:2273 — Matched completed-frame timing: report << "  \"timingMode\": \"live frames timed without metrics; GPU breakdown sampled after live timing\",\n";

### `native-firesim.mechanism.cuda-volume-step`

- score: `39`
- type/status/confidence: `mechanism` / `inferred` / `0.84`
- state: CUDA backend advances and renders a volume through advection, reaction, pressure projection, lighting, raymarching, and packing
- mechanism: frame_pixels, metrics := pack(raymarch(light(project(react(advect(fields, settings))))))
- parents: native-firesim.contract.fire-settings, native-firesim.operator.validation-metrics
- interventions: run_smoke_test_with_explicit_gpu_risk_and_compare_nonblank_frame, reduce_pressure_iterations_and_verify_divergence_metrics_worsen, toggle_render_debug_mode_and_record_metric_or_pixel_change
- abstractions: transformation-mechanism, physics state transition, renderer pipeline, transformation-mechanism
- evidence:
  - `source` src/fire_cuda.cu:791 — Matched volume update kernel: __global__ void __launch_bounds__(kCudaBlockThreads, 1) advectUKernel(float* out, const float* inU, const float* inV, const float* inW, SimParams p) {
  - `source` src/fire_cuda.cu:1089 — Matched pressure projection: __global__ void __launch_bounds__(kCudaBlockThreads, 1) divergenceKernel(float* divergence, float* pressure, const float* uField, const float* vField, const float* wField, SimParam
  - `source` src/fire_cuda.cu:48 — Matched volume renderer: int raymarchSteps;
  - `source` src/fire_cuda.cu:2533 — Matched measured step API: bool stepAndRenderInternal(std::uint32_t* bgraPixels, const FireSettings& settings, FireCudaFrameMetrics* metrics, bool writeD3DInterop, bool advanceSimulation) {

### `native-firesim.mechanism.worker-lifecycle-watchdog`

- score: `39`
- type/status/confidence: `mechanism` / `observed` / `0.86`
- state: host process supervises a worker with heartbeat age, frame freshness, stale kill, restart backoff, and visible status
- mechanism: worker_status := f(process_alive, heartbeat_age, frame_age, restart_count, exit_code)
- parents: native-firesim.contract.shared-viewport-buffer
- interventions: kill_worker_process_and_record_restart_or_status_event, freeze_worker_heartbeat_and_verify_stale_kill, force_repeated_worker_exits_and_verify_restart_cooldown
- abstractions: runtime-configuration, verification-surface, fault-containment mechanism, runtime-configuration
- evidence:
  - `source` src/main.cpp:1858 — Matched worker spawn: bool startCudaWorker() {
  - `source` src/main.cpp:56 — Matched watchdog timing: constexpr unsigned long long kWorkerFrameStaleMs = 2200ull;
  - `source` src/main.cpp:1713 — Matched runtime events: void appendRuntimeEvent(const char* event, const char* detail = "") {

### `semantic.verification-surface.scripts-run-nist-calibration.ps1`

- score: `31`
- type/status/confidence: `observation` / `inferred` / `0.74`
- state: scripts/run-nist-calibration.ps1 acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` scripts/run-nist-calibration.ps1 — Matched verification-surface signals: benchmark, test, validation

### `native-firesim.verification.lab-grade-preflight`

- score: `26`
- type/status/confidence: `observation` / `observed` / `0.87`
- state: lab-grade preflight validates required docs, dataset manifest, geometry, CSV coverage, channel metadata, hashes, and source fields
- mechanism: preflight_ok := all(file_checks, manifest_checks, geometry_checks, csv_checks, hash_checks)
- parents: native-firesim.dataset.nist-fcd-benchmark
- interventions: run_verify_lab_grade_require_real_dataset_and_record_report, remove_required_dataset_hash_and_confirm_fail_count_increases, add_unbacked_claimed_channel_and_confirm_coverage_check_fails
- abstractions: verification-surface, evidence promotion gate, dataset integrity check, verification-surface
- evidence:
  - `source` scripts/run-nist-calibration.ps1:56 — Matched preflight script: & (Join-Path $PSScriptRoot "verify-lab-grade.ps1") `
  - `source` scripts/verify-lab-grade.ps1:38 — Matched structured checks: function Add-Check {
  - `source` scripts/import-nist-fcd-methanol-r1.ps1:187 — Matched dataset coverage: $geometryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $geometryPath).Hash.ToLowerInvariant()

### `native-firesim.contract.fire-settings`

- score: `24`
- type/status/confidence: `constraint` / `observed` / `0.88`
- state: settings struct acts as the control vector from UI or runner inputs into simulation and rendering
- mechanism: sim_params := clamp_and_copy(settings, frame_dimensions, grid_dimensions, camera_basis)
- interventions: vary_one_settings_field_and_record_metric_or_pixel_delta, set_reset_flag_and_verify_field_reset_path, clamp_render_setting_above_limit_and_verify_bounded_behavior
- abstractions: state-contract, control vector, intervention surface, state-contract
- evidence:
  - `source` src/fire_cuda.h:60 — Matched settings contract: struct FireSettings {
  - `source` src/fire_cuda.cu:34 — Matched render controls: float turbulence;
  - `source` src/fire_cuda.cu:2533 — Matched settings consumer: bool stepAndRenderInternal(std::uint32_t* bgraPixels, const FireSettings& settings, FireCudaFrameMetrics* metrics, bool writeD3DInterop, bool advanceSimulation) {

### `semantic.verification-surface.benchmarks-nist-fcd-methanol-1m-pool-r1-manifest.json`

- score: `17`
- type/status/confidence: `observation` / `inferred` / `0.7999999999999999`
- state: benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json — Matched verification-surface signals: benchmark, path:verification-surface, validation

### `semantic.verification-surface.launch-firesim.ps1`

- score: `17`
- type/status/confidence: `observation` / `inferred` / `0.74`
- state: launch-firesim.ps1 acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` launch-firesim.ps1 — Matched verification-surface signals: smoke, test, validation

## Unknowns
Promote low-confidence or hypothesis frames only after inspecting the cited evidence or running an intervention/test.
