param(
    [string]$OutputPath = "out\cuda-artifact-manifest.json"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$exePath = Join-Path $repoRoot "build\NativeFireSim.exe"
if (-not (Test-Path -LiteralPath $exePath)) {
    throw "Missing $exePath. Run .\scripts\verify.ps1 -DiagnosticsOnly first."
}

$cmakeText = Get-Content -LiteralPath (Join-Path $repoRoot "CMakeLists.txt") -Raw
$archLine = if ($cmakeText -match "set\(CMAKE_CUDA_ARCHITECTURES\s+([^)]+)\)") { $Matches[1].Trim() } else { "unknown" }
$nvccVersion = (& nvcc --version 2>$null) -join "`n"
$smiGpu = (& nvidia-smi --query-gpu=driver_version,name --format=csv,noheader 2>$null) -join "`n"
$smiBanner = (& nvidia-smi 2>$null) -join "`n"
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $exePath).Hash.ToLowerInvariant()
$outputFullPath = Join-Path $repoRoot $OutputPath
$outputDir = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$manifest = [ordered]@{
    artifactManifestOk = $true
    generatedAt = (Get-Date).ToUniversalTime().ToString("o")
    artifact = "NativeFireSim.exe"
    artifactPath = $exePath
    artifactSha256 = $hash
    os = "win64"
    cudaArchitectures = $archLine
    requiredImages = @("86-real", "89-real", "90-real", "90-virtual")
    nvccVersion = $nvccVersion
    nvidiaSmiGpu = $smiGpu
    nvidiaSmiBanner = $smiBanner
    loaderPolicy = "prefer native SASS image for matching sm target; retain PTX only as forward-compatible fallback"
}

$manifest | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $outputFullPath
Write-Host "cuda artifact manifest: $outputFullPath"
