$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$cuda = Get-Content (Join-Path $root "src/fire_cuda.cu") -Raw
$main = Get-Content (Join-Path $root "src/main.cpp") -Raw
$diag = Join-Path $root "out\diagnostics\startup.txt"

function Require-Text($text, $needle, $message) {
    if (-not $text.Contains($needle)) {
        Write-Error $message
    }
}

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
Require-Text $cuda "g_renderChar[renderSlot]" "ember launch must pass the render char snapshot"
Require-Text $cuda "g_renderPyrolysis[renderSlot]" "ember launch must pass the render pyrolysis snapshot"
Require-Text $cuda "g_renderTurbulenceEnergy[renderSlot]" "ember launch must pass the render turbulence snapshot"
Require-Text $cuda "g_renderU[renderSlot]" "ember launch must pass the render u velocity snapshot"
Require-Text $cuda "g_renderV[renderSlot]" "ember launch must pass the render v velocity snapshot"
Require-Text $cuda "g_renderW[renderSlot]" "ember launch must pass the render w velocity snapshot"
Require-Text $main "emberSystem=field-spawned char/pyrolysis particles with local velocity advection, drag, cooling, and lifetimes" "diagnostics ember system string is missing from source"

if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "emberSystem=field-spawned char/pyrolysis particles with local velocity advection, drag, cooling, and lifetimes" "diagnostics do not report the ember system"
}

Write-Host "ember system gate ok"
