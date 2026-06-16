$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$cuda = Read-RepoText "src/fire_cuda.cu"
$main = Read-RepoText "src/main.cpp"
$diag = Join-Path $root "out\diagnostics\startup.txt"


Require-Text $cuda "const float* charField" "ember kernel must consume the char field"
Require-Text $cuda "const float* pyrolysisField" "ember kernel must consume the pyrolysis field"
Require-Text $cuda "const float* turbulenceEnergyField" "ember kernel must consume the turbulence energy field"
Require-Text $cuda "const float* uField" "ember kernel must consume the velocity u field"
Require-Text $cuda "const float* vField" "ember kernel must consume the velocity v field"
Require-Text $cuda "const float* wField" "ember kernel must consume the velocity w field"
Require-Text $cuda "const float materialGate" "ember spawning must be gated by active material fields"
Require-Text $cuda "const float3 localVelocity = sampleVelocity" "embers must inherit local field velocity"
Require-Text $cuda "const float drag" "embers must model drag"
Require-Text $cuda "const float cooling" "embers must cool over lifetime"
Require-Text $cuda "const float emberSize" "embers must scale from field-derived temperature"
Require-Text $cuda "renderChar," "ember launch must pass the active render char field"
Require-Text $cuda "renderPyrolysis," "ember launch must pass the active render pyrolysis field"
Require-Text $cuda "renderTurbulenceEnergy," "ember launch must pass the active render turbulence field"
Require-Text $cuda "renderU," "ember launch must pass the active render u velocity field"
Require-Text $cuda "renderV," "ember launch must pass the active render v velocity field"
Require-Text $cuda "renderW," "ember launch must pass the active render w velocity field"
Require-Text $main "emberSystem=field-spawned char/pyrolysis particles with local velocity advection, drag, cooling, and lifetimes" "diagnostics ember system string is missing from source"

if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "emberSystem=field-spawned char/pyrolysis particles with local velocity advection, drag, cooling, and lifetimes" "diagnostics do not report the ember system"
}

Write-Host "ember system gate ok"
