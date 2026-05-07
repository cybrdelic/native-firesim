$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$cuda = Get-Content (Join-Path $root "src/fire_cuda.cu") -Raw
$main = Get-Content (Join-Path $root "src/main.cpp") -Raw

function Require-Text($text, $needle, $message) {
    if (-not $text.Contains($needle)) {
        Write-Error $message
    }
}

Require-Text $cuda "blackbodyCoreStructure" "blackbody core structure term is missing"
Require-Text $cuda "hdrShoulderPreserve" "HDR shoulder preservation term is missing"
Require-Text $cuda "blackbodyHighlightLift" "blackbody highlight lift term is missing"
Require-Text $cuda "whiteFilament * whiteFilament * flameDensity * radiantPower" "white filament emission path is missing"
Require-Text $main "imageWhiteCoreFraction" "validation report must expose white-core fraction"
Require-Text $main "imageBrightFraction" "validation report must expose bright-pixel fraction"

Write-Host "blackbody HDR exposure gate ok"
