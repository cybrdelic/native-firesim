# Causal Context View: native FireSim CUDA renderer calibration lab-grade verification evidence

## Operational Thesis
Relevant state centers on docs/lab-grade-roadmap.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions; benchmarks/nist-fcd/methanol-1m-pool-r1/README.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions; benchmarks/README.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions.

## Relevant Frames

### `semantic.verification-surface.docs-lab-grade-roadmap.md`

- score: `38`
- type/status/confidence: `observation` / `inferred` / `0.74`
- state: docs/lab-grade-roadmap.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` docs/lab-grade-roadmap.md — Matched verification-surface signals: smoke, test, validation

### `semantic.verification-surface.benchmarks-nist-fcd-methanol-1m-pool-r1-readme.md`

- score: `24`
- type/status/confidence: `observation` / `inferred` / `0.7799999999999999`
- state: benchmarks/nist-fcd/methanol-1m-pool-r1/README.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` benchmarks/nist-fcd/methanol-1m-pool-r1/README.md — Matched verification-surface signals: benchmark, path:verification-surface

### `semantic.verification-surface.benchmarks-readme.md`

- score: `24`
- type/status/confidence: `observation` / `inferred` / `0.82`
- state: benchmarks/README.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` benchmarks/README.md — Matched verification-surface signals: benchmark, path:verification-surface, smoke, validation

### `semantic.verification-surface.docs-crash-analysis.md`

- score: `24`
- type/status/confidence: `observation` / `inferred` / `0.74`
- state: docs/crash-analysis.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` docs/crash-analysis.md — Matched verification-surface signals: smoke, test, validation

### `semantic.verification-surface.docs-fire-visual-gap-audit.md`

- score: `24`
- type/status/confidence: `observation` / `inferred` / `0.72`
- state: docs/fire-visual-gap-audit.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` docs/fire-visual-gap-audit.md — Matched verification-surface signals: smoke, validation

### `semantic.verification-surface.docs-gpu-engineering.md`

- score: `24`
- type/status/confidence: `observation` / `inferred` / `0.74`
- state: docs/gpu-engineering.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` docs/gpu-engineering.md — Matched verification-surface signals: benchmark, smoke, validation

### `semantic.verification-surface.docs-performance-bug-audit.md`

- score: `24`
- type/status/confidence: `observation` / `inferred` / `0.74`
- state: docs/performance-bug-audit.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` docs/performance-bug-audit.md — Matched verification-surface signals: benchmark, probe, validation

### `semantic.verification-surface.docs-reference-target.md`

- score: `24`
- type/status/confidence: `observation` / `inferred` / `0.7799999999999999`
- state: docs/reference-target.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` docs/reference-target.md — Matched verification-surface signals: benchmark, fixture, probe, smoke, validation

### `semantic.verification-surface.readme.md`

- score: `24`
- type/status/confidence: `observation` / `inferred` / `0.72`
- state: README.md acts as a verification-surface: can produce evidence about a mechanism under controlled conditions
- mechanism: evidence := run(probe_or_test, target_mechanism, fixture)
- interventions: run_the_named_test_or_probe_and_record_output, add_one_fixture_for_the_target_mechanism, promote_only_frames_supported_by_the_observation
- abstractions: evidence producer, verification, intervention, verification-surface
- evidence:
  - `source` README.md — Matched verification-surface signals: smoke, test

## Unknowns
Promote low-confidence or hypothesis frames only after inspecting the cited evidence or running an intervention/test.
