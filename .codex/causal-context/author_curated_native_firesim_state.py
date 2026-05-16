from pathlib import Path
import sys


SKILL_SCRIPT_DIR = Path(r"C:\Users\alexf\.codex\skills\causal-context-compiler\scripts")
sys.path.insert(0, str(SKILL_SCRIPT_DIR))

from ccc_common import write_jsonl


OUT = Path(__file__).with_name("curated-mechanisms.jsonl")


def evidence(kind, path=None, line=None, note=None, source=None):
    item = {"kind": kind}
    if path:
        item["path"] = path
    if line:
        item["line"] = line
    if note:
        item["note"] = note
    if source:
        item["source"] = source
    return item


frames = [
    {
        "id": "native-firesim.pipeline.ui-to-worker-to-viewport",
        "type": "mechanism",
        "state": "Native FireSim presents live fire through a process-isolated CUDA worker rather than by running CUDA kernels inside the UI process.",
        "parents": [
            "native-firesim.contract.shared-viewport-buffer",
            "native-firesim.mechanism.worker-lifecycle-watchdog",
            "native-firesim.mechanism.cuda-volume-step",
            "native-firesim.presentation.d3d-ui-compositor",
        ],
        "mechanism": "visible_frame := ui_present(copy(shared_fp16_d3d11_texture(worker_render(step(settings)))))",
        "context": ["native-firesim", "Win32", "CUDA", "D3D11", "interactive viewport"],
        "status": "inferred",
        "confidence": 0.85,
        "interventions": [
            "run NativeFireSim.exe with default worker path and inspect out/worker-events.log",
            "do(disable_cuda_worker) and verify the viewport reports no live CUDA frame instead of synthesizing motion",
            "simulate stale worker heartbeat and verify UI status changes without killing the UI process",
        ],
        "evidence": [
            evidence("source", "README.md", 3, "README states the main viewport starts an isolated CUDA worker and receives real 3D volume frames through shared memory."),
            evidence("source", "src/main.cpp", 3454, "WinMain routes diagnostics, worker benchmark, cuda worker, validation, smoke test, and default interactive UI."),
            evidence("source", "src/main.cpp", 3496, "Default interactive path starts the CUDA worker when enabled."),
            evidence("source", "src/main.cpp", 3555, "Main loop copies worker frames and falls back to explicit no-live-frame state when stale."),
        ],
        "abstractions": ["pipeline-orchestrator", "crash-boundary", "dynamic expansion target"],
        "reconstruct": ["runtime diagram", "operator narrative", "source excerpt"],
        "open_questions": [
            "Which current runtime artifact proves fresh worker frames on this exact machine after the latest build?"
        ],
    },
    {
        "id": "native-firesim.contract.shared-viewport-buffer",
        "type": "constraint",
        "state": "SharedViewportBuffer is the ABI between the UI process and the CUDA worker.",
        "parents": ["native-firesim.build.native-cuda-d3d11-target"],
        "mechanism": "handoff_valid := magic/version/buildStamp/displayFormat match && frameSequence is stable_even && texture_slot is acquireable",
        "context": ["native-firesim", "shared memory", "worker UI ABI"],
        "status": "observed",
        "confidence": 0.91,
        "interventions": [
            "change kSharedViewportVersion and verify stale mappings are reset",
            "corrupt buildStamp in a fixture and assert initializeSharedViewport resets the buffer",
            "force an odd frameSequence and verify UI refuses the candidate frame",
        ],
        "evidence": [
            evidence("source", "src/main.cpp", 45, "Shared viewport magic, version, display format, and name are constants."),
            evidence("source", "src/main.cpp", 85, "SharedViewportBuffer contains frame sequence, worker status, settings, timing, texture handles, and status text."),
            evidence("source", "src/main.cpp", 1689, "initializeSharedViewport creates/maps the named buffer and resets incompatible mappings."),
            evidence("source", "src/main.cpp", 1747, "writeWorkerSettings sends FireSettings through the shared buffer."),
        ],
        "abstractions": ["state-contract", "shared-memory contract", "worker boundary"],
        "reconstruct": ["ABI summary", "source excerpt", "failure-mode table"],
        "open_questions": [
            "Should the shared ABI have a separate schema/version test independent of the running app?"
        ],
    },
    {
        "id": "native-firesim.mechanism.worker-lifecycle-watchdog",
        "type": "mechanism",
        "state": "The UI process supervises the CUDA worker with heartbeat age, frame freshness, stale-kill, restart backoff, and visible status.",
        "parents": ["native-firesim.contract.shared-viewport-buffer"],
        "mechanism": "worker_status := f(process_alive, heartbeat_age, frame_age, restart_count, exit_code)",
        "context": ["native-firesim", "worker supervision", "interactive viewport"],
        "status": "observed",
        "confidence": 0.88,
        "interventions": [
            "kill worker process and verify worker-exited event plus restart behavior",
            "freeze heartbeatTickMs and assert stale kill after kWorkerKillStaleMs",
            "force repeated worker exits and verify restart cooldown after kWorkerRestartLimit",
        ],
        "evidence": [
            evidence("source", "src/main.cpp", 55, "Worker stale-frame, heartbeat, kill, restart-window, and restart-limit constants are defined."),
            evidence("source", "src/main.cpp", 1682, "appendRuntimeEvent writes out/worker-events.log."),
            evidence("source", "src/main.cpp", 1825, "startCudaWorker creates the worker process with explicit CUDA-risk flags."),
            evidence("source", "src/main.cpp", 1909, "serviceCudaWorkerWatchdog updates UI status and handles stale worker recovery."),
        ],
        "abstractions": ["runtime-configuration", "verification-surface", "fault-containment mechanism"],
        "reconstruct": ["watchdog state machine", "event log interpretation", "source excerpt"],
        "open_questions": [
            "What is the empirical restart behavior when CUDA initialization fails on the current driver?"
        ],
    },
    {
        "id": "native-firesim.mechanism.cuda-volume-step",
        "type": "mechanism",
        "state": "The CUDA backend advances and renders a 3D fire volume from FireSettings through field advection, reaction, pressure projection, lighting, raymarching, and packing.",
        "parents": ["native-firesim.contract.fire-settings", "native-firesim.operator.validation-metrics"],
        "mechanism": "frame_pixels, metrics := pack(raymarch(light(project(react(advect(fields, settings))))))",
        "context": ["native-firesim", "CUDA backend", "3D volume solver"],
        "status": "inferred",
        "confidence": 0.84,
        "interventions": [
            "run smoke test with accepted GPU risk and compare cuda-smoke-test-frame.bmp to expected nonblank output",
            "set renderDebugMode to isolate velocity/reaction/smoke channels and inspect output metrics",
            "reduce pressure iterations in a branch and verify divergenceAfter metrics worsen",
        ],
        "evidence": [
            evidence("source", "src/fire_cuda.cu", 845, "advectReactKernel updates combustion-related scalar channels."),
            evidence("source", "src/fire_cuda.cu", 1089, "divergenceKernel begins pressure projection mechanics."),
            evidence("source", "src/fire_cuda.cu", 1105, "sorPressureKernel performs weighted red/black pressure relaxation."),
            evidence("source", "src/fire_cuda.cu", 1706, "renderKernel raymarches volume fields into a frame."),
            evidence("source", "src/fire_cuda.cu", 2926, "fireCudaStepAndRenderMeasured exposes measured frame stepping."),
        ],
        "abstractions": ["transformation-mechanism", "physics state transition", "renderer pipeline"],
        "reconstruct": ["kernel pipeline", "math sketch", "validation test plan"],
        "open_questions": [
            "Which physical quantities are calibrated versus only visual proxies?"
        ],
    },
    {
        "id": "native-firesim.contract.fire-settings",
        "type": "constraint",
        "state": "FireSettings is the control vector that maps UI inputs and worker settings into CUDA simulation and rendering parameters.",
        "parents": [],
        "mechanism": "sim_params := clamp_and_copy(FireSettings, frame_dimensions, grid_dimensions, camera_basis)",
        "context": ["native-firesim", "CUDA API", "interactive controls"],
        "status": "observed",
        "confidence": 0.89,
        "interventions": [
            "vary one FireSettings field and record which metrics or pixels change",
            "set reset=1 and verify field reset path executes",
            "clamp raymarchSteps above maximum and verify kernel uses bounded value",
        ],
        "evidence": [
            evidence("source", "src/fire_cuda.h", 52, "FireSettings defines dt, input state, wind, turbulence, camera, raymarch, ember, debug, and exposure controls."),
            evidence("source", "src/main.cpp", 196, "sameFireSettings lists fields that define settings equality."),
            evidence("source", "src/main.cpp", 3549, "Main loop writes worker settings without gizmos to the worker."),
        ],
        "abstractions": ["state-contract", "control vector", "intervention surface"],
        "reconstruct": ["control table", "source excerpt", "parameter intervention matrix"],
        "open_questions": [
            "Which settings should be exposed as calibration variables instead of interactive-only controls?"
        ],
    },
    {
        "id": "native-firesim.operator.validation-metrics",
        "type": "observation",
        "state": "Validation mode converts CUDA simulation frames into metrics, CSV rows, BMP frames, and a JSON report.",
        "parents": ["native-firesim.mechanism.cuda-volume-step", "native-firesim.dataset.nist-fcd-methanol-r1"],
        "mechanism": "validation_artifacts := summarize(fireCudaStepAndRenderMeasured(settings), target_envelopes, calibration_sidecars)",
        "context": ["native-firesim", "validation mode", "lab-grade evidence"],
        "status": "observed",
        "confidence": 0.9,
        "interventions": [
            "run --validation with explicit GPU risk acceptance and inspect validation-report.json",
            "tighten validation-targets.csv and verify validationOk flips when metrics exceed envelopes",
            "remove calibration sidecar and assert comparison CSV is missing or degraded",
        ],
        "evidence": [
            evidence("source", "src/fire_cuda.h", 16, "FireCudaFrameMetrics declares divergence, timing, scalar totals, flame height, optical depth, and heat-release proxy fields."),
            evidence("source", "src/main.cpp", 3048, "Validation mode chooses frame count and output paths."),
            evidence("source", "src/main.cpp", 3071, "Validation metrics CSV header includes solver, render, scalar, and divergence columns."),
            evidence("source", "src/main.cpp", 3292, "Validation report writes validationOk from stability and artifact-writing checks."),
        ],
        "abstractions": ["observation-operator", "verification-surface", "calibration bridge"],
        "reconstruct": ["artifact index", "metric glossary", "validation failure diagnosis"],
        "open_questions": [
            "Do current target envelopes distinguish physically meaningful failures from merely broad smoke-test failures?"
        ],
    },
    {
        "id": "native-firesim.dataset.nist-fcd-methanol-r1",
        "type": "entity",
        "state": "NIST_FCD_Methanol_1m_Pool_R1 provides the real-dataset calibration anchor for HRR, derived fuel mass, gas channels, radiant heat flux, and smoke extinction.",
        "parents": [],
        "mechanism": "calibration_claim_scope := manifest(source, hashes, geometry, measurement_channels, derived_channels, target_envelopes)",
        "context": ["native-firesim", "benchmarks", "NIST FCD"],
        "status": "verified",
        "confidence": 0.93,
        "interventions": [
            "rerun verify-lab-grade.ps1 -RequireRealDataset after changing manifest or calibration CSV",
            "change calibrationCsvSha256 and verify hash check fails",
            "delete a declared measurement column and verify data coverage fails",
        ],
        "evidence": [
            evidence("source", "benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json", 3, "Manifest identifies experimentId and claim scope."),
            evidence("source", "benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json", 33, "Manifest pins calibration and raw CSV SHA-256 hashes."),
            evidence("source", "benchmarks/nist-fcd/methanol-1m-pool-r1/validation-targets.csv", 4, "Target envelopes include calibration shape RMSE metrics."),
            evidence("observation", "out/lab-grade-readiness.json", None, "Real dataset preflight passed with failCount=0 and warnCount=0."),
        ],
        "abstractions": ["initial-condition-generator", "calibration dataset", "ground-truth anchor"],
        "reconstruct": ["dataset card", "provenance table", "calibration target summary"],
        "open_questions": [
            "Which additional NIST channels should become hard validation metrics next?"
        ],
    },
    {
        "id": "native-firesim.verification.lab-grade-preflight",
        "type": "observation",
        "state": "The lab-grade preflight currently verifies required docs, real dataset manifest, geometry, CSV coverage, channel metadata, hashes, and source fields with zero warnings.",
        "parents": ["native-firesim.dataset.nist-fcd-methanol-r1"],
        "mechanism": "preflight_ok := all(file_checks, manifest_checks, geometry_checks, csv_checks, hash_checks)",
        "context": ["native-firesim", "safe local verification", "2026-05-03"],
        "status": "verified",
        "confidence": 0.96,
        "interventions": [
            "rerun scripts/verify-lab-grade.ps1 -RequireRealDataset",
            "remove a required dataset hash and confirm failCount increases",
            "add an unbacked claimed channel and confirm coverage or metadata checks fail",
        ],
        "evidence": [
            evidence("command", source="powershell -ExecutionPolicy Bypass -File .\\scripts\\verify-lab-grade.ps1 -RequireRealDataset", note="Exited 0 with lab-grade preflight ok; warnings=0."),
            evidence("observation", "out/lab-grade-readiness.json", None, "failCount=0, warnCount=0, direct measured channels with data=8, declared channels with data=10."),
            evidence("source", "scripts/verify-lab-grade.ps1", 177, "Script parses manifest and emits structured checks."),
            evidence("source", "scripts/verify-lab-grade.ps1", 248, "Script reads calibration CSV and validates channel coverage."),
        ],
        "abstractions": ["verification-surface", "evidence promotion gate", "dataset integrity check"],
        "reconstruct": ["verification report", "checklist", "CI gate proposal"],
        "open_questions": [
            "Should this preflight become a required CI step for every benchmark edit?"
        ],
    },
    {
        "id": "native-firesim.mechanism.nist-calibration-runner",
        "type": "mechanism",
        "state": "The NIST calibration runner resolves a manifest to geometry, calibration CSV, target envelopes, output directory, and only launches CUDA validation with explicit risk acceptance.",
        "parents": [
            "native-firesim.dataset.nist-fcd-methanol-r1",
            "native-firesim.operator.validation-metrics",
            "native-firesim.constraint.gpu-kernel-risk-gate",
        ],
        "mechanism": "calibration_run := verify_dataset(manifest) -> if risk_accepted then native_validation(...) else write_plan",
        "context": ["native-firesim", "NIST calibration", "PowerShell runner"],
        "status": "verified",
        "confidence": 0.92,
        "interventions": [
            "run scripts/run-nist-calibration.ps1 -PlanOnly and inspect calibration-run-plan.json",
            "run with -RunGpuKernels without -AcceptBugcheckRisk and verify it blocks",
            "run with fake missing manifest file and verify path resolution fails before CUDA",
        ],
        "evidence": [
            evidence("source", "scripts/run-nist-calibration.ps1", 16, "Default manifest path points to NIST FCD methanol pool-fire dataset."),
            evidence("source", "scripts/run-nist-calibration.ps1", 56, "Runner invokes verify-lab-grade before CUDA validation."),
            evidence("source", "scripts/run-nist-calibration.ps1", 62, "Without RunGpuKernels, runner writes a plan and does not launch CUDA."),
            evidence("observation", "out/validation/NIST_FCD_Methanol_1m_Pool_R1/calibration-run-plan.json", None, "Plan generated with readyToRunCuda=false and explicit reason."),
        ],
        "abstractions": ["pipeline-orchestrator", "verification-surface", "risk-gated experiment"],
        "reconstruct": ["calibration workflow", "CLI contract", "test plan"],
        "open_questions": [
            "What minimal non-GPU simulation artifact could be compared against NIST before enabling kernels?"
        ],
    },
    {
        "id": "native-firesim.constraint.gpu-kernel-risk-gate",
        "type": "constraint",
        "state": "Live CUDA kernel paths are intentionally blocked unless the caller explicitly supplies GPU run and bugcheck-risk acceptance flags.",
        "parents": ["native-firesim.mechanism.cuda-volume-step"],
        "mechanism": "allow_gpu_kernels := has(--allow-gpu-kernels) && has(--accept-bugcheck-risk)",
        "context": ["native-firesim", "local Windows GPU safety", "verification"],
        "status": "observed",
        "confidence": 0.9,
        "interventions": [
            "run validation without --accept-bugcheck-risk and assert safety-stop output is written",
            "set FIRESIM_ACCEPT_BUGCHECK_RISK=1 and verify PowerShell runner accepts the risk gate",
            "ensure diagnostics/input-stress paths remain available without GPU kernel launch",
        ],
        "evidence": [
            evidence("source", "scripts/verify.ps1", 46, "verify.ps1 skips smoke and validation unless RunGpuKernels is set."),
            evidence("source", "scripts/verify.ps1", 50, "verify.ps1 throws unless bugcheck risk is accepted for GPU kernel verification."),
            evidence("source", "scripts/run-nist-calibration.ps1", 83, "NIST calibration runner blocks GPU validation unless bugcheck risk is accepted."),
            evidence("source", "src/main.cpp", 1503, "writeGpuSafetyStop writes instructions for explicit GPU override."),
        ],
        "abstractions": ["runtime-configuration", "safety interlock", "experiment gate"],
        "reconstruct": ["risk policy", "CLI examples", "verification boundary"],
        "open_questions": [
            "Can GPU smoke coverage be shifted to a sacrificial worker-only test that never risks the UI process?"
        ],
    },
    {
        "id": "native-firesim.presentation.d3d-ui-compositor",
        "type": "mechanism",
        "state": "The UI compositor copies the latest shared worker FP16 texture into the D3D display path and overlays operator UI/status.",
        "parents": ["native-firesim.contract.shared-viewport-buffer", "native-firesim.contract.fire-settings"],
        "mechanism": "swapchain_frame := compose(displaySimTexture(copy_worker_slot), uiTexture(status_overlay(settings, worker_status)))",
        "context": ["native-firesim", "D3D11 presentation", "operator viewport"],
        "status": "inferred",
        "confidence": 0.82,
        "interventions": [
            "feed a fixed worker texture slot and checksum displayed pixels",
            "force no fresh worker frame and verify UI status renders no-live-CUDA-frame state",
            "toggle clean viewport mode and verify overlay state changes without altering simulation frame",
        ],
        "evidence": [
            evidence("source", "src/main.cpp", 1069, "copyD3DWorkerFrame imports and copies the worker frame."),
            evidence("source", "src/main.cpp", 655, "UI drawing writes worker status text into the overlay."),
            evidence("source", "src/main.cpp", 729, "UI status distinguishes CUDA 3D volume from worker-waiting state."),
            evidence("source", "src/main.cpp", 3568, "Present is dirty when worker frame, overlay state, or no-live-frame state changes."),
        ],
        "abstractions": ["renderer-or-presentation", "observation projection", "operator UX"],
        "reconstruct": ["render pipeline diagram", "viewport state table", "screenshot checklist"],
        "open_questions": [
            "Where should a deterministic compositor screenshot test live?"
        ],
    },
    {
        "id": "native-firesim.benchmark.completed-worker-frame",
        "type": "observation",
        "state": "The worker benchmark measures completed CUDA/D3D frames and writes a JSON report with timing breakdowns rather than queue-submission timing.",
        "parents": ["native-firesim.mechanism.cuda-volume-step", "native-firesim.presentation.d3d-ui-compositor"],
        "mechanism": "worker_benchmark_report := time(completed_worker_frames) + sampled_gpu_breakdown",
        "context": ["native-firesim", "performance benchmark", "CUDA/D3D path"],
        "status": "observed",
        "confidence": 0.85,
        "interventions": [
            "run --worker-benchmark with explicit GPU risk acceptance and inspect worker-benchmark.json",
            "compare benchmark output before and after changing raymarch steps",
            "assert timingMode states completed-frame timing rather than queued submissions",
        ],
        "evidence": [
            evidence("source", "README.md", 91, "README documents completed-frame worker benchmark command."),
            evidence("source", "src/main.cpp", 2064, "runWorkerBenchmark parses benchmark arguments and output dir."),
            evidence("source", "src/main.cpp", 2194, "Benchmark samples FireCudaFrameMetrics after live timing."),
            evidence("source", "src/main.cpp", 2240, "Report records timingMode as live frames timed without metrics, with GPU breakdown sampled after live timing."),
        ],
        "abstractions": ["verification-surface", "performance probe", "intervention measurement"],
        "reconstruct": ["benchmark contract", "perf regression plan", "report schema"],
        "open_questions": [
            "What threshold should define regression for completed-frame FPS on this machine?"
        ],
    },
    {
        "id": "native-firesim.build.native-cuda-d3d11-target",
        "type": "constraint",
        "state": "The build produces a native Win32 C++17/CUDA17 executable targeting RTX 4060 Laptop GPU compute capability 8.9 and linking D3D11/DXGI/D3DCompiler.",
        "parents": [],
        "mechanism": "NativeFireSim.exe := cmake(CXX17, CUDA17, arch=89, src/main.cpp + src/fire_cuda.cu, d3d11/dxgi/d3dcompiler)",
        "context": ["native-firesim", "CMake", "Windows", "CUDA"],
        "status": "observed",
        "confidence": 0.88,
        "interventions": [
            "change CMAKE_CUDA_ARCHITECTURES and verify build target changes",
            "remove d3d11 link and verify linker failure at D3D integration points",
            "run scripts/verify.ps1 -DiagnosticsOnly after toolchain changes",
        ],
        "evidence": [
            evidence("source", "CMakeLists.txt", 3, "Project declares CXX and CUDA languages."),
            evidence("source", "CMakeLists.txt", 12, "CUDA architecture is set to 89 for RTX 4060 Laptop GPU."),
            evidence("source", "CMakeLists.txt", 14, "NativeFireSim executable includes main.cpp, fire_cuda.cu, and fire_cuda.h."),
            evidence("source", "CMakeLists.txt", 24, "Target links user32, winmm, d3d11, dxgi, and d3dcompiler."),
        ],
        "abstractions": ["runtime-configuration", "build contract", "platform constraint"],
        "reconstruct": ["build contract", "toolchain checklist", "failure diagnosis"],
        "open_questions": [
            "Should architecture 89 remain hard-coded or become a configured local profile?"
        ],
    },
]


write_jsonl(OUT, frames)
print(OUT)
