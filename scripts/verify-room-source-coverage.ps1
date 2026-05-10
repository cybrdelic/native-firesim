$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$cuda = Read-RepoText "src/fire_cuda.cu"
$sceneRuntime = Read-RepoText "src/scene_runtime.h"
Require-Text $cuda "roomTraySheet" "room source coverage must add a room-only lower tray sheet term"
Require-Text $cuda "roomCoverageBoost" "room source coverage must boost scene 0 coverage explicitly"
Require-Text $cuda "smoothstepf(1.08f, 0.030f, fabsf(x))" "room tray width must be widened"
Require-Text $cuda "smoothstepf(0.56f, 0.026f, fabsf(z))" "room tray depth must be widened"
Forbid-Text $sceneRuntime "initialPyrolysisBase" "room profile reintroduced fake reset pyrolysis seeds"
Forbid-Text $cuda "sceneInitialPyrolysisBase" "room reset path reintroduced fake pyrolysis fields"
Require-Text $cuda "heat[idx] = 0.0f;" "room reset must start from material and oxygen, not visible pre-seeded heat"
Require-Text $cuda "pyrolysis[idx] = 0.0f;" "room reset must let pyrolysis emerge through chemistry"
Write-Host "room source coverage gate ok"
