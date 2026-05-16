$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")

$runtimeHeader = Read-RepoText "src/scene_runtime.h"
$runtime = Read-RepoText "src/scene_runtime.cpp"
$cuda = Read-RepoText "src/fire_cuda.cu"
$main = Read-RepoText "src/main.cpp"

Require-Text $runtimeHeader "constexpr int kSceneCount = 1;" "runtime must expose exactly one product scene"
Require-Text $runtimeHeader "constexpr int kProductSceneId = 0;" "product scene id must be the only runtime scene id"
Require-Text $runtimeHeader 'constexpr const char* kProductSceneKey = "methanol-pool";' "product scene key must remain methanol-pool"
Require-Text $runtimeHeader "struct SceneProfile" "canonical scene profile contract is missing"
Require-Text $runtimeHeader "struct SceneValidationEnvelope" "scene validation envelope is missing"
Require-Text $runtimeHeader "struct SceneCudaCoefficients" "scene-owned CUDA coefficient contract is missing"
Require-Text $runtimeHeader "struct SceneCameraProfile" "scene camera profile contract is missing"
Require-Text $runtime "constexpr SceneProfile kMethanolProfile" "scene runtime must centralize the single methanol profile"
Require-Text $runtime '"methanol-pool"' "methanol product profile is missing"
Require-Text $runtime '"nist-1m-liquid-pool"' "methanol source model is missing"
if (([regex]::Matches($runtime, "constexpr\s+SceneProfile\s+k[A-Za-z0-9_]+Profile")).Count -ne 1) {
    throw "scene runtime must define exactly one product profile"
}
Require-Text $main "const SceneProfile& profile = sceneProfile(validationScene)" "validation must consume the canonical scene profile"
Require-Text $main "const SceneValidationEnvelope& envelope = profile.validation" "validation must consume profile-owned envelopes"
Require-Text $main '\"sceneProfile\"' "validation JSON must report the scene profile used for the run"
Forbid-Text $cuda "sceneInitialHeatBase" "CUDA reset path reintroduced pre-seeded heat instead of material-only initial conditions"
Forbid-Text $cuda "sceneInitialPyrolysisBase" "CUDA reset path reintroduced pre-seeded pyrolysis instead of chemistry-driven ignition"
Require-Text $cuda "p.sceneSourceMode" "CUDA source geometry must consume product source mode"
Require-Text $cuda "p.sceneSourceHeightCeiling" "CUDA source height envelope must consume product source height"
Require-Text $cuda "p.scenePyrolysisGain" "CUDA combustion must consume product pyrolysis coefficients"
Require-Text $cuda "p.sceneSootYieldScale" "CUDA soot yield must consume product soot coefficients"
Require-Text $cuda "p.sceneBuoyancyScale" "CUDA buoyancy must consume product buoyancy coefficients"
Require-Text $cuda "p.sceneFloorGlowR" "CUDA floor bounce color must consume product render coefficients"
Require-Text $cuda "p.sceneOrangeEmissionScale" "CUDA flame emission must consume product render coefficients"
Require-Text $cuda "p.sceneWarmScatter" "CUDA smoke scatter must consume product render coefficients"
Require-Text $runtime "settings.sceneInitialFuelBase = source.initialFuelBase" "scene runtime must copy source material fuel coefficients into FireSettings"
Require-Text $runtime "settings.scenePyrolysisGain = combustion.pyrolysisGain" "scene runtime must copy combustion coefficients into FireSettings"
Require-Text $runtime "settings.sceneOrangeEmissionScale = render.orangeEmissionScale" "scene runtime must copy render coefficients into FireSettings"
Require-Text $runtime "settings.sceneEmberAlphaScale = ember.emberAlphaScale" "scene runtime must copy ember coefficients into FireSettings"
Require-Text $main "applyCameraToSettings(settings)" "interactive settings must use the canonical camera state"
Require-Text $cuda "p.cameraTargetY" "CUDA camera must consume the profile-owned target point"
Require-Text $cuda "p.cameraFovYDegrees" "CUDA camera must consume the profile-owned field of view"

if ($main.Contains("validationScene ==") -or $cuda.Contains("p.sceneId ==")) {
    throw "old non-product scene branches leaked back into the runtime"
}

Write-Host "scene profile contract gate ok"
