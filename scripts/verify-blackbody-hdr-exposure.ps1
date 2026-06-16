$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$cuda = Read-RepoText "src/fire_cuda.cu"
$main = Read-RepoText "src/main.cpp"


Require-Text $cuda "blackbodyCoreStructure" "blackbody core structure term is missing"
Require-Text $cuda "hdrShoulderPreserve" "HDR shoulder preservation term is missing"
Require-Text $cuda "blackbodyHighlightLift" "blackbody highlight lift term is missing"
Require-Text $cuda "whiteFilament * whiteFilament * flameDensity * radiantPower" "white filament emission path is missing"
Require-Text $main "imageWhiteCoreFraction" "validation report must expose white-core fraction"
Require-Text $main "imageBrightFraction" "validation report must expose bright-pixel fraction"

Write-Host "blackbody HDR exposure gate ok"
