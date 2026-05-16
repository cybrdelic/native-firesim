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
Require-Text $cuda "emberBed * glow * 0.26f" "methanol ember-bed bounce is missing"
Require-Text $cuda "floorGlowColor = make_float3(p.sceneFloorGlowR" "methanol floor response must come from product profile coefficients"
Require-Text $cuda "wallGlowColor = make_float3(p.sceneWallGlowR" "methanol wall spill must come from product profile coefficients"
Require-Text $sceneRuntime "settings.sceneFloorGlowR = render.floorGlowR" "scene profile floor lighting coefficients must reach FireSettings"
Require-Text $sceneRuntime "settings.sceneWallGlowR = render.wallGlowR" "scene profile wall lighting coefficients must reach FireSettings"
Require-Text $main "meshLightingPass=removed; fire scenes are CUDA volumes without imported GLB geometry" "scene bounce gate still expects removed GLB mesh lighting to stay removed"
Require-Text $main "sceneSourceWorld(g_sceneEmitters[scene], g_placement.scene(scene), scene)" "methanol light must be fed by canonical source coordinates"
Require-Text $sceneRuntime "emitter.centerX + placement.sourceOffset.x" "methanol source x no longer follows canonical placement"
Require-Text $sceneRuntime "emitter.centerZ + placement.sourceOffset.z" "methanol source z no longer follows canonical placement"
Require-Text $main "productLightingLayer=methanol floor/wall response receives flame-fed irradiance gated by volumetric shadow and material albedo" "scene bounce lighting must stay in the CUDA product lighting layer"

Write-Host "scene bounce lighting gate ok"
