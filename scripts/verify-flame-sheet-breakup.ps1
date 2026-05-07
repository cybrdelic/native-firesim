$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$cuda = Get-Content (Join-Path $root "src/fire_cuda.cu") -Raw
$audit = Get-Content (Join-Path $root "scripts/scene_visual_audit.py") -Raw

function Require-Text($text, $needle, $message) {
    if (-not $text.Contains($needle)) {
        Write-Error $message
    }
}

Require-Text $cuda "flameSheetTear" "flame sheet tear term is missing"
Require-Text $cuda "fieldFilament * (1.0f + flameSheetTear" "filament emission must respond to sheet tearing"
Require-Text $cuda "flameFrontMask = saturate(flameDensity * 4.8f" "flame-front mask must favor thin emissive samples"
Require-Text $audit "activeEdgeDensity" "visual audit must report active flame edge density"
Require-Text $audit "activeFragmentCount" "visual audit must report separated flame fragments"
Require-Text $audit "campfire flame sheets are too smooth and under-broken" "campfire smooth-sheet issue is missing"
Require-Text $audit "campfire flame region has too few separated tongues" "campfire tongue-count issue is missing"

Write-Host "flame sheet breakup gate ok"
