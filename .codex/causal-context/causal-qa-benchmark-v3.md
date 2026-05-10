# Causal QA Benchmark

- questions: `4`
- seed-limit/depth/budget/direction: `3` / `2` / `18` / `both`
- graph expected-frame recall: `1.0`
- ranked expected-frame recall: `0.875`

## `q1_shared_viewport_impact`

What changes if the shared viewport buffer contract changes?

- expected: `native-firesim.contract.shared-viewport-buffer`, `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.presentation.d3d-ui-compositor`, `native-firesim.mechanism.worker-lifecycle-watchdog`
- seeds: `native-firesim.contract.shared-viewport-buffer`, `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.contract.fire-settings`
- graph recall: `1.0`
- ranked recall: `0.75`
- graph hits: `native-firesim.contract.shared-viewport-buffer`, `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.presentation.d3d-ui-compositor`, `native-firesim.mechanism.worker-lifecycle-watchdog`
- ranked hits: `native-firesim.contract.shared-viewport-buffer`, `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.presentation.d3d-ui-compositor`

### Graph Expansion

- `native-firesim.contract.shared-viewport-buffer`
- `native-firesim.pipeline.ui-to-worker-to-viewport`
- `native-firesim.contract.fire-settings`
- `native-firesim.presentation.d3d-ui-compositor`
- `native-firesim.mechanism.worker-lifecycle-watchdog`
- `native-firesim.build.native-cuda-d3d11-target`
- `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.benchmark.completed-worker-frame`
- `native-firesim.operator.validation-metrics`
- `native-firesim.constraint.gpu-kernel-risk-gate`

### Graph Edges

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

### Ranked Retrieval

- `native-firesim.contract.shared-viewport-buffer`
- `native-firesim.pipeline.ui-to-worker-to-viewport`
- `native-firesim.contract.fire-settings`
- `native-firesim.presentation.d3d-ui-compositor`
- `semantic.verification-surface.benchmarks-nist-fcd-methanol-1m-pool-r1-manifest.json`
- `semantic.verification-surface.benchmarks-nist-fcd-methanol-1m-pool-r1-readme.md`
- `semantic.verification-surface.benchmarks-readme.md`
- `semantic.verification-surface.docs-crash-analysis.md`
- `semantic.verification-surface.docs-fire-visual-gap-audit.md`
- `semantic.verification-surface.docs-gpu-engineering.md`
- `semantic.verification-surface.docs-infrastructure-hardening-plan.md`
- `semantic.verification-surface.docs-lab-grade-roadmap.md`

## `q2_safe_nist_calibration`

What is the safest evidence path for NIST calibration without launching CUDA kernels?

- expected: `native-firesim.mechanism.nist-calibration-runner`, `native-firesim.constraint.gpu-kernel-risk-gate`, `native-firesim.verification.lab-grade-preflight`, `native-firesim.dataset.nist-fcd-benchmark`
- seeds: `semantic.verification-surface.scripts-run-nist-calibration.ps1`, `native-firesim.mechanism.nist-calibration-runner`, `semantic.transformation-mechanism.src-fire_cuda.h`
- graph recall: `1.0`
- ranked recall: `0.75`
- graph hits: `native-firesim.mechanism.nist-calibration-runner`, `native-firesim.constraint.gpu-kernel-risk-gate`, `native-firesim.verification.lab-grade-preflight`, `native-firesim.dataset.nist-fcd-benchmark`
- ranked hits: `native-firesim.mechanism.nist-calibration-runner`, `native-firesim.constraint.gpu-kernel-risk-gate`, `native-firesim.dataset.nist-fcd-benchmark`

### Graph Expansion

- `semantic.verification-surface.scripts-run-nist-calibration.ps1`
- `native-firesim.mechanism.nist-calibration-runner`
- `semantic.transformation-mechanism.src-fire_cuda.h`
- `native-firesim.dataset.nist-fcd-benchmark`
- `native-firesim.constraint.gpu-kernel-risk-gate`
- `native-firesim.operator.validation-metrics`
- `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.verification.lab-grade-preflight`

### Graph Edges

- `native-firesim.constraint.gpu-kernel-risk-gate` -> `native-firesim.mechanism.nist-calibration-runner`
- `native-firesim.dataset.nist-fcd-benchmark` -> `native-firesim.mechanism.nist-calibration-runner`
- `native-firesim.dataset.nist-fcd-benchmark` -> `native-firesim.operator.validation-metrics`
- `native-firesim.dataset.nist-fcd-benchmark` -> `native-firesim.verification.lab-grade-preflight`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.constraint.gpu-kernel-risk-gate`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.operator.validation-metrics`
- `native-firesim.operator.validation-metrics` -> `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.operator.validation-metrics` -> `native-firesim.mechanism.nist-calibration-runner`

### Ranked Retrieval

- `semantic.verification-surface.scripts-run-nist-calibration.ps1`
- `native-firesim.mechanism.nist-calibration-runner`
- `semantic.transformation-mechanism.src-fire_cuda.h`
- `semantic.verification-surface.benchmarks-nist-fcd-methanol-1m-pool-r1-manifest.json`
- `semantic.verification-surface.benchmarks-nist-fcd-methanol-1m-pool-r1-readme.md`
- `semantic.verification-surface.scripts-import-nist-fcd-methanol-r1.ps1`
- `native-firesim.dataset.nist-fcd-benchmark`
- `semantic.verification-surface.docs-performance-bug-audit.md`
- `native-firesim.mechanism.cuda-volume-step`
- `semantic.transformation-mechanism.src-main.cpp`
- `native-firesim.constraint.gpu-kernel-risk-gate`
- `native-firesim.build.native-cuda-d3d11-target`

## `q3_cuda_volume_validation`

What does the CUDA volume step depend on and what verifies it?

- expected: `native-firesim.mechanism.cuda-volume-step`, `native-firesim.contract.fire-settings`, `native-firesim.operator.validation-metrics`
- seeds: `native-firesim.mechanism.cuda-volume-step`, `native-firesim.presentation.d3d-ui-compositor`, `semantic.runtime-configuration.src-fire_cuda.cu`
- graph recall: `1.0`
- ranked recall: `1.0`
- graph hits: `native-firesim.mechanism.cuda-volume-step`, `native-firesim.contract.fire-settings`, `native-firesim.operator.validation-metrics`
- ranked hits: `native-firesim.mechanism.cuda-volume-step`, `native-firesim.contract.fire-settings`, `native-firesim.operator.validation-metrics`

### Graph Expansion

- `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.presentation.d3d-ui-compositor`
- `semantic.runtime-configuration.src-fire_cuda.cu`
- `native-firesim.operator.validation-metrics`
- `native-firesim.contract.fire-settings`
- `native-firesim.benchmark.completed-worker-frame`
- `native-firesim.constraint.gpu-kernel-risk-gate`
- `native-firesim.contract.shared-viewport-buffer`
- `native-firesim.pipeline.ui-to-worker-to-viewport`
- `native-firesim.build.native-cuda-d3d11-target`
- `native-firesim.mechanism.nist-calibration-runner`
- `native-firesim.dataset.nist-fcd-benchmark`

### Graph Edges

- `native-firesim.build.native-cuda-d3d11-target` -> `native-firesim.contract.shared-viewport-buffer`
- `native-firesim.constraint.gpu-kernel-risk-gate` -> `native-firesim.mechanism.nist-calibration-runner`
- `native-firesim.contract.fire-settings` -> `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.contract.fire-settings` -> `native-firesim.presentation.d3d-ui-compositor`
- `native-firesim.contract.shared-viewport-buffer` -> `native-firesim.mechanism.worker-lifecycle-watchdog`
- `native-firesim.contract.shared-viewport-buffer` -> `native-firesim.pipeline.ui-to-worker-to-viewport`
- `native-firesim.contract.shared-viewport-buffer` -> `native-firesim.presentation.d3d-ui-compositor`
- `native-firesim.dataset.nist-fcd-benchmark` -> `native-firesim.mechanism.nist-calibration-runner`
- `native-firesim.dataset.nist-fcd-benchmark` -> `native-firesim.operator.validation-metrics`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.benchmark.completed-worker-frame`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.constraint.gpu-kernel-risk-gate`
- `native-firesim.mechanism.cuda-volume-step` -> `native-firesim.operator.validation-metrics`

### Ranked Retrieval

- `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.presentation.d3d-ui-compositor`
- `semantic.runtime-configuration.src-fire_cuda.cu`
- `native-firesim.build.native-cuda-d3d11-target`
- `native-firesim.operator.validation-metrics`
- `native-firesim.contract.fire-settings`
- `semantic.transformation-mechanism.src-fire_cuda.h`
- `semantic.verification-surface.docs-fire-visual-gap-audit.md`
- `semantic.verification-surface.docs-performance-bug-audit.md`
- `semantic.verification-surface.docs-physics-architecture.md`
- `native-firesim.benchmark.completed-worker-frame`
- `native-firesim.constraint.gpu-kernel-risk-gate`

## `q4_visible_frame_path`

How does native FireSim produce a visible frame from settings to viewport?

- expected: `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.contract.fire-settings`, `native-firesim.mechanism.cuda-volume-step`, `native-firesim.contract.shared-viewport-buffer`, `native-firesim.presentation.d3d-ui-compositor`
- seeds: `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.contract.fire-settings`, `native-firesim.contract.shared-viewport-buffer`
- graph recall: `1.0`
- ranked recall: `1.0`
- graph hits: `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.contract.fire-settings`, `native-firesim.mechanism.cuda-volume-step`, `native-firesim.contract.shared-viewport-buffer`, `native-firesim.presentation.d3d-ui-compositor`
- ranked hits: `native-firesim.pipeline.ui-to-worker-to-viewport`, `native-firesim.contract.fire-settings`, `native-firesim.mechanism.cuda-volume-step`, `native-firesim.contract.shared-viewport-buffer`, `native-firesim.presentation.d3d-ui-compositor`

### Graph Expansion

- `native-firesim.pipeline.ui-to-worker-to-viewport`
- `native-firesim.contract.fire-settings`
- `native-firesim.contract.shared-viewport-buffer`
- `native-firesim.presentation.d3d-ui-compositor`
- `native-firesim.mechanism.worker-lifecycle-watchdog`
- `native-firesim.build.native-cuda-d3d11-target`
- `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.operator.validation-metrics`
- `native-firesim.benchmark.completed-worker-frame`
- `native-firesim.constraint.gpu-kernel-risk-gate`

### Graph Edges

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

### Ranked Retrieval

- `native-firesim.pipeline.ui-to-worker-to-viewport`
- `native-firesim.contract.fire-settings`
- `native-firesim.contract.shared-viewport-buffer`
- `native-firesim.operator.validation-metrics`
- `native-firesim.presentation.d3d-ui-compositor`
- `native-firesim.benchmark.completed-worker-frame`
- `native-firesim.mechanism.worker-lifecycle-watchdog`
- `native-firesim.mechanism.nist-calibration-runner`
- `native-firesim.build.native-cuda-d3d11-target`
- `native-firesim.mechanism.cuda-volume-step`
- `native-firesim.dataset.nist-fcd-benchmark`
- `semantic.verification-surface.launch-firesim.ps1`
