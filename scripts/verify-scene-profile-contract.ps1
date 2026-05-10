$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")

$runtimeHeader = Read-RepoText "src/scene_runtime.h"
$runtime = Read-RepoText "src/scene_runtime.cpp"
$sceneRuntime = $runtime
$cuda = Read-RepoText "src/fire_cuda.cu"
$main = Read-RepoText "src/main.cpp"
$burnerAudit = Read-RepoText "scripts/verify-burner-scene.ps1"

Require-Text $runtimeHeader "struct SceneProfile" "canonical scene profile contract is missing"
Require-Text $runtimeHeader "struct SceneValidationEnvelope" "scene validation envelope is missing"
Require-Text $runtimeHeader "struct SceneCudaCoefficients" "scene-owned CUDA coefficient contract is missing"
Require-Text $runtimeHeader "struct SceneSourceCoefficients" "scene source coefficient contract is missing"
Require-Text $runtimeHeader "struct SceneCombustionCoefficients" "scene combustion coefficient contract is missing"
Require-Text $runtimeHeader "struct SceneRenderCoefficients" "scene render coefficient contract is missing"
Require-Text $runtimeHeader "struct SceneEmberCoefficients" "scene ember coefficient contract is missing"
Require-Text $runtimeHeader "sourceMode" "scene profile must own the source-shape selector"
Require-Text $runtime "constexpr SceneProfile kSceneProfiles" "scene profiles must be centralized in scene runtime"
Require-Text $runtime '"selected-gas-burner-ring"' "burner source model must be declared in the scene profile"
Require-Text $runtime '"log-contact-char-bed"' "campfire source model must be declared in the scene profile"
Require-Text $runtime '"tray-fuel-bed"' "room source model must be declared in the scene profile"
Require-Text $main "const SceneProfile& profile = sceneProfile(validationScene)" "validation must consume the canonical scene profile"
Require-Text $main "const SceneValidationEnvelope& envelope = profile.validation" "validation must consume profile-owned envelopes"
Require-Text $main '\"sceneProfile\"' "validation JSON must report the scene profile used for the run"
Forbid-Text $cuda "sceneInitialHeatBase" "CUDA reset path reintroduced pre-seeded heat instead of material-only initial conditions"
Forbid-Text $cuda "sceneInitialPyrolysisBase" "CUDA reset path reintroduced pre-seeded pyrolysis instead of chemistry-driven ignition"
Require-Text $cuda "p.sceneSourceMode" "CUDA source geometry must consume scene-profile source mode"
Require-Text $cuda "p.sceneSourceHeightCeiling" "CUDA source height envelope must consume scene-profile source height"
Require-Text $cuda "p.scenePyrolysisGain" "CUDA combustion must consume scene-profile pyrolysis coefficients"
Require-Text $cuda "p.sceneSootYieldScale" "CUDA soot yield must consume scene-profile soot coefficients"
Require-Text $cuda "p.sceneBuoyancyScale" "CUDA buoyancy must consume scene-profile buoyancy coefficients"
Require-Text $cuda "p.sceneFloorGlowR" "CUDA floor bounce color must consume scene-profile render coefficients"
Require-Text $cuda "p.sceneOrangeEmissionScale" "CUDA flame emission must consume scene-profile render coefficients"
Require-Text $cuda "p.sceneWarmScatter" "CUDA smoke scatter must consume scene-profile render coefficients"
Require-Text $sceneRuntime "settings.sceneInitialFuelBase = source.initialFuelBase" "scene runtime must copy source material fuel coefficients into FireSettings"
Require-Text $sceneRuntime "settings.scenePyrolysisGain = combustion.pyrolysisGain" "scene runtime must copy combustion coefficients into FireSettings"
Require-Text $sceneRuntime "settings.sceneOrangeEmissionScale = render.orangeEmissionScale" "scene runtime must copy render coefficients into FireSettings"
Require-Text $sceneRuntime "settings.sceneEmberAlphaScale = ember.emberAlphaScale" "scene runtime must copy ember coefficients into FireSettings"
Require-Text $burnerAudit "cudaSceneBranchCount" "burner audit must quantify CUDA scene-specific branch pressure"
Require-Text $burnerAudit "biggestBlocker" "burner audit must report the unification blocker"

if ($main.Contains("if (validationScene == 2)")) {
    throw "validation path still hardcodes burner-specific scene branches instead of using SceneProfile"
}
if ($cuda.Contains("scenePyrolysisGain = p.sceneId == 2") -or
    $cuda.Contains("sceneCurlScale = p.sceneId == 2") -or
    $cuda.Contains("if (p.sceneId == 2) {\r\n        return gasBurnerPortEmitter") -or
    $cuda.Contains("const float height = smoothstepf(p.sceneId == 1 ?") -or
    $cuda.Contains("floorGlowColor = p.sceneId == 2") -or
    $cuda.Contains("sceneWarmScatter = p.sceneId == 2") -or
    $cuda.Contains("sootYield = burnMass * (0.035f + incomplete * 0.34f) * p.smokeGain * (p.sceneId == 2")) {
    throw "CUDA hot-path coefficients still use direct sceneId branches instead of SceneProfile coefficients"
}

Write-Host "scene profile contract gate ok"
