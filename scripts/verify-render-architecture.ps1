param(
    [switch]$SkipDiagnostics
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $root "src\main.cpp"
$d3dTypesPath = Join-Path $root "src\d3d_render_types.h"
$docPath = Join-Path $root "docs\render-graph.md"
$diagPath = Join-Path $root "out\diagnostics.txt"


if (-not (Test-Path -LiteralPath $mainPath)) {
    throw "missing src\main.cpp"
}
if (-not (Test-Path -LiteralPath $docPath)) {
    throw "missing docs\render-graph.md"
}

$source = Get-Content -LiteralPath $mainPath -Raw
$d3dTypes = Get-Content -LiteralPath $d3dTypesPath -Raw
$doc = Get-Content -LiteralPath $docPath -Raw

Require-Text $source "constexpr DXGI_FORMAT kSceneRadianceFormat = DXGI_FORMAT_R16G16B16A16_FLOAT;" "source no longer declares the FP16 scene-radiance contract"
Require-Text $source "constexpr const char* kRenderGraphPasses = `"clear,volume-hdr-camera,ui-overlay,present`";" "source no longer declares the named render graph"
Require-Text $source "renderD3DVolumeCameraPass" "source no longer has a dedicated volume camera pass"
Require-Text $source "renderD3DUiOverlayPass" "source no longer has a dedicated UI overlay pass"
Require-Text $source "CameraResponse" "source no longer has a named HDR camera response"
Require-Text $source "meshLightingPass=removed; fire scenes are CUDA volumes without imported GLB geometry" "diagnostics must report that imported mesh lighting was removed"
Forbid-Text $source "renderD3DSceneMeshPass(exposure)" "runtime render graph must not draw imported scene meshes"
Require-Text $source "OMSetBlendState(g_d3d.alphaBlend.Get(), blendFactor, 0xffffffffu)" "UI pass must own alpha blending explicitly"
Require-Text $doc "The live viewport has one render graph." "render graph documentation lost its one-graph contract"
Require-Text $doc 'DXGI_FORMAT_R16G16B16A16_FLOAT' "render graph documentation lost the FP16 contract"
Require-Text $doc 'UI' "render graph documentation lost the UI pass rule"

if (-not $SkipDiagnostics) {
    if (-not (Test-Path -LiteralPath $diagPath)) {
        throw "missing out\diagnostics.txt; run .\scripts\verify.ps1 -DiagnosticsOnly first or pass -SkipDiagnostics"
    }
    $diag = Get-Content -LiteralPath $diagPath -Raw
    Require-Text $diag "sceneRadianceFormat=DXGI_FORMAT_R16G16B16A16_FLOAT" "diagnostics do not report FP16 scene radiance"
    Require-Text $diag "renderGraphPasses=clear,volume-hdr-camera,ui-overlay,present" "diagnostics do not report the named render graph"
    Require-Text $diag "renderGraphOwnsCameraResponse=true" "diagnostics do not report render-graph camera ownership"
    Require-Text $diag "uiOverlayAfterCameraResponse=true" "diagnostics do not report UI-after-camera ordering"
}

Write-Host "render architecture ok"
