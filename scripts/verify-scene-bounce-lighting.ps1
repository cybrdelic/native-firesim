$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$cuda = Read-RepoText "src/fire_cuda.cu"
$main = Read-RepoText "src/main.cpp"


Require-Text $cuda "floorLift * luminance3(direct) * 0.18f" "floor contact bounce is missing"
Require-Text $cuda "grazingBounce" "grazing bounce boost is missing"
Require-Text $cuda "4.20f * grazingBounce" "gathered scene irradiance boost is missing"
Require-Text $cuda "giSample.x, giSample.y, giSample.z), 0.42f" "local scene light contribution is too low or missing"
Require-Text $cuda "contactWarmth = surface == 1 ? 1.72f" "surface-specific bounce warmth is missing"
Require-Text $cuda "emberBed * glow * 0.26f" "room tray ember-bed bounce is missing"
Require-Text $cuda "floorGlowColor = p.sceneId == 2 ? make_float3(0.030f, 0.12f, 0.44f)" "burner floor response must be blue and scene-specific"
Require-Text $cuda "wallGlowColor = p.sceneId == 2 ? make_float3(0.020f, 0.060f, 0.18f)" "burner wall spill must be blue and scene-specific"
Require-Text $main "length(input.worldPos.xz - MeshLightPos.xz)" "mesh fire bounce is still centered at world origin instead of source position"
Require-Text $main "normalize(MeshLightPos.xyz - input.worldPos)" "mesh fire-facing term is still centered at world origin instead of source position"
Require-Text $main "return float4(color, 1.0)" "gas burner mesh pass must be opaque instead of source-occlusion ghosted"
Require-Text $main "emitter.burnerCenterX[0]" "gas burner mesh light no longer follows selected burner source"
Require-Text $main "emitter.burnerCenterZ[0]" "gas burner mesh light no longer follows selected burner source"
Require-Text $main "lowSource * 0.88" "mesh fire bounce low-source term is missing"
Require-Text $main "material * (0.075 + ndl * 0.34" "mesh ambient lighting must keep imported burner geometry readable"

Write-Host "scene bounce lighting gate ok"
