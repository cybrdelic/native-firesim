$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$cuda = Get-Content (Join-Path $root "src/fire_cuda.cu") -Raw
$audit = Get-Content (Join-Path $root "scripts/scene_visual_audit.py") -Raw

function Require-Text($text, $needle, $message) {
    if (-not $text.Contains($needle)) {
        Write-Error $message
    }
}

Require-Text $cuda "upperSootNeutrality" "upper soot neutralization term is missing"
Require-Text $cuda "nearFlameWarmLeak" "near-flame warm leakage limiter is missing"
Require-Text $cuda "sceneWarmScatter = p.sceneId == 2 ? 0.010f : (p.sceneId == 1 ? 0.18f : 0.30f)" "scene warm smoke scatter must stay bounded"
Require-Text $cuda "make_float3(0.010f, 0.012f, 0.016f)" "back-scatter smoke tint must remain cool-neutral"
Require-Text $cuda "make_float3(localIrradianceLuma * 0.052f, localIrradianceLuma * 0.064f, localIrradianceLuma * 0.086f)" "neutral smoke scatter light is missing"
Require-Text $audit "excessive warm/sepia smoke pixels" "visual audit must still check warm sepia smoke"

Write-Host "neutral soot smoke gate ok"
