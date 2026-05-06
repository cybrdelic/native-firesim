param(
    [switch]$SkipDiagnostics
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$cudaPath = Join-Path $root "src\fire_cuda.cu"
$mainPath = Join-Path $root "src\main.cpp"
$diagPath = Join-Path $root "out\diagnostics.txt"
$burnerMaskPath = Join-Path $root "assets\fire-scenes\gas-burner-aver1\emitter-mask.json"
$campScenePath = Join-Path $root "assets\fire-scenes\campfire\scene.json"

function Require-Text {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Needle,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not $Text.Contains($Needle)) {
        throw $Message
    }
}

$cuda = Get-Content -LiteralPath $cudaPath -Raw
$main = Get-Content -LiteralPath $mainPath -Raw
$burnerMask = Get-Content -LiteralPath $burnerMaskPath -Raw
$campScene = Get-Content -LiteralPath $campScenePath -Raw

Require-Text $burnerMask '"selectedBurnerIndex": 3' "gas burner mask no longer declares one selected burner"
Require-Text $burnerMask '"burnerCentersMeters"' "gas burner mask no longer exposes selected burner center"
Require-Text $campScene '"type": "solid-fuel-bed"' "campfire scene no longer declares solid fuel bed"
Require-Text $cuda "const int centerCount = 1;" "gas burner material no longer forces a single selected burner source"
Require-Text $cuda "cosf(angle * 32.0f)" "gas burner source no longer uses narrow port-driven jets"
Require-Text $cuda "sceneBuoyancyScale = p.sceneId == 2 ? 0.42f" "stove/gas burner buoyancy is no longer constrained"
Require-Text $cuda "contactPyrolysis" "campfire source no longer emphasizes log-contact pyrolysis"
Require-Text $cuda "p.sceneId == 1 ? 0.245f" "campfire source no longer has an expanded fuel-bed height band"
Require-Text $cuda "campTongueBias = p.sceneId == 1 ? smoothstepf(0.035f, 0.72f" "campfire raymarch no longer has an expanded warm tongue body"
Require-Text $cuda "scenePyrolysisGain = p.sceneId == 2 ? 0.42f : (p.sceneId == 1 ? 1.34f" "scene-specific pyrolysis gains are missing"
Require-Text $main "sceneSourceModels=gas selected low-soot burner ring; campfire log-contact char bed; room tray fuel bed" "diagnostics source model string is missing from source"

if (-not $SkipDiagnostics) {
    if (-not (Test-Path -LiteralPath $diagPath)) {
        throw "missing out\diagnostics.txt; run .\scripts\verify.ps1 -DiagnosticsOnly first or pass -SkipDiagnostics"
    }
    $diag = Get-Content -LiteralPath $diagPath -Raw
    Require-Text $diag "sceneSourceModels=gas selected low-soot burner ring; campfire log-contact char bed; room tray fuel bed" "diagnostics do not report scene source models"
}

Write-Host "scene source models ok"
