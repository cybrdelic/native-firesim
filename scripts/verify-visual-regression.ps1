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

    $report = Join-Path $root "out\validation\NIST_FCD_Methanol_1m_Pool_R1\validation-report.json"
    if (Test-Path -LiteralPath $report) {
        $json = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        if ($json.sceneProfile.key -ne "methanol-pool") {
            throw "visual regression report is not for methanol-pool"
        }
    }
    Write-Host "visual regression gate ok"
} finally {
    Pop-Location
}
