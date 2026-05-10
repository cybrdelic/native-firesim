# Mechanism Compilation Brief: C:\Users\alexf\Documents\Codex\2026-04-30\all-right-so-i-want-you\native-firesim

This is a semantic draft, not a verified causal model. Codex should inspect the cited source files, rewrite vague role claims into domain mechanisms, and only promote frames after tests/probes record evidence.

## Role Counts

- `verification-surface`: 19
- `runtime-configuration`: 5
- `transformation-mechanism`: 3
- `pipeline-orchestrator`: 2
- `state-contract`: 2
- `observation-operator`: 1
- `initial-condition-generator`: 1
- `renderer-or-presentation`: 1

## Top Files To Inspect

### initial-condition-generator
- `benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json` -> `native-firesim.dataset.nist-fcd-benchmark`
  - NIST FCD benchmark manifest anchors calibration claims with source, hashes, measurement channels, derived channels, and target envelopes
  - intervention: `rerun_lab_grade_preflight_after_manifest_or_csv_change`

### observation-operator
- `src/fire_cuda.cu` -> `native-firesim.operator.validation-metrics`
  - validation mode converts simulation frames into metrics, comparison CSVs, images, and a report
  - intervention: `run_validation_with_explicit_gpu_risk_and_inspect_report`

### pipeline-orchestrator
- `src/main.cpp` -> `native-firesim.pipeline.ui-to-worker-to-viewport`
  - interactive native viewport is a composed causal path from settings through isolated worker simulation, shared frame transport, and presentation
  - intervention: `run_default_app_and_inspect_worker_events_log`
- `scripts/run-nist-calibration.ps1` -> `native-firesim.mechanism.nist-calibration-runner`
  - calibration runner resolves a manifest into geometry, calibration CSV, target envelopes, output directory, and a risk-gated validation command
  - intervention: `run_calibration_runner_plan_only_and_inspect_plan`

### renderer-or-presentation
- `src/main.cpp` -> `native-firesim.presentation.d3d-ui-compositor`
  - presentation layer copies the latest shared worker texture into the display path and overlays operator UI or status
  - intervention: `feed_fixed_worker_texture_slot_and_checksum_displayed_pixels`

### runtime-configuration
- `CMakeLists.txt` -> `native-firesim.build.native-cuda-d3d11-target`
  - build configuration produces a native C++/CUDA executable with D3D or platform graphics linkage
  - intervention: `run_build_or_diagnostics_after_toolchain_change`
- `src/main.cpp` -> `native-firesim.mechanism.worker-lifecycle-watchdog`
  - host process supervises a worker with heartbeat age, frame freshness, stale kill, restart backoff, and visible status
  - intervention: `kill_worker_process_and_record_restart_or_status_event`
- `src/main.cpp` -> `native-firesim.constraint.gpu-kernel-risk-gate`
  - live GPU kernel paths are blocked unless explicit run and risk-acceptance flags are present
  - intervention: `run_validation_without_risk_flag_and_assert_safety_stop`
- `scripts/apply-gpu-recovery-settings.ps1` -> `semantic.runtime-configuration.scripts-apply-gpu-recovery-settings.ps1`
  - scripts/apply-gpu-recovery-settings.ps1 acts as a runtime-configuration: sets runtime, build, quality, or environment constraints
  - intervention: `toggle_one_configuration_value_and_run_smoke_check`
- `src/fire_cuda.cu` -> `semantic.runtime-configuration.src-fire_cuda.cu`
  - src/fire_cuda.cu acts as a runtime-configuration: sets runtime, build, quality, or environment constraints
  - intervention: `toggle_one_configuration_value_and_run_smoke_check`

### state-contract
- `src/fire_cuda.h` -> `native-firesim.contract.fire-settings`
  - settings struct acts as the control vector from UI or runner inputs into simulation and rendering
  - intervention: `vary_one_settings_field_and_record_metric_or_pixel_delta`
- `src/main.cpp` -> `native-firesim.contract.shared-viewport-buffer`
  - shared viewport buffer is the ABI between a producer process and a presentation process
  - intervention: `corrupt_shared_abi_version_and_verify_mapping_reset`

### transformation-mechanism
- `src/fire_cuda.cu` -> `native-firesim.mechanism.cuda-volume-step`
  - CUDA backend advances and renders a volume through advection, reaction, pressure projection, lighting, raymarching, and packing
  - intervention: `run_smoke_test_with_explicit_gpu_risk_and_compare_nonblank_frame`
- `src/fire_cuda.h` -> `semantic.transformation-mechanism.src-fire_cuda.h`
  - src/fire_cuda.h acts as a transformation-mechanism: transforms input state into updated state
  - intervention: `run_minimal_step_fixture_and_assert_state_delta`
- `src/main.cpp` -> `semantic.transformation-mechanism.src-main.cpp`
  - src/main.cpp acts as a transformation-mechanism: transforms input state into updated state
  - intervention: `run_minimal_step_fixture_and_assert_state_delta`

### verification-surface
- `scripts/run-nist-calibration.ps1` -> `native-firesim.verification.lab-grade-preflight`
  - lab-grade preflight validates required docs, dataset manifest, geometry, CSV coverage, channel metadata, hashes, and source fields
  - intervention: `run_verify_lab_grade_require_real_dataset_and_record_report`
- `src/main.cpp` -> `native-firesim.benchmark.completed-worker-frame`
  - worker benchmark measures completed GPU/D3D frames and writes a timing report rather than queue-submission timing
  - intervention: `run_worker_benchmark_with_explicit_gpu_risk_and_inspect_json`
- `README.md` -> `semantic.verification-surface.readme.md`
  - README.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
  - intervention: `run_the_named_test_or_probe_and_record_output`
- `benchmarks/README.md` -> `semantic.verification-surface.benchmarks-readme.md`
  - benchmarks/README.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
  - intervention: `run_the_named_test_or_probe_and_record_output`
- `benchmarks/nist-fcd/methanol-1m-pool-r1/README.md` -> `semantic.verification-surface.benchmarks-nist-fcd-methanol-1m-pool-r1-readme.md`
  - benchmarks/nist-fcd/methanol-1m-pool-r1/README.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
  - intervention: `run_the_named_test_or_probe_and_record_output`
- `benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json` -> `semantic.verification-surface.benchmarks-nist-fcd-methanol-1m-pool-r1-manifest.json`
  - benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
  - intervention: `run_the_named_test_or_probe_and_record_output`
- `docs/crash-analysis.md` -> `semantic.verification-surface.docs-crash-analysis.md`
  - docs/crash-analysis.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
  - intervention: `run_the_named_test_or_probe_and_record_output`
- `docs/fire-visual-gap-audit.md` -> `semantic.verification-surface.docs-fire-visual-gap-audit.md`
  - docs/fire-visual-gap-audit.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
  - intervention: `run_the_named_test_or_probe_and_record_output`
