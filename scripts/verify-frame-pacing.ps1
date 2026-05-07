$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$main = Get-Content (Join-Path $root "src/main.cpp") -Raw
$diag = Join-Path $root "out\diagnostics\startup.txt"

function Require-Text($text, $needle, $message) {
    if (-not $text.Contains($needle)) {
        Write-Error $message
    }
}

Require-Text $main "constexpr double kAppPumpFps = 360.0" "app pump cadence must be explicit"
Require-Text $main "constexpr double kDisplayMaxPresentFps = 180.0" "display present cadence must be explicit"
Require-Text $main "static_assert(static_cast<int>(kAppPumpFps) == static_cast<int>(kDisplayMaxPresentFps) * 2" "app pump and present cadence must be locked to a 2:1 ratio"
Require-Text $main "displayPresentStep" "display present step must be precomputed"
Require-Text $main "presentBudgetDue && (presentDirty || g_cudaWorkerFrameLive)" "present path must run on cadence even when reusing a CUDA frame"
Require-Text $main "reusedDisplayFrame = g_cudaWorkerFrameLive && !copiedWorkerFrame" "reused display frames must be explicit telemetry"
Require-Text $main "g_liveReusedPresents" "reused presents must be counted"
Require-Text $main "fireStreamHealthLabel()" "operator status must expose fire-stream health"
Require-Text $main "fire-stream copy lag" "operator status must warn when copied CUDA frames lag physics"
Require-Text $main "ringTimeouts=%llu ringNoCandidate=%llu ringStarved=%llu" "live profile must include ring pressure counters"
Require-Text $main "fireStreamNeedsOperatorWarning()" "operator status must distinguish healthy and warning fire-stream states"
Require-Text $main "nextDisplayPresent += displayPresentStep" "present schedule must advance by fixed cadence instead of resetting from now"
Require-Text $main "reusedDisplayFrame" "frame trace must include display-frame reuse"
Require-Text $main "presentationPacing=2:1 fixed app pump to present cadence with intentional display-frame reuse" "diagnostics pacing contract is missing from source"

if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "appPumpFps=360" "diagnostics do not report app pump FPS"
    Require-Text $diagText "presentationTargetFps=180" "diagnostics do not report presentation FPS"
    Require-Text $diagText "presentationPacing=2:1 fixed app pump to present cadence with intentional display-frame reuse" "diagnostics do not report the pacing contract"
}

Write-Host "frame pacing gate ok"
