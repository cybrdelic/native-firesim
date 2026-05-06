# Native FireSim Development Workflow

This repo has one canonical workflow for each class of work. Do not add duplicate launchers or fallback runtime versions when a ticket can be handled by extending one of these paths.

## Local Gates

Use this before opening a normal runtime, scene, UI, or infrastructure PR:

```powershell
.\scripts\verify-roadmap-gates.ps1
```

That command runs the safe gates:

- diagnostics and build through `verify.ps1 -DiagnosticsOnly`
- imported scene asset verification through `verify-scene-assets.ps1`
- input stress coverage through the diagnostics verifier

GPU kernel validation remains explicit because this machine has had prior Windows bugchecks during risky CUDA paths:

```powershell
.\scripts\verify-roadmap-gates.ps1 -RunGpuKernels -AcceptBugcheckRisk
```

Only use the risky path when the PR specifically changes CUDA kernel execution, D3D interop, or validation behavior.

## Live App

Use the native app directly for manual visual review:

```powershell
.\build\NativeFireSim.exe --scene=2 --allow-gpu-kernels --accept-bugcheck-risk
```

The live viewport is not a substitute for the local gates. If the UI, GLB, source overlay, or worker status looks wrong, capture the window and attach it to the PR body.

## PR Evidence

Every visual, render, CUDA, scene, or performance PR should include:

- the issue numbers it addresses
- the exact verification commands that passed
- before/after screenshots or GIFs when pixels changed
- debug-overlay captures when alignment, source placement, or scene switching changed
- trace or timing output when performance, stutter, worker lifecycle, or interop changed
- a remaining-issues section that says what still looks wrong

The PR should not say a ticket is complete unless the acceptance criteria in the GitHub issue are actually satisfied.

## Roadmap Ticket Boundaries

Prefer stacked PRs when later tickets depend on earlier runtime work. Keep each PR small enough to review as a real change:

- runtime state and scene switching
- telemetry and frame pacing
- capture/regression tooling
- scene manifest contracts
- renderer architecture
- simulation models
- validation and lab-data harnesses

Avoid broad rewrites that mix all of those layers in one branch.
