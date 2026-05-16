param(
    [string]$AssetRoot = "assets\fire-scenes"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$assetRootFull = Join-Path $repoRoot $AssetRoot
$productScene = Join-Path $assetRootFull "methanol-pool"
$scenePath = Join-Path $productScene "scene.json"

if (-not (Test-Path -LiteralPath $scenePath)) {
    throw "missing methanol product scene contract: $scenePath"
}

$sceneDirs = Get-ChildItem -LiteralPath $assetRootFull -Directory
foreach ($dir in $sceneDirs) {
    if ($dir.Name -ne "methanol-pool") {
        throw "non-product scene asset still present: $($dir.FullName)"
    }
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

Write-Host "scene asset check: only methanol product scene is present"
exit 0
