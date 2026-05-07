$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$main = Get-Content (Join-Path $root "src/main.cpp") -Raw
$diag = Join-Path $root "out\diagnostics\startup.txt"
function Require-Text($text, $needle, $message) { if (-not $text.Contains($needle)) { Write-Error $message } }
Require-Text $main "enum class WorkerLifecycleReason" "worker lifecycle reason enum is missing"
Require-Text $main "appendWorkerLifecycleEvent" "worker lifecycle event helper is missing"
Require-Text $main "WorkerLifecycleReason::StartRequested" "start reason is missing"
Require-Text $main "WorkerLifecycleReason::RestartBlocked" "restart blocked reason is missing"
Require-Text $main "WorkerLifecycleReason::StaleHeartbeatKill" "stale kill reason is missing"
Require-Text $main "WorkerLifecycleReason::ForcedTerminate" "forced termination reason is missing"
Require-Text $main "WorkerLifecycleReason::GpuInitFailed" "GPU init failure reason is missing"
Require-Text $main "WorkerLifecycleReason::InteropFailed" "interop failure reason is missing"
Require-Text $main "WorkerLifecycleReason::RenderFailed" "render failure reason is missing"
Require-Text $main "worker-lifecycle:%s" "worker event prefix is missing"
Require-Text $main "workerLifecycleReasons=start-requested,createprocess-failed,restart-blocked,stale-heartbeat-kill,stop-requested,forced-terminate,exited,gpu-init-failed,interop-failed,render-failed,clean-exit" "diagnostics worker lifecycle string is missing from source"
if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "workerLifecycleEvents=worker-lifecycle:<reason> entries in out/worker-events.log" "diagnostics do not report lifecycle event contract"
}
Write-Host "worker lifecycle gate ok"
