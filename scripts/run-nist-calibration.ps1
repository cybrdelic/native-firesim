param(
    [string]$ManifestPath = "",
    [string]$OutputDir = "",
    [int]$Frames = 96,
    [switch]$PlanOnly,
    [switch]$RunGpuKernels,
    [switch]$AcceptBugcheckRisk,
    [switch]$SkipBuild,
    [switch]$SkipPlots
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $root "benchmarks\nist-fcd\methanol-1m-pool-r1\manifest.json"
}
$ManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$manifestDir = Split-Path -Parent $ManifestPath
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$experimentId = [string]$manifest.experimentId
if ([string]::IsNullOrWhiteSpace($experimentId)) {
    throw "Manifest is missing experimentId: $ManifestPath"
}
$safeExperimentId = $experimentId -replace "[^A-Za-z0-9_.-]", "-"

function Resolve-ManifestFile {
    param([string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return ""
    }
    if ([IO.Path]::IsPathRooted($RelativePath)) {
        return $RelativePath
    }
    return Join-Path $manifestDir $RelativePath
}

$geometryPath = Resolve-ManifestFile ([string]$manifest.files.geometry)
$calibrationPath = Resolve-ManifestFile ([string]$manifest.files.calibrationCsv)
$targetPath = ""
if ($manifest.files.PSObject.Properties.Name -contains "targetEnvelopeCsv") {
    $targetPath = Resolve-ManifestFile ([string]$manifest.files.targetEnvelopeCsv)
}
if ([string]::IsNullOrWhiteSpace($targetPath)) {
    $candidate = Join-Path $manifestDir "validation-targets.csv"
    if (Test-Path -LiteralPath $candidate) {
        $targetPath = $candidate
    }
}
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $root ("out\validation\" + $safeExperimentId)
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

& (Join-Path $PSScriptRoot "verify-lab-grade.ps1") `
    -RequireRealDataset `
    -GeometryPath $geometryPath `
    -CalibrationCsvPath $calibrationPath `
    -ManifestPath $ManifestPath

if (-not $RunGpuKernels) {
    $plan = [pscustomobject]@{
        experimentId = $experimentId
        manifestPath = $ManifestPath
        geometryPath = $geometryPath
        calibrationCsvPath = $calibrationPath
        targetEnvelopePath = $targetPath
        outputDir = $OutputDir
        readyToRunCuda = $false
        reason = "Live CUDA validation is blocked unless -RunGpuKernels -AcceptBugcheckRisk is supplied."
    }
    $plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDir "calibration-run-plan.json") -Encoding UTF8
    if ($PlanOnly) {
        Write-Host "NIST calibration run plan written: $(Join-Path $OutputDir "calibration-run-plan.json")"
        exit 0
    }
    throw "NIST calibration runner is staged, but live CUDA kernels were not launched. Re-run with -RunGpuKernels -AcceptBugcheckRisk to produce sim-vs-measured outputs."
}

$riskAccepted = $AcceptBugcheckRisk -or $env:FIRESIM_ACCEPT_BUGCHECK_RISK -eq "1"
if (-not $riskAccepted) {
    throw "GPU kernel validation is blocked because recent runs caused Windows bugchecks. Re-run with -AcceptBugcheckRisk only if you intentionally want to test that driver path."
}

if (-not $SkipBuild) {
    $vcvars = "C:\VSBuildTools\VC\Auxiliary\Build\vcvars64.bat"
    if (-not (Test-Path -LiteralPath $vcvars)) {
        throw "Visual Studio Build Tools were not found at $vcvars"
    }
    $buildCommand = "`"$vcvars`" && cmake -S `"$root`" -B `"$root\build`" -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build `"$root\build`" --config Release"
    cmd.exe /c $buildCommand
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$nativeExe = Join-Path $root "build\NativeFireSim.exe"
if (-not (Test-Path -LiteralPath $nativeExe)) {
    throw "NativeFireSim.exe was not found at $nativeExe"
}

$nativeArgs = @(
    "--validation",
    "--manifest=$ManifestPath",
    "--dataset-id=$experimentId",
    "--calibration=$calibrationPath",
    "--geometry=$geometryPath",
    "--output-dir=$OutputDir",
    "--validation-frames=$Frames",
    "--scene=0",
    "--pool-fire-calibration",
    "--allow-gpu-kernels",
    "--accept-bugcheck-risk"
)
if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
    $nativeArgs += "--targets=$targetPath"
}

Push-Location $root
try {
    $nativeProcess = Start-Process -FilePath $nativeExe -ArgumentList $nativeArgs -PassThru -Wait -WindowStyle Hidden
    $nativeExit = $nativeProcess.ExitCode
} finally {
    Pop-Location
}
if ($nativeExit -ne 0) {
    Write-Warning "NativeFireSim NIST calibration validation returned exit code $nativeExit. Building any available comparison artifacts before failing."
}

if (-not $SkipPlots -and
    (Test-Path -LiteralPath (Join-Path $OutputDir "calibration-comparison.csv")) -and
    (Test-Path -LiteralPath (Join-Path $OutputDir "validation-report.json"))) {
    & python (Join-Path $PSScriptRoot "build_calibration_report.py") --output-dir $OutputDir --manifest $ManifestPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$truthGate = Join-Path $PSScriptRoot "verify-methanol-truth-gate.ps1"
$reportPath = Join-Path $OutputDir "validation-report.json"
if (Test-Path -LiteralPath $reportPath) {
    try {
        & $truthGate -ReportPath $reportPath
    } catch {
        if ($nativeExit -eq 0) {
            throw
        }
        Write-Warning $_.Exception.Message
    }
}

if ($nativeExit -ne 0) {
    throw "NativeFireSim NIST calibration validation failed with exit code $nativeExit. See $OutputDir"
}

Write-Host "NIST CUDA calibration complete: $OutputDir"
