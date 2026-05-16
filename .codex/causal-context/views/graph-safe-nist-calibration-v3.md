# Causal Graph View: What is the safest evidence path for NIST calibration without launching CUDA kernels?

`View(Q,S)=Expand(Retrieve(Q,S),budget,uncertainty)`

## Retrieval

- seeds: `semantic.verification-surface.scripts-run-nist-calibration.ps1`, `native-firesim.mechanism.nist-calibration-runner`, `semantic.transformation-mechanism.src-fire_cuda.h`
- direction/depth/budget: `both` / `2` / `18`
- expanded frames: `8`
- resolved edges: `8`

## Causal Edges

- `native-firesim.constraint.gpu-kernel-risk-gate` -> `native-firesim.mechanism.nist-calibration-runner`
- `native-firesim.dataset.nist-fcd-benchmark` -> `native-firesim.mechanism.nist-calibration-runner`
- `native-firesim.dataset.nist-fcd-benchmark` -> `native-firesim.operator.validation-metrics`
- `native-firesim.dataset.nist-fcd-benchmark` -> `native-firesim.verification.lab-grade-preflight`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.constraint.gpu-kernel-risk-gate`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.operator.validation-metrics`
- `native-firesim.operator.validation-metrics` -> `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.operator.validation-metrics` -> `native-firesim.mechanism.nist-calibration-runner`

## Expanded Frames

### `semantic.verification-surface.scripts-run-nist-calibration.ps1`

- distance/query-score: `0` / `57`
- type/status/confidence: `observation` / `inferred` / `0.74`
- state: scripts/run-nist-calibration.ps1 acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- evidence:
  - `source` scripts/run-nist-calibration.ps1 - Matched verification-surface signals: benchmark, test, validation

### `native-firesim.mechanism.nist-calibration-runner`

- distance/query-score: `0` / `53`
- type/status/confidence: `mechanism` / `observed` / `0.88`
- state: calibration runner resolves a manifest into geometry, calibration CSV, target envelopes, output directory, and a risk-gated validation command
- mechanism: calibration_run := verify_dataset(manifest) -> if risk_accepted then native_validation(...) else write_plan
- upstream parents: `native-firesim.constraint.gpu-kernel-risk-gate`, `native-firesim.dataset.nist-fcd-benchmark`, `native-firesim.operator.validation-metrics`
- interventions: run_calibration_runner_plan_only_and_inspect_plan, run_without_risk_acceptance_and_verify_gpu_validation_blocks, supply_missing_manifest_and_verify_resolution_fails_before_cuda
- evidence:
  - `source` scripts/run-nist-calibration.ps1 - Matched calibration runner: scripts/run-nist-calibration.ps1
  - `source` scripts/run-nist-calibration.ps1:56 - Matched preflight before run: & (Join-Path $PSScriptRoot "verify-lab-grade.ps1") `
  - `source` scripts/run-nist-calibration.ps1:6 - Matched plan without kernels: [switch]$RunGpuKernels,

### `semantic.transformation-mechanism.src-fire_cuda.h`

- distance/query-score: `0` / `47`
- type/status/confidence: `mechanism` / `inferred` / `0.66`
- state: src/fire_cuda.h acts as a transformation-mechanism: transforms input state into updated state
- mechanism: next_state := transform(previous_state, parameters, external_inputs)
- interventions: run_minimal_step_fixture_and_assert_state_delta, perturb_one_input_and_compare_predicted_downstream_change, trace_runtime_path_through_direct_consumers
- evidence:
  - `source` src/fire_cuda.h - Matched transformation-mechanism signals: step

### `native-firesim.dataset.nist-fcd-benchmark`

- distance/query-score: `1` / `37`
- type/status/confidence: `entity` / `observed` / `0.86`
- state: NIST FCD benchmark manifest anchors calibration claims with source, hashes, measurement channels, derived channels, and target envelopes
- mechanism: calibration_claim_scope := manifest(source, hashes, geometry, measurement_channels, derived_channels, target_envelopes)
- downstream children: `native-firesim.mechanism.nist-calibration-runner`, `native-firesim.operator.validation-metrics`, `native-firesim.verification.lab-grade-preflight`
- interventions: rerun_lab_grade_preflight_after_manifest_or_csv_change, change_declared_hash_and_verify_hash_check_fails, delete_declared_measurement_column_and_verify_data_coverage_fails
- evidence:
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json:3 - Matched NIST experiment identity: "experimentId":  "NIST_FCD_Methanol_1m_Pool_R1",
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json:32 - Matched dataset hashes: "geometrySha256":  "4d024b364e9aee63e5de9d63845809b1295172be6b2e1aa93bb51f6d3e676885",
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json:38 - Matched declared channels: "measurementChannels":  {

### `native-firesim.constraint.gpu-kernel-risk-gate`

- distance/query-score: `1` / `31`
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

### `native-firesim.operator.validation-metrics`

- distance/query-score: `1` / `20`
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

### `native-firesim.mechanism.cuda-volume-step`

- distance/query-score: `2` / `33`
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

### `native-firesim.verification.lab-grade-preflight`

- distance/query-score: `2` / `16`
- type/status/confidence: `observation` / `observed` / `0.87`
- state: lab-grade preflight validates required docs, dataset manifest, geometry, CSV coverage, channel metadata, hashes, and source fields
- mechanism: preflight_ok := all(file_checks, manifest_checks, geometry_checks, csv_checks, hash_checks)
- upstream parents: `native-firesim.dataset.nist-fcd-benchmark`
- interventions: run_verify_lab_grade_require_real_dataset_and_record_report, remove_required_dataset_hash_and_confirm_fail_count_increases, add_unbacked_claimed_channel_and_confirm_coverage_check_fails
- evidence:
  - `source` scripts/run-nist-calibration.ps1:56 - Matched preflight script: & (Join-Path $PSScriptRoot "verify-lab-grade.ps1") `
  - `source` scripts/verify-lab-grade.ps1:38 - Matched structured checks: function Add-Check {
  - `source` scripts/import-nist-fcd-methanol-r1.ps1:187 - Matched dataset coverage: $geometryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $geometryPath).Hash.ToLowerInvariant()
