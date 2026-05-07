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

    Write-Host "roadmap gate: canonical app state"
    & (Join-Path $PSScriptRoot "verify-canonical-app-state.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: worker lifecycle"
    & (Join-Path $PSScriptRoot "verify-worker-lifecycle.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: render architecture"
    & (Join-Path $PSScriptRoot "verify-render-architecture.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: debug overlay system"
    & (Join-Path $PSScriptRoot "verify-debug-overlay-system.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: volume smoke/flame separation"
    & (Join-Path $PSScriptRoot "verify-volume-separation.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    & (Join-Path $PSScriptRoot "verify-neutral-soot-smoke.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    & (Join-Path $PSScriptRoot "verify-blackbody-hdr-exposure.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    & (Join-Path $PSScriptRoot "verify-flame-sheet-breakup.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: lighting architecture"
    & (Join-Path $PSScriptRoot "verify-lighting-architecture.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    & (Join-Path $PSScriptRoot "verify-scene-bounce-lighting.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: scene source models"
    & (Join-Path $PSScriptRoot "verify-scene-source-models.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: room source coverage"
    & (Join-Path $PSScriptRoot "verify-room-source-coverage.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: ember system"
    & (Join-Path $PSScriptRoot "verify-ember-system.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: field ownership"
    & (Join-Path $PSScriptRoot "verify-field-ownership.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: frame pacing"
    & (Join-Path $PSScriptRoot "verify-frame-pacing.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: temporal visual stability"
    & (Join-Path $PSScriptRoot "verify-temporal-visual-stability.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: shared texture ring"
    & (Join-Path $PSScriptRoot "verify-shared-texture-ring.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: kernel hotspot pass"
    & (Join-Path $PSScriptRoot "verify-kernel-hotspot-pass.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: imported scene assets"
    & (Join-Path $PSScriptRoot "verify-scene-assets.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Host "roadmap gate: visual regression audit"
    & (Join-Path $PSScriptRoot "verify-visual-checklist.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    & (Join-Path $PSScriptRoot "verify-before-after-pixel-proof.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    & (Join-Path $PSScriptRoot "verify-scene-silhouette-targets.ps1")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    & (Join-Path $PSScriptRoot "verify-visual-regression.ps1")
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
