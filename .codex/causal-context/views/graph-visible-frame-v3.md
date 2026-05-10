# Causal Graph View: How does native FireSim produce a visible frame from settings to viewport?

`View(Q,S)=Expand(Retrieve(Q,S),budget,uncertainty)`

## Retrieval

- seeds: `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.contract.fire-settings`, `native-firesim.contract.shared-viewport-buffer`
- direction/depth/budget: `both` / `2` / `18`
- expanded frames: `10`
- resolved edges: `14`

## Causal Edges

- `native-firesim.build.native-cuda-d3d11-target` -> `native-firesim.contract.shared-viewport-buffer`
- `native-firesim.contract.fire-settings` -> `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.contract.fire-settings` -> `native-firesim.presentation.d3d-ui-compositor`
- `native-firesim.contract.shared-viewport-buffer` -> `native-firesim.mechanism.worker-lifecycle-watchdog`
- `native-firesim.contract.shared-viewport-buffer` -> `native-firesim.pipeline.ui-to-worker-to-viewport`
- `native-firesim.contract.shared-viewport-buffer` -> `native-firesim.presentation.d3d-ui-compositor`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.benchmark.completed-worker-frame`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.constraint.gpu-kernel-risk-gate`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.operator.validation-metrics`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.pipeline.ui-to-worker-to-viewport`
- `native-firesim.mechanism.worker-lifecycle-watchdog` -> `native-firesim.pipeline.ui-to-worker-to-viewport`
- `native-firesim.operator.validation-metrics` -> `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.presentation.d3d-ui-compositor` -> `native-firesim.benchmark.completed-worker-frame`
- `native-firesim.presentation.d3d-ui-compositor` -> `native-firesim.pipeline.ui-to-worker-to-viewport`

## Expanded Frames

### `native-firesim.pipeline.ui-to-worker-to-viewport`

- distance/query-score: `0` / `88`
- type/status/confidence: `mechanism` / `inferred` / `0.85`
- state: interactive native viewport is a composed causal path from settings through isolated worker simulation, shared frame transport, and presentation
- mechanism: visible_frame := ui_present(copy(shared_texture(worker_render(step(settings)))))
- upstream parents: `native-firesim.contract.shared-viewport-buffer`, `native-firesim.mechanism.cuda-volume-step`, `native-firesim.mechanism.worker-lifecycle-watchdog`, `native-firesim.presentation.d3d-ui-compositor`
- interventions: run_default_app_and_inspect_worker_events_log, disable_worker_and_verify_no_live_frame_state, simulate_stale_worker_and_verify_ui_survives_with_status
- evidence:
  - `source` src/main.cpp:86 - Matched shared buffer struct: struct SharedViewportBuffer {
  - `source` src/main.cpp:1726 - Matched shared memory mapping: g_sharedViewportMap = CreateFileMappingA(
  - `source` src/main.cpp:1858 - Matched worker spawn: bool startCudaWorker() {

### `native-firesim.contract.fire-settings`

- distance/query-score: `0` / `65`
- type/status/confidence: `constraint` / `observed` / `0.88`
- state: settings struct acts as the control vector from UI or runner inputs into simulation and rendering
- mechanism: sim_params := clamp_and_copy(settings, frame_dimensions, grid_dimensions, camera_basis)
- downstream children: `native-firesim.mechanism.cuda-volume-step`, `native-firesim.presentation.d3d-ui-compositor`
- interventions: vary_one_settings_field_and_record_metric_or_pixel_delta, set_reset_flag_and_verify_field_reset_path, clamp_render_setting_above_limit_and_verify_bounded_behavior
- evidence:
  - `source` src/fire_cuda.h:60 - Matched settings contract: struct FireSettings {
  - `source` src/fire_cuda.cu:34 - Matched render controls: float turbulence;
  - `source` src/fire_cuda.cu:2533 - Matched settings consumer: bool stepAndRenderInternal(std::uint32_t* bgraPixels, const FireSettings& settings, FireCudaFrameMetrics* metrics, bool writeD3DInterop, bool advanceSimulation) {

### `native-firesim.contract.shared-viewport-buffer`

- distance/query-score: `0` / `61`
- type/status/confidence: `constraint` / `observed` / `0.9`
- state: shared viewport buffer is the ABI between a producer process and a presentation process
- mechanism: handoff_valid := magic/version/buildStamp/displayFormat match && frameSequence is stable_even && texture_slot is acquireable
- upstream parents: `native-firesim.build.native-cuda-d3d11-target`
- downstream children: `native-firesim.mechanism.worker-lifecycle-watchdog`, `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.presentation.d3d-ui-compositor`
- interventions: corrupt_shared_abi_version_and_verify_mapping_reset, force_odd_frame_sequence_and_verify_frame_is_rejected, change_display_format_and_verify_handoff_contract_breaks
- evidence:
  - `source` src/main.cpp:86 - Matched shared buffer struct: struct SharedViewportBuffer {
  - `source` src/main.cpp:1726 - Matched shared memory mapping: g_sharedViewportMap = CreateFileMappingA(
  - `source` src/main.cpp:93 - Matched frame handoff fields: volatile LONG frameSequence;

### `native-firesim.presentation.d3d-ui-compositor`

- distance/query-score: `1` / `61`
- type/status/confidence: `mechanism` / `inferred` / `0.82`
- state: presentation layer copies the latest shared worker texture into the display path and overlays operator UI or status
- mechanism: swapchain_frame := compose(display_texture(copy_worker_slot), ui_texture(status_overlay(settings, worker_status)))
- upstream parents: `native-firesim.contract.fire-settings`, `native-firesim.contract.shared-viewport-buffer`
- downstream children: `native-firesim.benchmark.completed-worker-frame`, `native-firesim.pipeline.ui-to-worker-to-viewport`
- interventions: feed_fixed_worker_texture_slot_and_checksum_displayed_pixels, force_no_fresh_worker_frame_and_verify_no-live-frame_status, toggle_clean_viewport_mode_and_verify_overlay_only_changes
- evidence:
  - `source` src/main.cpp:1088 - Matched worker frame copy: bool copyD3DWorkerFrame() {
  - `source` CMakeLists.txt:26 - Matched D3D presentation: target_link_libraries(NativeFireSim PRIVATE user32 winmm d3d11 dxgi d3dcompiler)
  - `source` src/fire_cuda.cu:2126 - Matched operator overlay: __global__ void __launch_bounds__(kCudaBlockThreads, 1) overlayKernel(

### `native-firesim.mechanism.worker-lifecycle-watchdog`

- distance/query-score: `1` / `49`
- type/status/confidence: `mechanism` / `observed` / `0.86`
- state: host process supervises a worker with heartbeat age, frame freshness, stale kill, restart backoff, and visible status
- mechanism: worker_status := f(process_alive, heartbeat_age, frame_age, restart_count, exit_code)
- upstream parents: `native-firesim.contract.shared-viewport-buffer`
- downstream children: `native-firesim.pipeline.ui-to-worker-to-viewport`
- interventions: kill_worker_process_and_record_restart_or_status_event, freeze_worker_heartbeat_and_verify_stale_kill, force_repeated_worker_exits_and_verify_restart_cooldown
- evidence:
  - `source` src/main.cpp:1858 - Matched worker spawn: bool startCudaWorker() {
  - `source` src/main.cpp:56 - Matched watchdog timing: constexpr unsigned long long kWorkerFrameStaleMs = 2200ull;
  - `source` src/main.cpp:1713 - Matched runtime events: void appendRuntimeEvent(const char* event, const char* detail = "") {

### `native-firesim.build.native-cuda-d3d11-target`

- distance/query-score: `1` / `46`
- type/status/confidence: `constraint` / `observed` / `0.86`
- state: build configuration produces a native C++/CUDA executable with D3D or platform graphics linkage
- mechanism: native_executable := build(cxx_sources, cuda_sources, gpu_architecture, platform_graphics_libraries)
- downstream children: `native-firesim.contract.shared-viewport-buffer`
- interventions: run_build_or_diagnostics_after_toolchain_change, change_gpu_architecture_and_verify_build_contract, remove_graphics_link_and_confirm_linker_or_startup_failure
- evidence:
  - `source` CMakeLists.txt - Matched native CMake target: CMakeLists.txt
  - `source` CMakeLists.txt:7 - Matched CUDA architecture: set(CMAKE_CUDA_STANDARD 17)
  - `source` CMakeLists.txt:26 - Matched graphics linkage: target_link_libraries(NativeFireSim PRIVATE user32 winmm d3d11 dxgi d3dcompiler)

### `native-firesim.mechanism.cuda-volume-step`

- distance/query-score: `1` / `46`
- type/status/confidence: `mechanism` / `inferred` / `0.84`
- state: CUDA backend advances and renders a volume through advection, reaction, pressure projection, lighting, raymarching, and packing
- mechanism: frame_pixels, metrics := pack(raymarch(light(project(react(advect(fields, settings))))))
- upstream parents: `native-firesim.contract.fire-settings`, `native-firesim.operator.validation-metrics`
- downstream children: `native-firesim.benchmark.completed-worker-frame`, `native-firesim.constraint.gpu-kernel-risk-gate`, `native-firesim.operator.validation-metrics`, `native-firesim.pipeline.ui-to-worker-to-viewport`
- interventions: run_smoke_test_with_explicit_gpu_risk_and_compare_nonblank_frame, reduce_pressure_iterations_and_verify_divergence_metrics_worsen, toggle_render_debug_mode_and_record_metric_or_pixel_change
- evidence:
  - `source` src/fire_cuda.cu:791 - Matched volume update kernel: __global__ void __launch_bounds__(kCudaBlockThreads, 1) advectUKernel(float* out, const float* inU, const float* inV, const float* inW, SimParams p) {
  - `source` src/fire_cuda.cu:1089 - Matched pressure projection: __global__ void __launch_bounds__(kCudaBlockThreads, 1) divergenceKernel(float* divergence, float* pressure, const float* uField, const float* vField, const float* wField, SimParam
  - `source` src/fire_cuda.cu:48 - Matched volume renderer: int raymarchSteps;

### `native-firesim.operator.validation-metrics`

- distance/query-score: `2` / `61`
- type/status/confidence: `observation` / `observed` / `0.88`
- state: validation mode converts simulation frames into metrics, comparison CSVs, images, and a report
- mechanism: validation_artifacts := summarize(measured_step(settings), target_envelopes, calibration_sidecars)
- upstream parents: `native-firesim.dataset.nist-fcd-benchmark`, `native-firesim.mechanism.cuda-volume-step`
- downstream children: `native-firesim.mechanism.cuda-volume-step`, `native-firesim.mechanism.nist-calibration-runner`
- interventions: run_validation_with_explicit_gpu_risk_and_inspect_report, tighten_target_envelope_and_verify_validation_status_changes, remove_calibration_sidecar_and_verify_comparison_artifact_degrades
- evidence:
  - `source` src/fire_cuda.cu:2533 - Matched metrics contract: bool stepAndRenderInternal(std::uint32_t* bgraPixels, const FireSettings& settings, FireCudaFrameMetrics* metrics, bool writeD3DInterop, bool advanceSimulation) {
  - `source` src/main.cpp:3072 - Matched validation entrypoint: int runValidation(const std::string& args) {
  - `source` src/main.cpp:3086 - Matched validation artifacts: const std::string metricsPath = joinPath(outputDir, "validation-metrics.csv");

### `native-firesim.benchmark.completed-worker-frame`

- distance/query-score: `2` / `52`
- type/status/confidence: `observation` / `observed` / `0.84`
- state: worker benchmark measures completed GPU/D3D frames and writes a timing report rather than queue-submission timing
- mechanism: worker_benchmark_report := time(completed_worker_frames) + sampled_gpu_breakdown
- upstream parents: `native-firesim.mechanism.cuda-volume-step`, `native-firesim.presentation.d3d-ui-compositor`
- interventions: run_worker_benchmark_with_explicit_gpu_risk_and_inspect_json, compare_benchmark_before_after_raymarch_step_change, assert_report_timing_mode_is_completed_frame_timing
- evidence:
  - `source` src/main.cpp:2097 - Matched benchmark entrypoint: int runWorkerBenchmark(const std::string& args) {
  - `source` src/main.cpp:2124 - Matched benchmark artifact: const std::string reportPath = joinPath(outputDir, "worker-benchmark.json");
  - `source` src/main.cpp:2273 - Matched completed-frame timing: report << "  \"timingMode\": \"live frames timed without metrics; GPU breakdown sampled after live timing\",\n";

### `native-firesim.constraint.gpu-kernel-risk-gate`

- distance/query-score: `2` / `37`
- type/status/confidence: `constraint` / `observed` / `0.9`
- state: live GPU kernel paths are blocked unless explicit run and risk-acceptance flags are present
- mechanism: allow_gpu_kernels := has(--allow-gpu-kernels) && has(--accept-bugcheck-risk)
- upstream parents: `native-firesim.mechanism.cuda-volume-step`
- downstream children: `native-firesim.mechanism.nist-calibration-runner`
- interventions: run_validation_without_risk_flag_and_assert_safety_stop, set_risk_env_override_and_verify_runner_accepts_gate, ensure_diagnostics_path_remains_available_without_gpu_kernel_launch
- evidence:
  - `source` src/main.cpp:1529 - Matched risk flag: const bool explicitRiskAllow = args.find("--accept-bugcheck-risk") != std::string::npos;
  - `source` src/main.cpp:1524 - Matched GPU run flag: const bool explicitKernelAllow = args.find("--allow-gpu-kernels") != std::string::npos;
  - `source` src/main.cpp:1529 - Matched blocked path: const bool explicitRiskAllow = args.find("--accept-bugcheck-risk") != std::string::npos;
