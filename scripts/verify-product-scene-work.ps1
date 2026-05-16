param(
    [int]$Frames = 24,
    [switch]$AcceptBugcheckRisk,
    [switch]$SkipCapture
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root "build\NativeFireSim.exe"
$outRoot = Join-Path $root "out\scene-work-test"
$effectiveFrames = $Frames
if (-not $SkipCapture -and $effectiveFrames -lt 24) {
    $effectiveFrames = 24
}

$scenes = @(
    @{ Name = "methanol-pool"; Id = 0; MinMaxLuma = 0.06; MinMeanLuma = 0.006 }
)

if (-not (Test-Path -LiteralPath $exe)) {
    throw "NativeFireSim.exe was not found at $exe. Run .\scripts\verify.ps1 -DiagnosticsOnly first."
}

if ($SkipCapture -and -not (Test-Path -LiteralPath (Join-Path $outRoot "methanol-pool\validation-report.json"))) {
    $outRoot = Join-Path $root "out\scene-visual-audit"
}

New-Item -ItemType Directory -Force -Path $outRoot | Out-Null

if (-not $SkipCapture) {
    if (-not $AcceptBugcheckRisk) {
        throw "Product-scene runtime validation launches CUDA kernels. Re-run with -AcceptBugcheckRisk when intentionally testing the live scene path."
    }
    foreach ($scene in $scenes) {
        $outDir = Join-Path $outRoot $scene.Name
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
        Write-Host "validating product scene $($scene.Name)"
        $arguments = @(
            "--validation",
            "--scene=$($scene.Id)",
            "--validation-frames=$effectiveFrames",
            "--output-dir=$outDir",
            "--allow-gpu-kernels",
            "--accept-bugcheck-risk"
        )
        $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $root -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "product scene $($scene.Name) failed validation run with exit code $($process.ExitCode)"
        }
    }
}

$summary = [ordered]@{
    productSceneWork = $true
    requestedFrames = $Frames
    frames = $effectiveFrames
    outputDir = $outRoot
    scenes = @()
}

foreach ($scene in $scenes) {
    $outDir = Join-Path $outRoot $scene.Name
    $reportPath = Join-Path $outDir "validation-report.json"
    $rawPath = Join-Path $outDir "validation-frame.bmp"
    $appPath = Join-Path $outDir "validation-app-frame.bmp"
    $metricsPath = Join-Path $outDir "validation-metrics.csv"

    foreach ($required in @($reportPath, $rawPath, $appPath, $metricsPath)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "product scene $($scene.Name) did not produce required artifact: $required"
        }
    }

    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $rawSize = (Get-Item -LiteralPath $rawPath).Length
    $appSize = (Get-Item -LiteralPath $appPath).Length
    if ($report.validationOk -ne $true) {
        throw "product scene $($scene.Name) produced validationOk=false"
    }
    if (-not $SkipCapture -and [int]$report.frames -lt $effectiveFrames) {
        throw "product scene $($scene.Name) reported fewer frames than requested"
    }
    if ([double]$report.imageMaxLuma -lt [double]$scene.MinMaxLuma) {
        throw "product scene $($scene.Name) appears too dark or black: imageMaxLuma=$($report.imageMaxLuma)"
    }
    if ([double]$report.imageMeanLuma -lt [double]$scene.MinMeanLuma) {
        throw "product scene $($scene.Name) has near-zero visibility: imageMeanLuma=$($report.imageMeanLuma)"
    }
    if ($rawSize -lt 1024 -or $appSize -lt 1024) {
        throw "product scene $($scene.Name) produced suspiciously small frame output"
    }

    $summary.scenes += [ordered]@{
        name = $scene.Name
        id = $scene.Id
        validationOk = $report.validationOk
        frames = $report.frames
        imageMeanLuma = $report.imageMeanLuma
        imageMaxLuma = $report.imageMaxLuma
        averageGpuSolveMs = $report.averageGpuSolveMs
        averageGpuRenderMs = $report.averageGpuRenderMs
        rawFrame = $rawPath
        appFrame = $appPath
    }
}

$summaryPath = Join-Path $outRoot "product-scene-work.json"
$summary | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $summaryPath
Write-Host "product scene work gate ok: $summaryPath"
