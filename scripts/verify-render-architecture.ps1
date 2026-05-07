param(
    [switch]$SkipDiagnostics
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $root "src\main.cpp"
$docPath = Join-Path $root "docs\render-graph.md"
$diagPath = Join-Path $root "out\diagnostics.txt"

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

if (-not (Test-Path -LiteralPath $mainPath)) {
    throw "missing src\main.cpp"
}
if (-not (Test-Path -LiteralPath $docPath)) {
    throw "missing docs\render-graph.md"
}

$source = Get-Content -LiteralPath $mainPath -Raw
$doc = Get-Content -LiteralPath $docPath -Raw

Require-Text $source "constexpr DXGI_FORMAT kSceneRadianceFormat = DXGI_FORMAT_R16G16B16A16_FLOAT;" "source no longer declares the FP16 scene-radiance contract"
Require-Text $source "constexpr const char* kRenderGraphPasses = `"clear,volume-hdr-camera,lit-scene-mesh,ui-overlay,present`";" "source no longer declares the named render graph"
Require-Text $source "renderD3DVolumeCameraPass" "source no longer has a dedicated volume camera pass"
Require-Text $source "renderD3DSceneMeshPass" "source no longer has a dedicated scene mesh pass"
Require-Text $source "renderD3DUiOverlayPass" "source no longer has a dedicated UI overlay pass"
Require-Text $source "CameraResponse" "source no longer has a named HDR camera response"
Require-Text $source "ComPtr<ID3D11DepthStencilView> meshDepthView" "GLTF mesh pass no longer owns a depth buffer"
Require-Text $source "return float4(color, 1.0)" "GLTF mesh shader must be opaque, not ghosted through alpha"
Require-Text $source "OMSetBlendState(nullptr, blendFactor, 0xffffffffu)" "GLTF mesh pass must render opaque without alpha blending"
Require-Text $source "OMSetBlendState(g_d3d.alphaBlend.Get(), blendFactor, 0xffffffffu)" "UI pass must own alpha blending explicitly"
Require-Text $doc "The live viewport has one render graph." "render graph documentation lost its one-graph contract"
Require-Text $doc 'DXGI_FORMAT_R16G16B16A16_FLOAT' "render graph documentation lost the FP16 contract"
Require-Text $doc 'UI and mesh drawing stay outside that display transform' "render graph documentation lost the camera/UI separation rule"

if (-not $SkipDiagnostics) {
    if (-not (Test-Path -LiteralPath $diagPath)) {
        throw "missing out\diagnostics.txt; run .\scripts\verify.ps1 -DiagnosticsOnly first or pass -SkipDiagnostics"
    }
    $diag = Get-Content -LiteralPath $diagPath -Raw
    Require-Text $diag "sceneRadianceFormat=DXGI_FORMAT_R16G16B16A16_FLOAT" "diagnostics do not report FP16 scene radiance"
    Require-Text $diag "renderGraphPasses=clear,volume-hdr-camera,lit-scene-mesh,ui-overlay,present" "diagnostics do not report the named render graph"
    Require-Text $diag "renderGraphOwnsCameraResponse=true" "diagnostics do not report render-graph camera ownership"
    Require-Text $diag "uiOverlayAfterCameraResponse=true" "diagnostics do not report UI-after-camera ordering"
}

Write-Host "render architecture ok"
