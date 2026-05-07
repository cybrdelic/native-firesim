$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$main = Get-Content (Join-Path $root "src/main.cpp") -Raw
$diag = Join-Path $root "out\diagnostics\startup.txt"

function Require-Text($text, $needle, $message) {
    if (-not $text.Contains($needle)) {
        Write-Error $message
    }
}

Require-Text $main "constexpr int kSharedFrameSlots = 3" "shared ring slot count must stay explicit"
Require-Text $main "constexpr int kDisplayFrameSlots = 3" "display ring slot count must stay explicit"
Require-Text $main "AcquireSync(1, 0)" "host copy path must use bounded nonblocking keyed mutex acquire"
Require-Text $main "g_sharedRingAcquireTimeouts" "ring acquire timeout telemetry is missing"
Require-Text $main "g_sharedRingNoCandidateFrames" "ring no-candidate telemetry is missing"
Require-Text $main "g_sharedRingCopyStarvationFrames" "ring starvation telemetry is missing"
Require-Text $main "g_sharedRingSkippedActiveDisplaySlot" "display-slot skip telemetry is missing"
Require-Text $main "g_sharedRingLastCopiedSharedSlot" "last copied shared slot telemetry is missing"
Require-Text $main "g_sharedRingLastCopiedDisplaySlot" "last copied display slot telemetry is missing"
Require-Text $main "sequence > newestSequence" "ring copy path must select newest even sequence"
Require-Text $main "targetSlot == g_d3d.activeDisplaySimSlot" "ring copy path must avoid overwriting the active display slot"
Require-Text $main "ringSharedSlot,ringDisplaySlot,ringTimeouts,ringNoCandidate,ringStarved" "frame trace must include ring audit columns"
Require-Text $main "sharedTextureRingAudit=nonblocking keyed mutex acquire, newest-even sequence selection, display-slot rotation, timeout/no-candidate/starvation telemetry" "diagnostics ring audit string is missing from source"

if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "sharedTextureRingAudit=nonblocking keyed mutex acquire, newest-even sequence selection, display-slot rotation, timeout/no-candidate/starvation telemetry" "diagnostics do not report shared texture ring audit"
    Require-Text $diagText "sharedTextureRingSlots=3" "diagnostics do not report shared ring slots"
    Require-Text $diagText "displayTextureRingSlots=3" "diagnostics do not report display ring slots"
}

Write-Host "shared texture ring gate ok"
