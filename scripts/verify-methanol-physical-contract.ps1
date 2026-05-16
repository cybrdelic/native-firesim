param(
    [switch]$SkipDiagnostics
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")

$quality = Read-RepoText "src\runtime_quality.h"
$header = Read-RepoText "src\fire_cuda.h"
$cuda = Read-RepoText "src\fire_cuda.cu"
$sceneRuntime = Read-RepoText "src\scene_runtime.cpp"
$main = Read-RepoText "src\main.cpp"
$manifest = Read-RepoText "benchmarks\nist-fcd\methanol-1m-pool-r1\manifest.json"
$targets = Read-RepoText "benchmarks\nist-fcd\methanol-1m-pool-r1\validation-targets.csv"

Require-Text $quality "kNistMethanolPoolDiameterMeters" "NIST methanol pool diameter constant is missing"
Require-Text $quality "kNistMethanolInitialFuelMassKg" "NIST methanol initial fuel mass constant is missing"
Require-Text $quality "kNistMethanolMeasuredMassBurnRateGps" "NIST methanol measured mass-burn-rate constant is missing"
Require-Text $quality "kNistMethanolHeatOfCombustionMjPerKg" "NIST methanol heat of combustion constant is missing"
Require-Text $quality "kNistMethanolRadiativeFraction" "NIST methanol radiative fraction constant is missing"
Require-Text $quality "kNistMethanolSootYieldKgPerKg" "NIST methanol soot-yield constant is missing"
Require-Text $quality "kNistMethanolStoichOxygenFuelMassRatio" "NIST methanol stoichiometric oxygen demand is missing"
Require-Text $quality "kNistMethanolMaxSmokeOpticalDepth" "NIST methanol low-smoke optical-depth gate is missing"
Require-Text $quality "kNistMethanolMaxHrrShapeRmse" "NIST methanol HRR truth gate is missing"
Require-Text $quality "kNistMethanolMaxAverageRenderMs" "NIST methanol render-time truth gate is missing"
Require-Text $quality "kNistMethanolMinBrightPixels" "NIST methanol visible-fire truth gate is missing"

Require-Text $header "sceneStoichOxygenFuelMassRatio" "FireSettings no longer carries scene stoichiometry into CUDA"
Require-Text $header "sceneHeatOfCombustionProxy" "FireSettings no longer carries scene heat-of-combustion proxy into CUDA"
Require-Text $header "sceneRadiativeFraction" "FireSettings no longer carries scene radiative fraction into CUDA"
Require-Text $header "sceneTargetMassBurnRateGps" "FireSettings no longer carries target mass-burn rate into CUDA"
Require-Text $header "sceneMeasuredSootYield" "FireSettings no longer carries measured soot yield into CUDA"
Require-Text $header "sceneAmbientTemperatureK" "FireSettings no longer carries ambient temperature into CUDA"

Require-Text $sceneRuntime "c.source.sourceMode = 3" "methanol pool must use liquid pool source mode"
Require-Text $sceneRuntime "c.combustion.stoichOxygenFuelMassRatio = kNistMethanolStoichOxygenFuelMassRatio" "methanol scene profile is not wired to NIST stoichiometry"
Require-Text $sceneRuntime "c.combustion.heatOfCombustionProxy = kNistMethanolHeatOfCombustionMjPerKg" "methanol scene profile is not wired to NIST heat of combustion"
Require-Text $sceneRuntime "c.combustion.radiativeFraction = kNistMethanolRadiativeFraction" "methanol scene profile is not wired to NIST radiative fraction"
Require-Text $sceneRuntime "c.combustion.targetMassBurnRateGps = kNistMethanolMeasuredMassBurnRateGps" "methanol scene profile is not wired to NIST mass-burn rate"
Require-Text $sceneRuntime "c.combustion.measuredSootYield = kNistMethanolSootYieldKgPerKg" "methanol scene profile is not wired to NIST soot yield"
Require-Text $sceneRuntime "c.combustion.ambientTemperatureK = kNistMethanolAmbientTemperatureK" "methanol scene profile is not wired to NIST ambient temperature"
Require-Text $sceneRuntime "settings.sceneStoichOxygenFuelMassRatio = combustion.stoichOxygenFuelMassRatio" "scene stoichiometry is not applied to FireSettings"

Require-Text $cuda "oxygen / stoichOxygenFuelMassRatio" "CUDA reaction is not oxygen-limited by scene stoichiometry"
Require-Text $cuda "p.sceneHeatOfCombustionProxy" "CUDA heat release does not consume scene heat-of-combustion proxy"
Require-Text $cuda "p.sceneRadiativeFraction" "CUDA heat release does not consume scene radiative fraction"
Require-Text $cuda "p.sceneMeasuredSootYield" "CUDA soot yield does not consume measured soot yield"
Require-Text $cuda "p.sceneTargetMassBurnRateGps / kNistMethanolMeasuredMassBurnRateGps" "CUDA HRR metric is not normalized by the measured methanol burn rate"
Require-Text $cuda "kNistMethanolMaxSmokeOpticalDepth" "CUDA methanol smoke cap is missing"
Require-Text $cuda "params.sceneSourcePlaneMode = std::max(0.0f, std::min(2.0f, settings.sceneSourcePlaneMode))" "methanol source plane mode is clamped below its authored value"
Require-Text $cuda "params.sceneEmberSpawnMode = std::max(0.0f, std::min(3.0f, settings.sceneEmberSpawnMode))" "methanol ember spawn mode is clamped below its authored value"
Forbid-Text $cuda "oxygen * 1.42f" "generic oxygen multiplier reintroduced into combustion limiter"

Require-Text $main "methanolPhysicalContract" "validation/diagnostics do not emit the methanol physical contract"
Require-Text $main "NIST methanol pool uses measured mass-burn rate" "diagnostics combustion model does not distinguish measured methanol calibration"
Require-Text $manifest "NIST_FCD_Methanol_1m_Pool_R1" "NIST methanol manifest is missing"
Require-Text $manifest "hrrKW" "NIST methanol manifest no longer declares HRR"
Require-Text $manifest "massRemainingKg" "NIST methanol manifest no longer declares derived fuel mass"
Require-Text $manifest "radiantHeatFluxKWPerM2" "NIST methanol manifest no longer declares radiant heat flux"
Require-Text $manifest "smokeOpticalDepth" "NIST methanol manifest no longer declares smoke optical depth"
Require-Text $targets "calibrationHrrShapeRmse" "methanol target envelope no longer checks HRR shape"
Require-Text $targets "calibrationMassShapeRmse" "methanol target envelope no longer checks fuel mass shape"
Require-Text $targets "calibrationSmokeOpticalDepthShapeRmse" "methanol target envelope no longer checks smoke optical depth"
Require-Text $targets "calibrationRadiantHeatFluxShapeRmse" "methanol target envelope no longer checks radiant heat flux"
Require-Text $targets "averageGpuRaymarchMs,0.00,18.00" "methanol target envelope no longer checks raymarch performance"
Require-Text $targets "imageBrightPixels,256.00,999999.00" "methanol target envelope no longer checks visible fire brightness"
Require-Text $targets "imageWhiteCoreFraction,0.00010,0.05000" "methanol target envelope no longer checks white-hot core structure"
Require-Text $targets "maxFlameHeightMeters,0.20,1.10" "methanol target envelope no longer checks NIST pool flame height"
Require-Text $main "sceneTruthContract" "validation JSON no longer emits the methanol truth contract"
Require-Text $main "stable = stable && methanolTruthContractOk" "NIST methanol validation no longer fails on the truth contract"

if (-not $SkipDiagnostics) {
    $diagPath = Join-Path $script:RepoRoot "out\diagnostics.txt"
    if (-not (Test-Path -LiteralPath $diagPath)) {
        throw "missing out\diagnostics.txt; run .\scripts\verify.ps1 -DiagnosticsOnly first or pass -SkipDiagnostics"
    }
    $diag = Get-Content -LiteralPath $diagPath -Raw
    Require-Text $diag "methanolPhysicalContract=poolDiameterM" "diagnostics do not report the methanol physical contract"
}

Write-Host "methanol physical contract ok"
