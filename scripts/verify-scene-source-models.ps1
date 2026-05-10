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
$burnerMaskPath = Join-Path $root "assets\fire-scenes\gas-burner-aver1\emitter-mask.json"
$campScenePath = Join-Path $root "assets\fire-scenes\campfire\scene.json"


$cuda = Get-Content -LiteralPath $cudaPath -Raw
$main = Get-Content -LiteralPath $mainPath -Raw
$sceneRuntimeHeader = Get-Content -LiteralPath $sceneRuntimeHeaderPath -Raw
$sceneRuntime = Get-Content -LiteralPath $sceneRuntimePath -Raw
$sceneAssets = Get-Content -LiteralPath $sceneAssetsPath -Raw
$burnerMask = Get-Content -LiteralPath $burnerMaskPath -Raw
$campScene = Get-Content -LiteralPath $campScenePath -Raw

Require-Text $burnerMask '"selectedBurnerIndex": 3' "gas burner mask no longer declares one selected burner"
Require-Text $burnerMask '"burnerCentersMeters"' "gas burner mask no longer exposes selected burner center"
Require-Text $campScene '"type": "solid-fuel-bed"' "campfire scene no longer declares solid fuel bed"
Require-Text $sceneAssets 'jsonObjectForKey(sceneContract, "emitter")' "scene emitter contract is no longer parsed as an explicit nested object"
Require-Text $sceneAssets "const std::string& emitterSource = emitterContract.empty() ? sceneContract : emitterContract" "scene emitter loader no longer isolates nested emitter fields before legacy fallback"
Require-Text $sceneAssets "sceneMeshTranslationMeters(sceneId, sceneContract)" "scene mesh translation contract is not centralized"
Require-Text $sceneAssets "applySceneMeshTranslation(" "scene-to-sim point transform is not centralized"
Require-Text $sceneRuntimeHeader "struct SceneInstance" "canonical scene instance contract is missing"
Require-Text $sceneRuntime "SceneInstance makeSceneInstance" "scene instance builder is missing"
Require-Text $sceneRuntime "selectedBurnerExitY" "scene source coordinates must use the same selected burner exit height as CUDA"
Require-Text $main "const LONG sceneEpoch = settings.sceneEpoch > 0 ? settings.sceneEpoch : g_sceneEpoch" "scene instance refresh must preserve host-authored epochs across worker process boundaries"
Require-Text $sceneRuntime "settings.sceneEpoch = static_cast<int>(sceneEpoch)" "scene emitter application must stamp settings with canonical scene epoch"
Require-Text $main "sceneInstanceContract=SceneInstance owns scene id, epoch, emitter, source center/radius/height, and selected burner state" "diagnostics scene instance contract is missing from source"
Require-Text $sceneAssets "params.burnerCenterX[i] = burnerPoint[0]" "burner centers no longer share the scene-to-sim transform"
Require-Text $sceneAssets "params.burnerCenterY[i] = burnerPoint[1]" "burner center height no longer shares the scene-to-sim transform"
Require-Text $sceneAssets "params.heightNorm = ((params.burnerCenterY[0] + params.heightBandNorm * 2.03f * 0.42f) - 0.02f) / 2.03f" "burner source height is not lifted to the selected burner exit plane"
Require-Text $cuda "burnerExitY = params.burnerCenterY[0] + params.emitterHeightBandNorm * 2.03f * 0.42f" "CUDA source height is not lifted to the selected burner exit plane"
Require-Text $cuda "params.emitterHeightNorm = std::max(0.0f, std::min(0.96f, (burnerExitY - 0.02f) / 2.03f))" "CUDA source height is not locked to selected burner exit geometry"
Require-Text $cuda "p.emitterHeightNorm * 2.03f + 0.02f" "CUDA source overlays no longer use effective selected burner exit height"
if ($cuda.Contains("sourceLocalV = p.sceneId == 2 ? fmaxf(0.0f, fv - p.emitterHeightNorm) : fv")) {
    throw "burner flame masks clamp below-source samples onto the source plane"
}
Require-Text $cuda "sourceSignedV = lerpf(fv, fv - p.emitterHeightNorm, p.sceneSourcePlaneMode)" "burner flame masks no longer use a signed source-plane coordinate"
Require-Text $cuda "sourceAboveV = lerpf(fv, fmaxf(0.0f, sourceSignedV), p.sceneSourcePlaneMode)" "burner upward flame masks no longer use the signed source coordinate"
Require-Text $cuda "sourceCellV = 1.0f / static_cast<float>(p.ny)" "burner flame masks no longer account for vertical grid-cell sampling"
Require-Text $cuda "sourcePlaneGate = lerpf(1.0f, selectedSourcePlaneGate, p.sceneSourcePlaneMode)" "burner masks no longer reject samples below the selected source plane"
Require-Text $cuda "fabsf(sourceSignedV)) * sourcePlaneGate" "burner lower white core is no longer source-plane gated"
Require-Text $cuda "flameHeightFade * roomCoverageBoost * sourcePlaneGate" "burner flame density is no longer source-plane gated"
Require-Text $cuda "__device__ float gasBurnerPortSource" "gas burner no longer has a separate port/ring source model"
Require-Text $cuda "__device__ float gasBurnerPortEmitter" "gas burner source must be a separate port emitter, not a solid fuel-bed material"
Require-Text $cuda "p.sceneSourceMode == 2" "gas burner scene has fallen back to generic fuel-bed material"
Require-Text $cuda "return gasBurnerPortEmitter(x, z, h, p);" "gas burner source mode no longer dispatches to the port emitter"
Require-Text $cuda "charMass = 0.0f;" "gas burner chemistry must not retain solid fuel-bed char"
Require-Text $cuda "ash = 0.0f;" "gas burner chemistry must not retain solid fuel-bed ash"
Require-Text $cuda "const float burner = gasBurnerPortSource(hit.x, hit.z, p)" "gas burner floor visualization must use port geometry, not fuel-bed material"
Require-Text $cuda "noPoolCenter" "gas burner source no longer suppresses broad pool-like center fill"
Require-Text $cuda "attachmentClamp" "gas burner source no longer clamps lateral spread to the selected port attachment"
Require-Text $cuda "cosf(angle * 32.0f)" "gas burner source no longer uses narrow port-driven jets"
Require-Text $sceneRuntime "c.combustion.curlScale = 0.38f" "stove/gas burner curl is no longer constrained by the scene profile"
Require-Text $sceneRuntime "c.combustion.buoyancyScale = 0.42f" "stove/gas burner buoyancy is no longer constrained by the scene profile"
Require-Text $sceneRuntime "c.combustion.buoyancyCeiling = 0.24f" "stove/gas burner buoyancy ceiling is no longer constrained by the scene profile"
Require-Text $sceneRuntime "c.combustion.buoyancyFloor = 0.035f" "stove/gas burner buoyancy floor is no longer constrained by the scene profile"
Require-Text $cuda "contactPyrolysis" "campfire source no longer emphasizes log-contact pyrolysis"
Require-Text $campScene '"heightBandMeters": 0.2' "campfire source no longer has an expanded fuel-bed height band in the scene contract"
Require-Text $cuda "p.sceneSourceHeightCeiling" "source height band must come from the scene profile"
Require-Text $cuda "campTongueBias = p.sceneCampTongueScale *" "campfire raymarch no longer has an expanded warm tongue body"
Require-Text $cuda "smoothstepf(0.035f, 0.72f, fuel + pyrolysis * 0.50f + charMass * 0.12f)" "campfire raymarch no longer has fuel/char tongue shaping"
Require-Text $sceneRuntime "c.combustion.pyrolysisGain = 1.42f" "campfire scene-specific pyrolysis gain is missing from the scene profile"
Require-Text $sceneRuntime "c.combustion.fuelGain = 1.22f" "campfire scene-specific fuel gain is missing from the scene profile"
Require-Text $sceneRuntime "c.combustion.heatGain = 1.34f" "campfire scene-specific heat gain is missing from the scene profile"
Require-Text $sceneRuntime "c.combustion.gasFeed = 1.80f" "burner scene-specific gas feed is missing from the scene profile"
Require-Text $sceneRuntime "c.combustion.pyrolysisGain = 0.90f" "burner scene-specific pyrolysis gain is missing from the scene profile"
Require-Text $sceneRuntime "c.combustion.fuelGain = 1.05f" "burner scene-specific fuel gain is missing from the scene profile"
Require-Text $sceneRuntime "c.combustion.heatGain = 2.80f" "burner scene-specific heat gain is missing from the scene profile"
Require-Text $sceneRuntime "c.combustion.sootGain = 0.18f" "burner scene-specific soot gain is missing from the scene profile"
Require-Text $main "sceneSourceModels=gas selected low-soot burner ring; campfire log-contact char bed; room tray fuel bed; NIST methanol 1m liquid pool" "diagnostics source model string is missing from source"

if (-not $SkipDiagnostics) {
    if (-not (Test-Path -LiteralPath $diagPath)) {
        throw "missing out\diagnostics.txt; run .\scripts\verify.ps1 -DiagnosticsOnly first or pass -SkipDiagnostics"
    }
    $diag = Get-Content -LiteralPath $diagPath -Raw
    Require-Text $diag "sceneSourceModels=gas selected low-soot burner ring; campfire log-contact char bed; room tray fuel bed; NIST methanol 1m liquid pool" "diagnostics do not report scene source models"
}

Write-Host "scene source models ok"
