param(
    [string]$ReportPath = "out\validation\NIST_FCD_Methanol_1m_Pool_R1\validation-report.json",
    [switch]$StaticOnly
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")

$targets = Read-RepoText "benchmarks/nist-fcd/methanol-1m-pool-r1/validation-targets.csv"
Require-Text $targets "finalMeanRoomIrradiance" "methanol truth gate target is missing mean irradiance"
Require-Text $targets "maxFlameHeightMeters" "methanol truth gate target is missing flame height"
Require-Text $targets "calibrationSmokeOpticalDepthShapeRmse" "methanol truth gate target is missing smoke optical depth"

if ($StaticOnly) {
    Write-Host "methanol truth gate static contract ok"
    return
}

$resolvedReportPath = Join-Path $script:RepoRoot $ReportPath
if (-not (Test-Path -LiteralPath $resolvedReportPath)) {
    throw "methanol truth gate report is missing: $resolvedReportPath"
}

$report = Get-Content -LiteralPath $resolvedReportPath -Raw | ConvertFrom-Json
if ($report.sceneProfile.key -ne "methanol-pool") {
    throw "truth gate report is not for methanol-pool"
}
if ($report.validationOk -ne $true) {
    throw "methanol truth gate failed: validationOk=false"
}

Write-Host "methanol truth gate ok"
