param(
    [switch]$SkipDiagnostics
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$cudaPath = Join-Path $root "src\fire_cuda.cu"
$headerPath = Join-Path $root "src\fire_cuda.h"
$mainPath = Join-Path $root "src\main.cpp"
$diagPath = Join-Path $root "out\diagnostics.txt"


$cuda = Get-Content -LiteralPath $cudaPath -Raw
$header = Get-Content -LiteralPath $headerPath -Raw
$main = Get-Content -LiteralPath $mainPath -Raw

Require-Text $header "flameMassProxy" "frame metrics no longer expose flame mass"
Require-Text $header "smokeMassProxy" "frame metrics no longer expose smoke mass"
Require-Text $header "flameSmokeOverlapProxy" "frame metrics no longer expose flame/smoke overlap"
Require-Text $cuda "resolvedFlameSheet" "raymarch no longer computes a resolved flame-sheet mask"
Require-Text $cuda "smokeOnlyMask" "raymarch no longer computes a smoke-only mask"
Require-Text $cuda "nearFlameSootCleanout" "raymarch no longer suppresses soot inside emissive samples"
Require-Text $cuda "flameSmokeOverlapProxy" "CUDA metrics no longer accumulate flame/smoke overlap"
Require-Text $main "finalFlameSmokeOverlapProxy" "validation JSON no longer reports flame/smoke overlap"
Require-Text $main "flameMassProxy,smokeMassProxy,flameSmokeOverlapProxy" "validation CSV no longer reports separation proxies"

if (-not $SkipDiagnostics) {
    if (-not (Test-Path -LiteralPath $diagPath)) {
        throw "missing out\diagnostics.txt; run .\scripts\verify.ps1 -DiagnosticsOnly first or pass -SkipDiagnostics"
    }
    $diag = Get-Content -LiteralPath $diagPath -Raw
    Require-Text $diag "volumeSmokeFlameSeparation=resolved flame-sheet mask suppresses soot absorption and scattering inside emissive samples" "diagnostics do not report the smoke/flame separation contract"
}

Write-Host "volume separation ok"
