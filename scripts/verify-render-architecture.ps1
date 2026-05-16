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
$capturePath = Join-Path $root "scripts\capture-scene-set.ps1"


if (-not (Test-Path -LiteralPath $mainPath)) {
    throw "missing src\main.cpp"
}
if (-not (Test-Path -LiteralPath $docPath)) {
    throw "missing docs\render-graph.md"
}

$source = Get-Content -LiteralPath $mainPath -Raw
$cuda = Get-Content -LiteralPath (Join-Path $root "src\fire_cuda.cu") -Raw
$sparseIntegrator = Get-Content -LiteralPath (Join-Path $root "src\render_sparse_integrator.cu") -Raw
$quality = Get-Content -LiteralPath (Join-Path $root "src\runtime_quality.h") -Raw
$d3dTypes = Get-Content -LiteralPath $d3dTypesPath -Raw
$doc = Get-Content -LiteralPath $docPath -Raw
$capture = Get-Content -LiteralPath $capturePath -Raw

Require-Text $source "constexpr DXGI_FORMAT kSceneRadianceFormat = DXGI_FORMAT_R16G16B16A16_FLOAT;" "source no longer declares the FP16 scene-radiance contract"
Require-Text $source "constexpr const char* kRenderGraphPasses = `"clear,volume-hdr-camera,ui-overlay,present`";" "source no longer declares the named render graph"
Require-Text $source "rendererContractHeader=src\\firesim_render_contract.h" "diagnostics must report renderer contract ownership header"
Require-Text $source "renderD3DVolumeCameraPass" "source no longer has a dedicated volume camera pass"
Require-Text $source "renderD3DUiOverlayPass" "source no longer has a dedicated UI overlay pass"
Require-Text $source "CameraResponse" "source no longer has a named HDR camera response"
Require-Text $source "meshLightingPass=removed; fire scenes are CUDA volumes without imported GLB geometry" "diagnostics must report that imported mesh lighting was removed"
Require-Text $source "sparseVolumeTraversal=raymarch uses active-field empty-space skipping" "diagnostics must report sparse volume traversal"
Require-Text $source "sparseBrickMetadata=brickSize=8" "diagnostics must report sparse brick metadata"
Require-Text $source "sparseBrickEffectiveness=activeBrickCount=" "diagnostics must report sparse brick effectiveness"
Require-Text $source "brick-exit-bounded-sparse-raymarch" "diagnostics must report the brick-exit sparse traversal rewrite"
Require-Text $source "temporalVolumeSampling=historyFrames=" "diagnostics must report temporal volume sampling"
Require-Text $source "radianceCache=scene light volume updates every" "diagnostics must report the radiance-cache cadence"
Require-Text $cuda '#include "volume_bricks.h"' "CUDA runtime must consume extracted sparse brick metadata header"
Require-Text $cuda '#include "volume_bricks.cu"' "CUDA runtime must include extracted sparse brick metadata implementation"
Require-Text $cuda '#include "render_sparse_integrator.cu"' "CUDA runtime must include extracted sparse integrator implementation"
Require-Text $cuda "sparseRaymarchBrickSkipDecision" "CUDA renderer must call extracted sparse skip logic"
Require-Text $cuda "sparseRaymarchBrickExitStride" "CUDA renderer must bound sparse skips by brick exits"
Require-Text $cuda "buildBrickMetaKernel" "CUDA runtime must build sparse brick metadata"
Require-Text $cuda "cudaMalloc sparse brick metadata" "CUDA runtime must allocate sparse brick metadata"
Require-Text $cuda "sparse brick metadata launch" "CUDA step must dispatch sparse brick metadata after simulation"
Require-Text $cuda "const BrickMeta* brickMeta" "CUDA camera integrator must consume sparse brick metadata"
Require-Text $sparseIntegrator "brickActivity" "CUDA camera integrator must use brick activity for empty-space skipping"
Require-Text $cuda "volume_raymarch_sparse_skip_slices" "CUDA renderer must expose sparse-skip raymarch NVTX ranges"
Require-Text $cuda "sparseRaymarchMaxEmptyStride" "CUDA params must carry sparse raymarch stride settings"
Require-Text $cuda "temporalJitterPhase" "CUDA raymarch sampling must be temporally phased"
Require-Text $cuda "updateRadianceCache" "scene lighting must be cached instead of recomputed unconditionally every frame"
Require-Text $quality "kSparseRaymarchMaxEmptyStride" "runtime quality must own sparse raymarch stride limits"
Require-Text $quality "kTemporalVolumeHistoryFrames" "runtime quality must own temporal volume history settings"
Require-Text $quality "kRadianceCacheUpdateIntervalFrames" "runtime quality must own radiance cache cadence"
Forbid-Text $source "renderD3DSceneMeshPass(exposure)" "runtime render graph must not draw imported scene meshes"
Require-Text $source "OMSetBlendState(g_d3d.alphaBlend.Get(), blendFactor, 0xffffffffu)" "UI pass must own alpha blending explicitly"
Require-Text $capture "Start-Process -FilePath `$exe" "scene capture must launch the Windows app through a waitable process"
Require-Text $capture "-Wait -PassThru" "scene capture must wait for the GUI process before auditing frames"
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
    Require-Text $diag "rendererContractHeader=src\firesim_render_contract.h" "diagnostics do not report renderer contract header"
    Require-Text $diag "renderGraphOwnsCameraResponse=true" "diagnostics do not report render-graph camera ownership"
    Require-Text $diag "uiOverlayAfterCameraResponse=true" "diagnostics do not report UI-after-camera ordering"
    Require-Text $diag "sparseVolumeTraversal=raymarch uses active-field empty-space skipping" "diagnostics do not report sparse traversal"
    Require-Text $diag "sparseBrickMetadata=brickSize=8" "diagnostics do not report sparse brick metadata"
    Require-Text $diag "sparseBrickEffectiveness=activeBrickCount=" "diagnostics do not report sparse brick effectiveness"
    Require-Text $diag "traversal=brick-exit-bounded-sparse-raymarch" "diagnostics do not report the brick-exit sparse traversal rewrite"
    Require-Text $diag "temporalVolumeSampling=historyFrames=" "diagnostics do not report temporal volume sampling"
    Require-Text $diag "radianceCache=scene light volume updates every" "diagnostics do not report radiance cache cadence"
}

Write-Host "render architecture ok"
