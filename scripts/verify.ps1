param(
    [switch]$DiagnosticsOnly,
    [switch]$RunGpuKernels,
    [switch]$AcceptBugcheckRisk
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$vcvars = "C:\VSBuildTools\VC\Auxiliary\Build\vcvars64.bat"

& (Join-Path $PSScriptRoot "lint.ps1")
& (Join-Path $PSScriptRoot "verify-architecture-boundaries.ps1")
& (Join-Path $PSScriptRoot "verify-lab-grade.ps1")

if (-not (Test-Path -LiteralPath $vcvars)) {
    throw "Visual Studio Build Tools were not found at $vcvars"
}

$buildCommand = "`"$vcvars`" && cmake -S `"$root`" -B `"$root\build`" -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build `"$root\build`" --config Release"
cmd.exe /c $buildCommand
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

function Invoke-NativeFireSimCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutMs = 120000
    )

    $process = Start-Process -FilePath ".\build\NativeFireSim.exe" -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit($TimeoutMs)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "NativeFireSim timed out while running: $($Arguments -join ' ')"
    }
    return $process.ExitCode
}

Push-Location $root
try {
    $diagCode = Invoke-NativeFireSimCheck -Arguments @("--diagnostics")

    $inputCode = Invoke-NativeFireSimCheck -Arguments @("--input-stress-test")

    if ($DiagnosticsOnly -or -not $RunGpuKernels) {
        $smokeCode = 0
        $validationCode = 0
    } else {
        $riskAccepted = $AcceptBugcheckRisk -or $env:FIRESIM_ACCEPT_BUGCHECK_RISK -eq "1"
        if (-not $riskAccepted) {
            throw "GPU kernel verification is blocked because recent runs caused Windows bugchecks. Re-run with -AcceptBugcheckRisk only if you intentionally want to test that driver path."
        }
        $smokeCode = Invoke-NativeFireSimCheck -Arguments @("--smoke-test", "--allow-gpu-kernels", "--accept-bugcheck-risk") -TimeoutMs 300000
        & (Join-Path $PSScriptRoot "run-nist-calibration.ps1") -RunGpuKernels -AcceptBugcheckRisk -SkipBuild
        $validationCode = $LASTEXITCODE
    }
} finally {
    Pop-Location
}

if ($diagCode -ne 0) {
    Write-Error "Diagnostics failed with exit code $diagCode"
    exit $diagCode
}
if ($inputCode -ne 0) {
    Write-Error "Input stress test failed with exit code $inputCode"
    exit $inputCode
}
if ($smokeCode -ne 0) {
    Write-Error "CUDA smoke test failed with exit code $smokeCode"
    exit $smokeCode
}
if ($validationCode -ne 0) {
    Write-Error "CUDA validation failed with exit code $validationCode"
    exit $validationCode
}

Write-Host "verify ok"
