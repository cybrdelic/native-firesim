$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$main = Read-RepoText "src/main.cpp"
$runtimeQuality = Read-RepoText "src/runtime_quality.h"
$source = "$runtimeQuality`n$main"
$diag = Join-Path $root "out\diagnostics\startup.txt"


Require-Text $source "constexpr double kAppPumpFps = 360.0" "app pump cadence must be explicit"
Require-Text $source "constexpr double kDisplayMaxPresentFps = 180.0" "display present cadence must be explicit"
Require-Text $source "static_assert(static_cast<int>(kAppPumpFps) == static_cast<int>(kDisplayMaxPresentFps) * 2" "app pump and present cadence must be locked to a 2:1 ratio"
Require-Text $main "displayPresentStep" "display present step must be precomputed"
Require-Text $main "presentBudgetDue && presentDirty" "present path must avoid repainting identical CUDA frames and starving the worker"
Require-Text $main "reusedDisplayFrame = g_cudaWorkerFrameLive && !copiedWorkerFrame" "reused display frames must be explicit telemetry"
Require-Text $main "g_liveReusedPresents" "reused presents must be counted"
Require-Text $main "g_d3d.swapChain->Present(0, 0)" "swapchain present must not use DO_NOT_WAIT because skipped presents can flicker"
Forbid-Text $main "DXGI_PRESENT_DO_NOT_WAIT" "nonblocking present reintroduced visible skipped-frame flicker"
Require-Text $main "fireStreamHealthLabel()" "operator status must expose fire-stream health"
Require-Text $main "fire-stream copy lag" "operator status must warn when copied CUDA frames lag physics"
Require-Text $main "ringTimeouts=%llu ringNoCandidate=%llu ringStarved=%llu" "live profile must include ring pressure counters"
Require-Text $main "fireStreamNeedsOperatorWarning()" "operator status must distinguish healthy and warning fire-stream states"
Require-Text $main "nextDisplayPresent += displayPresentStep" "present schedule must advance by fixed cadence instead of resetting from now"
Require-Text $main "reusedDisplayFrame" "frame trace must include display-frame reuse"
Require-Text $main "presentationPacing=2:1 fixed app pump with present-on-fresh-frame pacing to keep reused CUDA frames from starving the worker" "diagnostics pacing contract is missing from source"

if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "appPumpFps=360" "diagnostics do not report app pump FPS"
    Require-Text $diagText "presentationTargetFps=180" "diagnostics do not report presentation FPS"
    Require-Text $diagText "presentationPacing=2:1 fixed app pump with present-on-fresh-frame pacing to keep reused CUDA frames from starving the worker" "diagnostics do not report the pacing contract"
}

Write-Host "frame pacing gate ok"
