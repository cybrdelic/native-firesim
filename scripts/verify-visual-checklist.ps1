$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$main = Read-RepoText "src/main.cpp"
$cuda = Read-RepoText "src/fire_cuda.cu"

Require-Text $main "validation-app-frame.bmp" "validation must still write app-frame captures"
Require-Text $main "imageWarmFireFraction" "validation image statistics must include warm fire fraction"
Require-Text $main "imageBlackSmokeFraction" "validation image statistics must include black smoke fraction"
Require-Text $main "sceneTruthContract" "validation JSON must report the methanol truth contract"
Require-Text $cuda "kNistMethanolMaxSmokeOpticalDepth" "methanol smoke cap must remain active"

Write-Host "visual checklist gate ok"
