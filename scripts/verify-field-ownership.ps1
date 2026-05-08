$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$cuda = Read-RepoText "src/fire_cuda.cu"
$main = Read-RepoText "src/main.cpp"
$diag = Join-Path $root "out\diagnostics\startup.txt"


Require-Text $cuda "enum class FieldOwner" "field ownership enum is missing"
Require-Text $cuda "PhysicalScalar" "physical scalar owner is missing"
Require-Text $cuda "OpticalScalar" "optical scalar owner is missing"
Require-Text $cuda "Velocity" "velocity owner is missing"
Require-Text $cuda "Lighting" "lighting owner is missing"
Require-Text $cuda "struct SnapshotFloatField" "float snapshot ownership table is missing"
Require-Text $cuda "struct SnapshotFloat4Field" "float4 snapshot ownership table is missing"
Require-Text $cuda "struct SnapshotFloatCopy" "snapshot copy table is missing"
Require-Text $cuda "allocateSnapshotFloatFields" "snapshot allocation must use the ownership table"
Require-Text $cuda "copySnapshotFloatFields" "snapshot publish must use the ownership table"
Require-Text $cuda '{"heat", g_renderHeat, scalarBytes, FieldOwner::PhysicalScalar}' "heat must be owned as a physical scalar"
Require-Text $cuda '{"soot optics", g_renderSootOptics, scalarBytes, FieldOwner::OpticalScalar}' "soot optics must be owned as a renderer optical scalar"
Require-Text $cuda '{"u", g_renderU, uBytes, FieldOwner::Velocity}' "u velocity snapshot must be owned as velocity"
Require-Text $cuda '{"scene light", g_renderSceneLight, lightBytes, FieldOwner::Lighting}' "scene light snapshot must be owned as lighting"
Require-Text $main "fieldOwnership=simulation physical scalars, renderer optical scalars, MAC velocity, and lighting snapshots are copied through explicit ownership tables" "diagnostics field ownership string is missing from source"

if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "fieldOwnership=simulation physical scalars, renderer optical scalars, MAC velocity, and lighting snapshots are copied through explicit ownership tables" "diagnostics do not report field ownership"
}

Write-Host "field ownership gate ok"
