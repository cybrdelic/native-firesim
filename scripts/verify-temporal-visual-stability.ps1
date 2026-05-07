$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$main = Get-Content (Join-Path $root "src/main.cpp") -Raw
$analyzerPath = Join-Path $root "scripts/analyze_live_frame_trace.py"
$analyzer = Get-Content $analyzerPath -Raw

function Require-Text($text, $needle, $message) {
    if (-not $text.Contains($needle)) {
        Write-Error $message
    }
}

Require-Text $main "FIRESIM_TRACE_FRAMES" "live frame tracing must stay available for stutter capture"
Require-Text $main "out\\live-frame-trace.csv" "live frame trace output path is missing"
Require-Text $main "reusedDisplayFrame" "trace must include display-frame reuse"
Require-Text $main "workerFrameUs,workerCudaUs,workerPublishUs" "trace must include worker timing columns"
Require-Text $analyzer "presentation misses have periodic every-N-frame pattern" "periodic skip detector is missing"
Require-Text $analyzer "presentation cadence jitter is above stability budget" "cadence jitter detector is missing"
Require-Text $analyzer "presentation has large skipped-frame interval" "skipped frame interval detector is missing"
Require-Text $analyzer "longestMissedPresentRun" "missed present run metric is missing"
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

Write-Host "temporal visual stability gate ok"
