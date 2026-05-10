$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$cuda = Read-RepoText "src/fire_cuda.cu"
$sceneRuntime = Read-RepoText "src/scene_runtime.h"
Require-Text $cuda "roomTraySheet" "room source coverage must add a room-only lower tray sheet term"
Require-Text $cuda "roomCoverageBoost" "room source coverage must boost scene 0 coverage explicitly"
Require-Text $cuda "smoothstepf(1.08f, 0.030f, fabsf(x))" "room tray width must be widened"
Require-Text $cuda "smoothstepf(0.56f, 0.026f, fabsf(z))" "room tray depth must be widened"
Require-Text $sceneRuntime "float initialPyrolysisBase = 0.058f" "room pyrolysis seed must be represented in the scene profile defaults"
Require-Text $cuda "p.sceneInitialPyrolysisBase + chunkNoise * p.sceneInitialPyrolysisNoise" "room pyrolysis seed must flow through scene profile coefficients"
Write-Host "room source coverage gate ok"
