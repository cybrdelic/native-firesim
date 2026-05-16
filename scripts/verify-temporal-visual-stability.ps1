$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$main = Read-RepoText "src/main.cpp"
$analyzerPath = Join-Path $root "scripts/analyze_live_frame_trace.py"
$analyzer = Get-Content $analyzerPath -Raw


Require-Text $main "FIRESIM_TRACE_FRAMES" "live frame tracing must stay available for stutter capture"
Require-Text $main "out\\live-frame-trace.csv" "live frame trace output path is missing"
Require-Text $main "constexpr unsigned long long kWorkerFrameStaleMs = 650ull" "displayed CUDA frame freshness budget must tolerate the measured fresh-frame cadence without false stale labels"
Require-Text $main "input.workerFrameStaleMs = kWorkerFrameDisplayHoldMs" "health labels must use the retained-display budget to avoid false stale overlays"
Require-Text $main "kWorkerFrameDisplayHoldMs" "display path must retain the last good CUDA texture through short copy gaps"
Require-Text $main "g_lastCopiedWorkerFrameTickMs" "fire freshness must be based on the last copied display frame, not only worker publication"
Require-Text $main "constexpr int kWorkerPhysicsFrameInterval = 1" "CUDA worker physics cadence must match the current measured-renderer tuning"
Require-Text $main "framesSincePhysics >= kWorkerPhysicsFrameInterval" "worker physics cadence must be explicit and bounded"
Require-Text $main "reusedDisplayFrame" "trace must include display-frame reuse"
Require-Text $main "retainedCudaFrame" "main loop must not clear the CUDA display texture on a single copy miss"
Require-Text $main "workerFrameDisplayHoldMs=" "diagnostics must report the CUDA display hold budget"
Require-Text $main "workerFrameUs,workerCudaUs,workerPublishUs" "trace must include worker timing columns"
Require-Text $analyzer "presentation misses have periodic every-N-frame pattern" "periodic skip detector is missing"
Require-Text $analyzer "worker physics cadence is below published frame cadence" "physics cadence detector is missing"
Require-Text $analyzer "worker emitted render-only frames between physics updates" "render-only worker cadence detector is missing"
Require-Text $analyzer "presentation cadence jitter is above stability budget" "cadence jitter detector is missing"
Require-Text $analyzer "presentation has large skipped-frame interval" "skipped frame interval detector is missing"
Require-Text $analyzer "CUDA fire frame age exceeded freshness budget" "stale CUDA fire frame detector is missing"
Require-Text $analyzer "shared texture ring copy path starved" "ring starvation detector is missing"
Require-Text $analyzer "shared texture producer did not rotate slots" "producer slot-rotation detector is missing"
Require-Text $analyzer "CUDA fire frames have consecutive copy misses" "copy-miss run detector is missing"
Require-Text $analyzer "longestMissedPresentRun" "missed present run metric is missing"
Require-Text $analyzer "longestCopyMissRun" "copy-miss run metric is missing"
Require-Text $analyzer "sharedSlotCoverage" "shared slot coverage metric is missing"
Require-Text $analyzer "ringStarvedEvents" "ring starvation metric is missing"
Require-Text $analyzer "periodicSkipScore" "periodic skip score metric is missing"

$fixtureDir = Join-Path $root "out\temporal-stability-fixture"
New-Item -ItemType Directory -Force $fixtureDir | Out-Null
$fixture = Join-Path $fixtureDir "live-frame-trace.csv"
@"
tickMs,dtMs,copyUs,presentUs,frameUs,copied,presented,reusedDisplayFrame,uploadUi,backend,seq,slot,frameAgeMs,ringSharedSlot,ringDisplaySlot,ringTimeouts,ringNoCandidate,ringStarved,workerPublishedFrames,workerPhysicsFrames,workerRenderOnlyFrames,workerFrameUs,workerCudaUs,workerPublishUs
0,3,1,900,3000,1,1,0,1,1,2,0,2,0,0,0,0,0,1,1,0,5000,4300,100
6,3,1,880,3000,0,1,1,0,1,2,0,4,0,1,0,0,0,1,1,1,5000,4300,100
12,3,1,0,3000,0,0,0,0,1,2,0,6,0,1,0,0,0,1,1,2,5000,4300,100
18,3,1,910,3000,1,1,0,0,1,4,1,2,1,2,0,0,0,2,2,2,5000,4300,100
24,3,1,890,3000,0,1,1,0,1,4,1,4,1,2,0,0,0,2,2,3,5000,4300,100
30,3,1,0,3000,0,0,0,0,1,4,1,6,1,2,0,0,0,2,2,4,5000,4300,100
36,3,1,905,3000,1,1,0,0,1,6,2,2,2,0,0,0,0,3,3,4,5000,4300,100
42,3,1,895,3000,0,1,1,0,1,6,2,4,2,0,0,0,0,3,3,5,5000,4300,100
48,3,1,0,3000,0,0,0,0,1,6,2,6,2,0,0,0,0,3,3,6,5000,4300,100
54,3,1,910,3000,1,1,0,0,1,8,0,2,0,1,0,0,0,4,4,6,5000,4300,100
60,3,1,890,3000,0,1,1,0,1,8,0,4,0,1,0,0,0,4,4,7,5000,4300,100
66,3,1,0,3000,0,0,0,0,1,8,0,6,0,1,0,0,0,4,4,8,5000,4300,100
"@ | Set-Content -Path $fixture -Encoding utf8

$reportPath = Join-Path $fixtureDir "report.json"
python $analyzerPath --trace $fixture --out $reportPath | Out-Host
$report = Get-Content $reportPath -Raw | ConvertFrom-Json
if (-not ($report.issues -contains "presentation misses have periodic every-N-frame pattern")) {
    Write-Error "temporal analyzer did not detect periodic skip fixture"
}
if (-not ($report.issues -contains "worker physics cadence is below published frame cadence")) {
    Write-Error "temporal analyzer did not detect sparse worker physics cadence"
}
if (-not ($report.issues -contains "worker emitted render-only frames between physics updates")) {
    Write-Error "temporal analyzer did not detect render-only worker frames"
}

$starvedFixture = Join-Path $fixtureDir "starved-fire-trace.csv"
@"
tickMs,dtMs,copyUs,presentUs,frameUs,copied,presented,reusedDisplayFrame,uploadUi,backend,seq,slot,frameAgeMs,ringSharedSlot,ringDisplaySlot,ringTimeouts,ringNoCandidate,ringStarved,workerPublishedFrames,workerPhysicsFrames,workerRenderOnlyFrames,workerFrameUs,workerCudaUs,workerPublishUs
0,4,1,900,4000,1,1,0,1,1,2,0,2,0,0,0,0,0,1,1,0,5000,4300,100
6,4,1,880,4000,0,1,1,0,1,2,0,14,0,0,0,1,0,2,2,0,5000,4300,100
12,4,1,890,4000,0,1,1,0,1,2,0,26,0,0,0,2,0,3,3,0,5000,4300,100
18,4,1,910,4000,0,1,1,0,1,2,0,38,0,0,1,3,1,4,4,0,5000,4300,100
24,4,1,900,4000,0,1,1,0,1,2,0,50,0,0,2,4,1,5,5,0,5000,4300,100
30,4,1,905,4000,0,1,1,0,1,2,0,62,0,0,3,5,2,6,6,0,5000,4300,100
36,4,1,895,4000,0,1,1,0,1,2,0,74,0,0,4,6,2,7,7,0,5000,4300,100
42,4,1,905,4000,0,1,1,0,1,2,0,86,0,0,5,7,3,8,8,0,5000,4300,100
48,4,1,900,4000,0,1,1,0,1,2,0,98,0,0,6,8,3,9,9,0,5000,4300,100
54,4,1,890,4000,0,1,1,0,1,2,0,110,0,0,7,9,4,10,10,0,5000,4300,100
60,4,1,900,4000,0,1,1,0,1,2,0,122,0,0,8,10,4,11,11,0,5000,4300,100
66,4,1,905,4000,0,1,1,0,1,2,0,134,0,0,9,11,5,12,12,0,5000,4300,100
"@ | Set-Content -Path $starvedFixture -Encoding utf8

$starvedReportPath = Join-Path $fixtureDir "starved-report.json"
python $analyzerPath --trace $starvedFixture --out $starvedReportPath | Out-Host
$starvedReport = Get-Content $starvedReportPath -Raw | ConvertFrom-Json
foreach ($issue in @(
    "CUDA fire frames have consecutive copy misses",
    "CUDA fire frame age exceeded freshness budget",
    "shared texture ring copy path starved",
    "shared texture producer did not rotate slots"
)) {
    if (-not ($starvedReport.issues -contains $issue)) {
        Write-Error "temporal analyzer did not detect expected stale fire issue: $issue"
    }
}

Write-Host "temporal visual stability gate ok"
