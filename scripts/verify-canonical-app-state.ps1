$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$main = Read-RepoText "src/main.cpp"
$runtimeState = Get-Content (Join-Path $root "src/runtime_state.h") -Raw
$diag = Join-Path $root "out\diagnostics\startup.txt"
Require-Text $runtimeState "struct CanonicalRuntimeState" "canonical runtime state struct is missing"
Require-Text $runtimeState "enum class RuntimeTransitionReason" "runtime transition reasons are missing"
Require-Text $main "applyRuntimeTransition" "state transitions must use one helper"
Require-Text $main "RuntimeTransitionReason::ProductSceneRefresh" "product-scene refresh transition reason is missing"
Require-Text $main "RuntimeTransitionReason::UserReset" "reset transition reason is missing"
Require-Text $main "RuntimeTransitionReason::WorkerStale" "worker stale transition reason is missing"
Require-Text $main "RuntimeTransitionReason::WorkerFrameCopied" "worker frame copied transition reason is missing"
Require-Text $main "RuntimeTransitionReason::OverlayChanged" "overlay changed transition reason is missing"
Require-Text $main "canonicalRuntimeState=scene,camera,controls,worker,frame,debug,and overlay transitions flow through CanonicalRuntimeState" "diagnostics canonical state string is missing from source"
if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "canonicalRuntimeState=scene,camera,controls,worker,frame,debug,and overlay transitions flow through CanonicalRuntimeState" "diagnostics do not report canonical runtime state"
}
Write-Host "canonical app state gate ok"
