param(
    [switch]$SkipDiagnostics
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$cudaPath = Join-Path $root "src\fire_cuda.cu"
$mainPath = Join-Path $root "src\main.cpp"
$sceneRuntimeHeaderPath = Join-Path $root "src\scene_runtime.h"
$sceneRuntimePath = Join-Path $root "src\scene_runtime.cpp"
$sceneAssetsPath = Join-Path $root "src\scene_assets.cpp"
$diagPath = Join-Path $root "out\diagnostics.txt"
$methanolScenePath = Join-Path $root "assets\fire-scenes\methanol-pool\scene.json"

$cuda = Get-Content -LiteralPath $cudaPath -Raw
$main = Get-Content -LiteralPath $mainPath -Raw
$sceneRuntimeHeader = Get-Content -LiteralPath $sceneRuntimeHeaderPath -Raw
$sceneRuntime = Get-Content -LiteralPath $sceneRuntimePath -Raw
$sceneAssets = Get-Content -LiteralPath $sceneAssetsPath -Raw
$methanolScene = Get-Content -LiteralPath $methanolScenePath -Raw

Require-Text $sceneRuntimeHeader "constexpr int kSceneCount = 1;" "runtime must expose exactly one product scene"
Require-Text $sceneRuntimeHeader "constexpr int kProductSceneId = 0;" "product scene id must be the only runtime scene id"
Require-Text $sceneRuntimeHeader 'constexpr const char* kProductSceneKey = "methanol-pool";' "product scene key must remain methanol-pool"
Require-Text $methanolScene '"type": "liquid-pool-source"' "methanol scene must declare a liquid-pool source"
Require-Text $methanolScene '"sourceDataset": "benchmarks/nist-fcd/methanol-1m-pool-r1/manifest.json"' "methanol scene must stay tied to the NIST reference dataset"
Require-Text $sceneAssets 'jsonObjectForKey(sceneContract, "emitter")' "scene emitter contract is no longer parsed as an explicit nested object"
Require-Text $sceneRuntimeHeader "struct SceneInstance" "canonical scene instance contract is missing"
Require-Text $sceneRuntime "SceneInstance makeSceneInstance" "scene instance builder is missing"
Require-Text $sceneRuntime "c.source.sourceMode = 3" "methanol pool must use the liquid pool source model"
Require-Text $main "g_sceneEmitters[kProductSceneId] = loadSceneEmitterParams(kProductSceneId);" "runtime must load only the product emitter"
Require-Text $main "productSceneIsolation=interactive and desktop runtime expose only the NIST methanol product scene" "diagnostics product scene isolation string is missing from source"
Require-Text $main "sceneSourceModels=NIST methanol 1m liquid pool product path only; non-product scene assets are disabled backlog, not runtime scenes" "diagnostics source model string is missing from source"
Require-Text $cuda "(void)settings.sceneSourceMode;" "CUDA source path must ignore stale caller source modes"
Require-Text $cuda "params.sceneSourceMode = 3;" "CUDA source path must force the liquid-pool source mode"
Require-Text $cuda "const float methanolPoolCalibration = 1.0f;" "CUDA combustion must be calibrated as methanol, not scene-switched at render time"
Require-Text $cuda "soot = fminf(soot, kNistMethanolMaxSmokeOpticalDepth" "methanol soot cap must stay active"
Forbid-Text $cuda "sceneSourceMode == 2" "non-product source mode leaked back into the CUDA product path"
Forbid-Text $cuda "gasBurnerPort" "non-product source helper leaked back into the CUDA product path"

if (-not $SkipDiagnostics) {
    if (-not (Test-Path -LiteralPath $diagPath)) {
        throw "missing out\diagnostics.txt; run .\scripts\verify.ps1 -DiagnosticsOnly first or pass -SkipDiagnostics"
    }
    $diag = Get-Content -LiteralPath $diagPath -Raw
    Require-Text $diag "productSceneIsolation=interactive and desktop runtime expose only the NIST methanol product scene" "diagnostics do not report product scene isolation"
    Require-Text $diag "sceneSourceModels=NIST methanol 1m liquid pool product path only; non-product scene assets are disabled backlog, not runtime scenes" "diagnostics do not report scene source models"
}

Write-Host "scene source models ok"
