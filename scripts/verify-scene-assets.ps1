param(
    [string]$AssetRoot = "assets\fire-scenes"
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$assetRootFull = Join-Path $repoRoot $AssetRoot
$expected = @(
    @{ Scene = "campfire"; Required = @("geometry.json", "emitter-mask.json") },
    @{ Scene = "gas-burner-aver1"; Required = @("geometry.json", "emitter-mask.json") }
)

$missing = @()
foreach ($entry in $expected) {
    $sceneDir = Join-Path $assetRootFull $entry.Scene
    foreach ($name in $entry.Required) {
        $path = Join-Path $sceneDir $name
        if (-not (Test-Path $path)) {
            $missing += $path
        }
    }
}

if ($missing.Count -gt 0) {
    Write-Host "scene asset check failed: required fire-source metadata is missing"
    foreach ($path in $missing) {
        Write-Host "missing: $path"
    }
    exit 2
}

$meshPayloads = Get-ChildItem -Path $assetRootFull -Recurse -Include *.glb,*.gltf,runtime-mesh.json -File -ErrorAction SilentlyContinue
if ($meshPayloads.Count -gt 0) {
    Write-Host "scene asset check failed: imported GLB/runtime mesh payloads must not be present"
    foreach ($path in $meshPayloads) {
        Write-Host "unexpected: $($path.FullName)"
    }
    exit 2
}

python (Join-Path $PSScriptRoot "verify-scene-contracts.py")
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "scene asset check: fire-source metadata present and GLB payloads absent"
exit 0
