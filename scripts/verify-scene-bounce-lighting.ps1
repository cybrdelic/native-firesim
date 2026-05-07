$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$cuda = Get-Content (Join-Path $root "src/fire_cuda.cu") -Raw
$main = Get-Content (Join-Path $root "src/main.cpp") -Raw

function Require-Text($text, $needle, $message) {
    if (-not $text.Contains($needle)) {
        Write-Error $message
    }
}

Require-Text $cuda "floorLift * luminance3(direct) * 0.18f" "floor contact bounce is missing"
Require-Text $cuda "grazingBounce" "grazing bounce boost is missing"
Require-Text $cuda "4.20f * grazingBounce" "gathered scene irradiance boost is missing"
Require-Text $cuda "giSample.x, giSample.y, giSample.z), 0.42f" "local scene light contribution is too low or missing"
Require-Text $cuda "contactWarmth = surface == 1 ? 1.72f" "surface-specific bounce warmth is missing"
Require-Text $cuda "emberBed * glow * 0.26f" "room tray ember-bed bounce is missing"
Require-Text $cuda "reflectCore * p.reflectionGain * 0.48f" "floor reflected fire core response is missing"
Require-Text $cuda "wallGlow * 0.090f" "wall fire spill response is missing"
Require-Text $main "length(input.worldPos.xz - MeshLightPos.xz)" "mesh fire bounce is still centered at world origin instead of source position"
Require-Text $main "normalize(MeshLightPos.xyz - input.worldPos)" "mesh fire-facing term is still centered at world origin instead of source position"
Require-Text $main "sourceOcclusionRelief = sourceFalloff * MeshFireParams.w * 0.62" "gas burner mesh pass still occludes the selected source opening"
Require-Text $main "emitter.burnerCenterX[0]" "gas burner mesh light no longer follows selected burner source"
Require-Text $main "emitter.burnerCenterZ[0]" "gas burner mesh light no longer follows selected burner source"
Require-Text $main "lowSource * 0.66" "mesh fire bounce low-source term is missing"
Require-Text $main "material * (0.038 + ndl * 0.24" "mesh ambient lighting must not dominate fire bounce"

Write-Host "scene bounce lighting gate ok"
