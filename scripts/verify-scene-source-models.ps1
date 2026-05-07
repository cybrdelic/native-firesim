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
Require-Text $main 'jsonObjectForKey(sceneContract, "emitter")' "scene emitter contract is no longer parsed as an explicit nested object"
Require-Text $main "const std::string& emitterSource = emitterContract.empty() ? sceneContract : emitterContract" "scene emitter loader no longer isolates nested emitter fields before legacy fallback"
Require-Text $main "sceneMeshTranslationMeters(sceneId, sceneContract)" "scene mesh translation contract is not centralized"
Require-Text $main "applySceneMeshTranslation(" "scene-to-sim point transform is not centralized"
Require-Text $main "struct SceneInstance" "canonical scene instance contract is missing"
Require-Text $main "SceneInstance makeSceneInstance" "scene instance builder is missing"
Require-Text $main "settings.sceneEpoch = instance.sceneEpoch" "scene emitter application must stamp settings with canonical scene epoch"
Require-Text $main "sceneInstanceContract=SceneInstance owns scene id, epoch, emitter, source center/radius/height, imported mesh presence, and selected burner state" "diagnostics scene instance contract is missing from source"
Require-Text $main "params.burnerCenterX[i] = burnerPoint[0]" "burner centers no longer share the scene-to-sim transform"
Require-Text $main "params.burnerCenterY[i] = burnerPoint[1]" "burner center height no longer shares the scene-to-sim transform"
Require-Text $main "params.heightNorm = ((params.burnerCenterY[0] + params.heightBandNorm * 2.03f * 0.42f) - 0.02f) / 2.03f" "burner source height is not lifted to the selected burner exit plane"
Require-Text $cuda "burnerExitY = params.burnerCenterY[0] + params.emitterHeightBandNorm * 2.03f * 0.42f" "CUDA source height is not lifted to the selected burner exit plane"
Require-Text $cuda "params.emitterHeightNorm = std::max(0.0f, std::min(0.96f, (burnerExitY - 0.02f) / 2.03f))" "CUDA source height is not locked to selected burner exit geometry"
Require-Text $cuda "p.emitterHeightNorm * 2.03f + 0.02f" "CUDA source overlays no longer use effective selected burner exit height"
if ($cuda.Contains("sourceLocalV = p.sceneId == 2 ? fmaxf(0.0f, fv - p.emitterHeightNorm) : fv")) {
    throw "burner flame masks clamp below-source samples onto the source plane"
}
Require-Text $cuda "sourceSignedV = p.sceneId == 2 ? fv - p.emitterHeightNorm : fv" "burner flame masks no longer use a signed source-plane coordinate"
Require-Text $cuda "sourceAboveV = p.sceneId == 2 ? fmaxf(0.0f, sourceSignedV) : fv" "burner upward flame masks no longer use the signed source coordinate"
Require-Text $cuda "sourceCellV = 1.0f / static_cast<float>(p.ny)" "burner flame masks no longer account for vertical grid-cell sampling"
Require-Text $cuda "sourcePlaneGate = p.sceneId == 2" "burner masks no longer reject samples below the selected source plane"
Require-Text $cuda "fabsf(sourceSignedV)) * sourcePlaneGate" "burner lower white core is no longer source-plane gated"
Require-Text $cuda "flameHeightFade * roomCoverageBoost * sourcePlaneGate" "burner flame density is no longer source-plane gated"
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
