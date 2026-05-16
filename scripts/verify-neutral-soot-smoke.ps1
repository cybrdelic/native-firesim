$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$cuda = Read-RepoText "src/fire_cuda.cu"

Require-Text $cuda "upperSootNeutrality" "upper soot neutralization term is missing"
Require-Text $cuda "nearFlameWarmLeak" "near-flame warm leakage limiter is missing"
Require-Text $cuda "sceneWarmScatter = p.sceneWarmScatter" "methanol warm smoke scatter must come from product profile coefficients"
Require-Text $cuda "p.sceneSmokeScale" "methanol smoke density scale must come from product profile coefficients"
Require-Text $cuda "make_float3(0.010f, 0.012f, 0.016f)" "back-scatter smoke tint must remain cool-neutral"
Require-Text $cuda "make_float3(localIrradianceLuma * 0.052f, localIrradianceLuma * 0.064f, localIrradianceLuma * 0.086f)" "neutral smoke scatter light is missing"

Write-Host "neutral soot smoke gate ok"
