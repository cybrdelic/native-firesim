$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$cuda = Read-RepoText "src/fire_cuda.cu"
$main = Read-RepoText "src/main.cpp"
$sceneRuntime = Read-RepoText "src/scene_runtime.cpp"


Require-Text $cuda "floorLift * luminance3(direct) * 0.18f" "floor contact bounce is missing"
Require-Text $cuda "grazingBounce" "grazing bounce boost is missing"
Require-Text $cuda "4.20f * grazingBounce" "gathered scene irradiance boost is missing"
Require-Text $cuda "giSample.x, giSample.y, giSample.z), 0.42f" "local scene light contribution is too low or missing"
Require-Text $cuda "contactWarmth = surface == 1 ? 1.72f" "surface-specific bounce warmth is missing"
Require-Text $cuda "emberBed * glow * 0.26f" "room tray ember-bed bounce is missing"
Require-Text $cuda "floorGlowColor = make_float3(p.sceneFloorGlowR" "burner floor response must come from scene profile coefficients"
Require-Text $cuda "wallGlowColor = make_float3(p.sceneWallGlowR" "burner wall spill must come from scene profile coefficients"
Require-Text $sceneRuntime "settings.sceneFloorGlowR = cuda.floorGlowR" "scene profile floor lighting coefficients must reach FireSettings"
Require-Text $main "length(input.worldPos.xz - MeshLightPos.xz)" "mesh fire bounce is still centered at world origin instead of source position"
Require-Text $main "normalize(MeshLightPos.xyz - input.worldPos)" "mesh fire-facing term is still centered at world origin instead of source position"
Require-Text $main "return float4(color, 1.0)" "gas burner mesh pass must be opaque instead of source-occlusion ghosted"
Require-Text $main "sceneSourceWorld(g_sceneEmitters[scene], g_placement.scene(scene), scene)" "gas burner mesh light must be fed by canonical scene source coordinates"
Require-Text $sceneRuntime "emitter.burnerCenterX[0] + placement.sourceOffset.x" "gas burner mesh light no longer follows selected burner source"
Require-Text $sceneRuntime "emitter.burnerCenterZ[0] + placement.sourceOffset.z" "gas burner mesh light no longer follows selected burner source"
Require-Text $main "lowSource * 0.88" "mesh fire bounce low-source term is missing"
Require-Text $main "material * (0.075 + ndl * 0.34" "mesh ambient lighting must keep imported burner geometry readable"

Write-Host "scene bounce lighting gate ok"
