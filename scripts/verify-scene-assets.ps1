param(
    [string]$AssetRoot = "assets\fire-scenes"
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$assetRootFull = Join-Path $repoRoot $AssetRoot
$expected = @(
    @{ Scene = "campfire"; Required = @("runtime-mesh.json", "scene.glb", "geometry.json", "emitter-mask.json") },
    @{ Scene = "gas-burner-aver1"; Required = @("runtime-mesh.json", "scene.glb", "geometry.json", "emitter-mask.json") }
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
    Write-Host "scene asset check: built-in native mesh fallback will be used"
    foreach ($path in $missing) {
        Write-Host "missing: $path"
    }
    exit 2
}

Write-Host "scene asset check: real imported runtime meshes present"
exit 0
