param(
    [string]$BenchmarkPath = "out\worker-benchmark-final\worker-benchmark.json",
    [string]$SceneSummaryPath = "out\scene-work-test\product-scene-work.json",
    [string]$ProductReportPath = "out\scene-work-test\methanol-pool\validation-report.json"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $qualityPath = Join-Path $root "src\runtime_quality.h"
    $cudaPath = Join-Path $root "src\fire_cuda.cu"
    $mainPath = Join-Path $root "src\main.cpp"

    $quality = Get-Content $qualityPath -Raw
    $cuda = Get-Content $cudaPath -Raw
    $main = Get-Content $mainPath -Raw

    function Require-Text([string]$Haystack, [string]$Needle, [string]$Message) {
        if (-not $Haystack.Contains($Needle)) {
            throw $Message
        }
    }

    function Require-NotText([string]$Haystack, [string]$Needle, [string]$Message) {
        if ($Haystack.Contains($Needle)) {
            throw $Message
        }
    }

    function Read-QualityNumber([string]$Name) {
        $pattern = "constexpr\s+(?:double|float|int)\s+$Name\s*=\s*([0-9.]+)"
        $m = [regex]::Match($quality, $pattern)
        if (-not $m.Success) {
            throw "runtime_quality.h is missing $Name"
        }
        return [double]$m.Groups[1].Value
    }

    $minFps = Read-QualityNumber "kEngineMinWorkerEffectiveFps"
    $maxFrameMs = Read-QualityNumber "kEngineMaxWorkerFrameMs"
    $maxProjectionMs = Read-QualityNumber "kEngineMaxProjectionMs"
    $maxReactionMs = Read-QualityNumber "kEngineMaxReactionMs"
    $maxRaymarchMs = Read-QualityNumber "kEngineMaxRaymarchMs"
    $maxLightingMs = Read-QualityNumber "kEngineMaxLightingMs"
    $minProductMean = Read-QualityNumber "kEngineMinRoomMeanLuma"
    $minProductMax = Read-QualityNumber "kEngineMinRoomMaxLuma"
    $minProductIrradiance = Read-QualityNumber "kEngineMinMeanRoomIrradiance"
    $probeCount = Read-QualityNumber "kRoomIrradianceProbeCount"
    $shadowSteps = Read-QualityNumber "kRoomShadowRaySteps"

    Require-Text $cuda "sceneEmitterWorld" "CUDA product lighting no longer exposes sceneEmitterWorld"
    Require-Text $cuda "sceneEmitterUv" "CUDA product lighting no longer exposes sceneEmitterUv"
    Require-Text $cuda "sceneIrradianceProbeWorld" "CUDA product lighting no longer exposes emitter-relative probes"
    Require-Text $cuda "for (int i = 0; i < kRoomIrradianceProbeCount; ++i)" "product irradiance probe loop is not governed by runtime_quality.h"
    Require-Text $cuda "for (int i = 1; i <= kRoomShadowRaySteps; ++i)" "product shadow ray loop is not governed by runtime_quality.h"
    Require-NotText $cuda "make_float3(0.50f, 0.16f, 0.50f)" "product irradiance is sampling the old hardcoded center source"
    Require-NotText $cuda "make_float3(0.50f, 0.12f, 0.50f)" "product shadow rays are sampling the old hardcoded center source"

    Require-Text $main "enginePerformanceContract" "worker benchmark report is missing enginePerformanceContract"
    Require-Text $main "productLightingContract" "validation report is missing productLightingContract"
    Require-Text $main "enginePerformanceContract=minWorkerEffectiveFps" "diagnostics do not print the performance contract"
    Require-Text $main "productLightingContract=product irradiance probes" "diagnostics do not print the product lighting contract"

    if (Test-Path $BenchmarkPath) {
        $benchmark = Get-Content $BenchmarkPath -Raw | ConvertFrom-Json
        if ($benchmark.workerBenchmarkOk -ne $true) {
            throw "worker benchmark artifact reports workerBenchmarkOk=false"
        }
        if ($benchmark.effectiveFps -lt $minFps) {
            throw "worker benchmark effectiveFps=$($benchmark.effectiveFps) below contract $minFps"
        }
        if ($benchmark.averageFrameMs -gt $maxFrameMs) {
            throw "worker benchmark averageFrameMs=$($benchmark.averageFrameMs) above contract $maxFrameMs"
        }
        if ($benchmark.averageGpuProjectionMs -gt $maxProjectionMs) {
            throw "worker benchmark projection=$($benchmark.averageGpuProjectionMs) above contract $maxProjectionMs"
        }
        if ($benchmark.averageGpuReactionMs -gt $maxReactionMs) {
            throw "worker benchmark reaction=$($benchmark.averageGpuReactionMs) above contract $maxReactionMs"
        }
        if ($benchmark.averageGpuRaymarchMs -gt $maxRaymarchMs) {
            throw "worker benchmark raymarch=$($benchmark.averageGpuRaymarchMs) above contract $maxRaymarchMs"
        }
        if ($benchmark.averageGpuLightingMs -gt $maxLightingMs) {
            throw "worker benchmark lighting=$($benchmark.averageGpuLightingMs) above contract $maxLightingMs"
        }
    }

    if (Test-Path $SceneSummaryPath) {
        $summary = Get-Content $SceneSummaryPath -Raw | ConvertFrom-Json
        if ($summary.productSceneWork -ne $true) {
            throw "scene summary reports productSceneWork=false"
        }
        foreach ($scene in $summary.scenes) {
            if ($scene.validationOk -ne $true) {
                throw "scene $($scene.name) reports validationOk=false"
            }
        }
    }

    if (Test-Path $ProductReportPath) {
        $product = Get-Content $ProductReportPath -Raw | ConvertFrom-Json
        if ($product.validationOk -ne $true) {
            throw "product scene validation report is not ok"
        }
        if ($product.imageMeanLuma -lt $minProductMean) {
            throw "product imageMeanLuma=$($product.imageMeanLuma) below contract $minProductMean"
        }
        if ($product.imageMaxLuma -lt $minProductMax) {
            throw "product imageMaxLuma=$($product.imageMaxLuma) below contract $minProductMax"
        }
        if ($product.finalMeanRoomIrradiance -lt $minProductIrradiance) {
            throw "product finalMeanRoomIrradiance=$($product.finalMeanRoomIrradiance) below contract $minProductIrradiance"
        }
        if ($product.productLightingContract) {
            if ($product.productLightingContract.irradianceProbeCount -ne $probeCount) {
                throw "productLightingContract probe count drifted from runtime_quality.h"
            }
            if ($product.productLightingContract.shadowRaySteps -ne $shadowSteps) {
                throw "productLightingContract shadow step count drifted from runtime_quality.h"
            }
        }
    }

    Write-Host "engine contracts ok"
} finally {
    Pop-Location
}
