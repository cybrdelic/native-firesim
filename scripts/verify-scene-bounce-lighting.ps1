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
Require-Text $main "lowSource * 0.66" "mesh fire bounce low-source term is missing"
Require-Text $main "material * (0.038 + ndl * 0.24" "mesh ambient lighting must not dominate fire bounce"

Write-Host "scene bounce lighting gate ok"
