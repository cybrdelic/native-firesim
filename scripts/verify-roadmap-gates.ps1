param(
    [switch]$RunGpuKernels,
    [switch]$AcceptBugcheckRisk
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    Write-Host "roadmap gate: diagnostics"
    & (Join-Path $PSScriptRoot "verify.ps1") -DiagnosticsOnly
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: imported scene assets"
    & (Join-Path $PSScriptRoot "verify-scene-assets.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    if ($RunGpuKernels) {
        Write-Host "roadmap gate: gpu validation"
        $args = @("-RunGpuKernels")
        if ($AcceptBugcheckRisk) {
            $args += "-AcceptBugcheckRisk"
        }
        & (Join-Path $PSScriptRoot "verify.ps1") @args
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    } else {
        Write-Host "roadmap gate: gpu validation skipped; pass -RunGpuKernels -AcceptBugcheckRisk to run the risky path"
    }

    Write-Host "roadmap gates ok"
} finally {
    Pop-Location
}
