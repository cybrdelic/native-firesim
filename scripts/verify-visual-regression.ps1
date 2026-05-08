param(
    [switch]$Capture,
    [switch]$AcceptBugcheckRisk
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if ($Capture) {
        & (Join-Path $PSScriptRoot "capture-scene-set.ps1") -AcceptBugcheckRisk:$AcceptBugcheckRisk
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }

    python (Join-Path $PSScriptRoot "scene_visual_audit.py")
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    Write-Host "visual regression gate ok"
} finally {
    Pop-Location
}
