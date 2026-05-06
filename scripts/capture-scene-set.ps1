param(
    [int]$Frames = 24,
    [switch]$AcceptBugcheckRisk
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root "build\NativeFireSim.exe"

if (-not (Test-Path -LiteralPath $exe)) {
    throw "NativeFireSim.exe was not found at $exe. Run .\scripts\verify.ps1 -DiagnosticsOnly first."
}

if (-not $AcceptBugcheckRisk) {
    throw "Scene capture uses CUDA validation kernels. Re-run with -AcceptBugcheckRisk after confirming this is an intentional GPU validation run."
}

$scenes = @(
    @{ Name = "room"; Id = 0 },
    @{ Name = "campfire"; Id = 1 },
    @{ Name = "burner"; Id = 2 }
)

$outRoot = Join-Path $root "out\scene-visual-audit"
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

foreach ($scene in $scenes) {
    $outDir = Join-Path $outRoot $scene.Name
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    Write-Host "capturing scene $($scene.Name) -> $outDir"
    & $exe `
        --validation `
        "--scene=$($scene.Id)" `
        "--validation-frames=$Frames" `
        "--output-dir=$outDir" `
        --allow-gpu-kernels `
        --accept-bugcheck-risk
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "scene capture failed for $($scene.Name) with exit code $LASTEXITCODE"
    }
    $framePath = Join-Path $outDir "validation-frame.bmp"
    $appFramePath = Join-Path $outDir "validation-app-frame.bmp"
    if (-not (Test-Path -LiteralPath $framePath) -or -not (Test-Path -LiteralPath $appFramePath)) {
        throw "scene capture for $($scene.Name) did not produce validation-frame.bmp and validation-app-frame.bmp"
    }
}

Write-Host "scene capture set complete: $outRoot"
