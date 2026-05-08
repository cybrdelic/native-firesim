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

Require-Text $cuda "volumeShadowRay" "CUDA renderer no longer has source-to-surface volumetric shadow rays"
Require-Text $cuda "volumeVisibility = volumeShadowRay" "room shading no longer gates irradiance through volumetric visibility"
Require-Text $cuda "volumetricShadowSum" "CUDA metrics no longer accumulate volumetric shadow"
Require-Text $cuda "roomIrradianceSum" "CUDA metrics no longer accumulate room irradiance"
Require-Text $cuda "verticalDepth" "scene shadow field no longer includes depth-aware plume attenuation"
Require-Text $cuda "opticalShadow" "scene shadow field no longer includes soot optical shadowing"
Require-Text $header "meanVolumetricShadow" "public frame metrics no longer expose mean volumetric shadow"
Require-Text $header "meanRoomIrradiance" "public frame metrics no longer expose mean room irradiance"
Require-Text $main "finalMeanVolumetricShadow" "validation JSON no longer reports mean volumetric shadow"
Require-Text $main "finalMeanRoomIrradiance" "validation JSON no longer reports mean room irradiance"

if (-not $SkipDiagnostics) {
    if (-not (Test-Path -LiteralPath $diagPath)) {
        throw "missing out\diagnostics.txt; run .\scripts\verify.ps1 -DiagnosticsOnly first or pass -SkipDiagnostics"
    }
    $diag = Get-Content -LiteralPath $diagPath -Raw
    Require-Text $diag "volumetricShadowing=scene shadow volume stores soot optical transmittance and room rays sample source-to-surface visibility" "diagnostics do not report volumetric shadowing"
    Require-Text $diag "roomLightingLayer=room surfaces receive flame-fed irradiance gated by volumetric shadow and material albedo" "diagnostics do not report room lighting layer"
}

Write-Host "lighting architecture ok"
