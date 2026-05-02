# Infrastructure Hardening Plan

This project has already hit Windows bugchecks on the live CUDA path. The hardening goal is not just "catch errors"; it is to make unsafe GPU states isolated, diagnosable, reproducible, and gated.

## Source-Backed Constraints

- Windows WDDM TDR treats a GPU task that cannot complete or be preempted inside the default timeout as a frozen GPU. Microsoft documents the default timeout as two seconds and recommends graphics operations complete under that in end-user scenarios: https://learn.microsoft.com/en-us/windows-hardware/drivers/display/timeout-detection-and-recovery
- CUDA kernel launches are asynchronous. NVIDIA documents that launches do not return kernel error codes directly; callers must check launch errors and synchronize to catch asynchronous failures: https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html
- CUDA call-stack warnings matter. NVIDIA documents that unknown stack size is usually caused by recursive functions and can require explicit stack sizing if default stack size is insufficient: https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html
- NVIDIA Compute Sanitizer memcheck detects out-of-bounds, misaligned accesses, hardware-reported errors, and leaks: https://docs.nvidia.com/compute-sanitizer/ComputeSanitizer/index.html
- NVIDIA Compute Sanitizer racecheck detects shared-memory data-access hazards and recommends running memcheck first: https://docs.nvidia.com/compute-sanitizer/ComputeSanitizer/index.html
- Nsight Compute is NVIDIA's CUDA kernel profiler for detailed metrics and API debugging: https://developer.nvidia.com/nsight-compute

## Current Controls

- Main viewport process does not initialize CUDA or submit custom kernels.
- Live CUDA is isolated in a worker process.
- Worker frames and settings use shared memory with sequence checks.
- Worker heartbeat/frame staleness is monitored.
- Live smoke/validation commands require explicit `--allow-gpu-kernels --accept-bugcheck-risk`.
- Heavy kernels are sliced across z windows or frame rows.
- Raymarch, tone-map, overlay, metrics, and solver passes are separate launches.
- CUDA diagnostics are allowed without simulation kernels.
- `scripts/verify.ps1 -DiagnosticsOnly` is the normal no-live-kernel verification path.

## Hardening Gaps

1. No automated lab-readiness gate.
2. No machine-readable experiment manifest with provenance and uncertainty.
3. No compute-sanitizer wrapper for tiny canary kernels.
4. No per-kernel budget report from CUDA events in normal worker mode.
5. No launch-shape/resource budget snapshot in CI-style verification.
6. No persistent driver/GPU/runtime fingerprint per validation run.
7. No crash-breadcrumb file written before every risky kernel phase.
8. No shader/renderer visual regression that compares current frames to target metrics without live driver risk.
9. No residual-targeted pressure-solve gate.
10. No code-generated report that separates verification, validation, and visual-quality status.

## Required Controls

1. Lab-readiness preflight.
   - Validate calibration CSV headers.
   - Validate geometry JSON fields.
   - Validate dataset manifest source/provenance/uncertainty.
   - Write `out/lab-grade-readiness.json`.
   - Never launch CUDA kernels.

2. Risk-tiered GPU verification.
   - Tier 0: build, lint, diagnostics, input stress, lab-readiness preflight.
   - Tier 1: CUDA canary only.
   - Tier 2: one-frame smoke with watchdog and sanitizer option.
   - Tier 3: full validation sequence.
   - Tier 4: profiling/performance sweep.

3. Kernel resource budget.
   - Record registers, local memory, static stack warnings, launch dimensions, and event timing.
   - Fail if unknown stack-size warnings return.
   - Fail if any single launch exceeds a configured TDR-safe budget in profiling runs.

4. Dataset provenance.
   - Require source URL or DOI.
   - Require license/terms.
   - Require raw and processed file hashes.
   - Require uncertainty per measured channel.
   - Require preprocessing command.

5. Validation report split.
   - Verification: code/numerics.
   - Validation: experiment comparison.
   - Rendering: perceptual/target-image gap.
   - Operations: driver/runtime/crash safety.

## Immediate Project Contract

Normal development must pass:

```powershell
.\scripts\verify.ps1 -DiagnosticsOnly
```

Real dataset admission must pass:

```powershell
.\scripts\verify-lab-grade.ps1 -RequireRealDataset
```

Live GPU validation remains explicit:

```powershell
.\scripts\verify.ps1 -RunGpuKernels -AcceptBugcheckRisk
```

Do not merge a claim like "lab-grade" unless the generated validation report cites a real dataset and reports uncertainty-bounded error for that specific scenario.
