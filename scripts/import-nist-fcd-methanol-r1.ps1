param(
    [string]$OutputRoot = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $root "benchmarks\nist-fcd\methanol-1m-pool-r1"
}

$rawDir = Join-Path $OutputRoot "raw"
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

$sourceUrl = "https://www.nist.gov/fcd-s3?path=%2FHRR%2FASSET_FILES%2FMethanolPoolFire%2Fdata%2F1539886448_Methanol_1m_Pool_R1.csv"
$pageUrl = "https://www.nist.gov/el/fcd/characteristics-1-m-methanol-pool-fire/methanol1mpoolr1"
$licenseUrl = "https://www.nist.gov/open/license"
$rawPath = Join-Path $rawDir "Methanol_1m_Pool_R1.csv"
$calibrationPath = Join-Path $OutputRoot "calibration.csv"
$geometryPath = Join-Path $OutputRoot "geometry.json"
$manifestPath = Join-Path $OutputRoot "manifest.json"
$readmePath = Join-Path $OutputRoot "README.md"
$culture = [Globalization.CultureInfo]::InvariantCulture

function Format-Number {
    param([double]$Value)
    return $Value.ToString("0.##########", $culture)
}

function Get-ClampedNumber {
    param(
        [object]$Value,
        [double]$Minimum = 0.0
    )
    $parsed = [double]::Parse([string]$Value, [Globalization.NumberStyles]::Float, $culture)
    return [Math]::Max($Minimum, $parsed)
}

if ($Force -or -not (Test-Path -LiteralPath $rawPath)) {
    Invoke-WebRequest -Uri $sourceUrl -OutFile $rawPath
}

$rawRows = @(Import-Csv -LiteralPath $rawPath)
$durationSeconds = 48.82 * 60.0
$totalHeatReleasedMJ = 753.0
$totalFuelMassBurnedKg = 37.8
$lowerHeatingValueKJPerKg = 19920.0

$filteredRows = @(
    foreach ($row in $rawRows) {
        $timeSeconds = [double]::Parse([string]$row.'Time (s)', [Globalization.NumberStyles]::Float, $culture)
        if ($timeSeconds -ge 0.0 -and $timeSeconds -le $durationSeconds) {
            $row
        }
    }
)

if ($filteredRows.Count -lt 10) {
    throw "Downloaded NIST FCD CSV did not contain enough post-ignition rows."
}

$csvLines = New-Object System.Collections.Generic.List[string]
$csvLines.Add("timeSeconds,hrrKW,massRemainingKg,ngBurnerHrrKW,exhaustMassFlowKgPerS,oxygenVolumeFraction,co2VolumeFraction,coVolumeFraction,radiantHeatFluxKWPerM2,smokeExtinctionCoefficientPerM,smokeOpticalDepth") | Out-Null

$cumulativeHeatMJ = 0.0
$previousTimeSeconds = $null
$previousHrrKW = $null
foreach ($row in $filteredRows) {
    $timeSeconds = [double]::Parse([string]$row.'Time (s)', [Globalization.NumberStyles]::Float, $culture)
    $hrrKW = Get-ClampedNumber $row.'Heat Release Rate (kW)'
    if ($null -ne $previousTimeSeconds) {
        $deltaSeconds = $timeSeconds - $previousTimeSeconds
        if ($deltaSeconds -gt 0.0) {
            $cumulativeHeatMJ += (($previousHrrKW + $hrrKW) * 0.5 * $deltaSeconds) / 1000.0
        }
    }

    $burnedFraction = [Math]::Min(1.0, $cumulativeHeatMJ / $totalHeatReleasedMJ)
    $massRemainingKg = [Math]::Max(0.0, $totalFuelMassBurnedKg * (1.0 - $burnedFraction))
    $smokeExtinctionPerM = Get-ClampedNumber $row.'Ksmoke (1/m)'

    $values = @(
        (Format-Number $timeSeconds),
        (Format-Number $hrrKW),
        (Format-Number $massRemainingKg),
        (Format-Number (Get-ClampedNumber $row.'NG Burner HRR (kW)' -Minimum -1000000.0)),
        (Format-Number (Get-ClampedNumber $row.'Exhaust Mass Flow Rate (kg/s)' -Minimum -1000000.0)),
        (Format-Number (Get-ClampedNumber $row.'Oxygen (Vol Fr)' -Minimum -1000000.0)),
        (Format-Number (Get-ClampedNumber $row.'CO2 (Vol Fr)' -Minimum -1000000.0)),
        (Format-Number (Get-ClampedNumber $row.'CO (Vol Fr)' -Minimum -1000000.0)),
        (Format-Number (Get-ClampedNumber $row.'Radiant Heat Flux (kW/m^2)' -Minimum -1000000.0)),
        (Format-Number $smokeExtinctionPerM),
        (Format-Number $smokeExtinctionPerM)
    )
    $csvLines.Add(($values -join ",")) | Out-Null

    $previousTimeSeconds = $timeSeconds
    $previousHrrKW = $hrrKW
}

$csvLines | Set-Content -LiteralPath $calibrationPath -Encoding UTF8

$geometryJson = @"
{
  "schemaVersion": 1,
  "experimentId": "NIST_FCD_Methanol_1m_Pool_R1",
  "units": "meters",
  "room": {
    "width": 3.0,
    "height": 3.0,
    "depth": 3.0,
    "ventilation": {
      "type": "open-oxygen-consumption-calorimeter",
      "hoodDiameterM": 3.0,
      "effectiveDuctDiameterM": 0.485,
      "notes": "NIST FCD reports a 3 m oxygen-consumption calorimeter hood. Detailed enclosure walls are not part of the CSV time series."
    }
  },
  "fuelBed": {
    "type": "liquid-pool",
    "material": "methanol",
    "initialMassKg": 37.8,
    "moistureFraction": 0.0,
    "lowerHeatingValueKJPerKg": 19920.0,
    "tray": {
      "center": [0.0, 0.445, 0.0],
      "diameterM": 1.0,
      "depthM": 0.10,
      "lipHeightAboveFloorM": 0.445
    },
    "geometryMesh": ""
  },
  "sensors": {
    "calorimeter": {
      "type": "oxygen-consumption",
      "hoodDiameterM": 3.0,
      "effectiveDuctDiameterM": 0.485
    },
    "gasAnalyzers": [
      {"species": "O2", "location": "hood exhaust stream"},
      {"species": "CO2", "location": "hood exhaust stream"},
      {"species": "CO", "location": "hood exhaust stream"}
    ],
    "radiometers": [
      {"id": "hf_0", "location": "reported by NIST FCD CSV"}
    ],
    "smokeMeters": [
      {"id": "ksmoke_0", "type": "laser-extinction", "location": "hood exhaust stream"}
    ],
    "thermocouples": [],
    "cameras": []
  },
  "provenance": {
    "dataset": "NIST Fire Calorimetry Database Methanol_1m_Pool_R1",
    "license": "NIST data/work terms at https://www.nist.gov/open/license",
    "notes": "Fuel mass curve is derived from THR and HOCf because gravimetric Mi/Mf were not measured in this FCD record."
  }
}
"@
$geometryJson | Set-Content -LiteralPath $geometryPath -Encoding UTF8

$geometryHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $geometryPath).Hash.ToLowerInvariant()
$calibrationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $calibrationPath).Hash.ToLowerInvariant()
$rawHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $rawPath).Hash.ToLowerInvariant()

$manifest = [ordered]@{
    schemaVersion = 1
    experimentId = "NIST_FCD_Methanol_1m_Pool_R1"
    claimScope = "Controlled 1 m methanol pool-fire calibration for HRR, derived fuel mass, gas concentrations, radiant heat flux, and smoke extinction. This dataset does not claim IR-frame or plume-height calibration."
    source = [ordered]@{
        datasetName = "NIST Fire Calorimetry Database: Methanol_1m_Pool_R1"
        organization = "National Institute of Standards and Technology"
        url = $pageUrl
        downloadUrl = $sourceUrl
        doi = "https://doi.org/10.18434/mds2-2314"
        license = "NIST data/work terms; see https://www.nist.gov/open/license"
        accessedDate = "2026-05-02"
    }
    files = [ordered]@{
        geometry = "geometry.json"
        calibrationCsv = "calibration.csv"
        rawData = @("raw/Methanol_1m_Pool_R1.csv")
        processedData = @("calibration.csv")
        videoFrames = @()
        irFrames = @()
    }
    hashes = [ordered]@{
        geometrySha256 = $geometryHash
        calibrationCsvSha256 = $calibrationHash
        rawDataSha256 = [ordered]@{
            "raw/Methanol_1m_Pool_R1.csv" = $rawHash
        }
    }
    measurementChannels = [ordered]@{
        hrrKW = [ordered]@{ units = "kW"; uncertainty = "Peak HRR combined expanded uncertainty Uc=14 kW; THR Uc=38 MJ." }
        ngBurnerHrrKW = [ordered]@{ units = "kW"; uncertainty = "CSV channel; per-row uncertainty is not provided in the FCD export." }
        exhaustMassFlowKgPerS = [ordered]@{ units = "kg/s"; uncertainty = "Baseline hood exhaust flow Uc=0.058 kg/s." }
        oxygenVolumeFraction = [ordered]@{ units = "volume fraction"; uncertainty = "O2 yield Uc=0.10 kg/kg; per-row analyzer uncertainty is not provided in the FCD export." }
        co2VolumeFraction = [ordered]@{ units = "volume fraction"; uncertainty = "CO2 yield Uc=0.10 kg/kg; per-row analyzer uncertainty is not provided in the FCD export." }
        coVolumeFraction = [ordered]@{ units = "volume fraction"; uncertainty = "CO yield Uc=0.000088 kg/kg; per-row analyzer uncertainty is not provided in the FCD export." }
        radiantHeatFluxKWPerM2 = [ordered]@{ units = "kW/m^2"; uncertainty = "CSV channel; per-row uncertainty is not provided in the FCD export." }
        smokeExtinctionCoefficientPerM = [ordered]@{ units = "1/m"; uncertainty = "Soot yield below detection limit; Uc=0.0000075 kg/kg." }
    }
    derivedChannels = [ordered]@{
        massRemainingKg = [ordered]@{
            units = "kg"
            uncertainty = "Derived from THR=753 MJ, HOCf=19.92 MJ/kg, and TFM Uc=2.4 kg."
            derivation = "Integrate positive HRR over time and scale cumulative heat by total heat released to estimate remaining burned fuel mass."
            sourceChannels = @("hrrKW")
        }
        smokeOpticalDepth = [ordered]@{
            units = "dimensionless"
            uncertainty = "1 m path-length proxy derived directly from smokeExtinctionCoefficientPerM."
            derivation = "Clamp Ksmoke to non-negative values and multiply by a 1 m path length."
            sourceChannels = @("smokeExtinctionCoefficientPerM")
        }
    }
    preprocessing = [ordered]@{
        command = ".\scripts\import-nist-fcd-methanol-r1.ps1"
        script = "scripts/import-nist-fcd-methanol-r1.ps1"
        notes = "Keeps post-ignition rows from t=0 through the reported 48.82 min duration. Negative baseline times stay in raw data only. HRR and smoke extinction are clamped non-negative for calibration targets."
    }
    expectedValidationMetrics = @(
        "calibrationHrrShapeRmse",
        "calibrationMassShapeRmse"
    )
}

$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$readme = @"
# NIST FCD Methanol_1m_Pool_R1

Imported by `scripts/import-nist-fcd-methanol-r1.ps1`.

Source page: $pageUrl
Raw CSV: $sourceUrl
FCD DOI: https://doi.org/10.18434/mds2-2314
License/terms: $licenseUrl

This benchmark includes direct CSV channels for HRR, natural-gas burner HRR, exhaust mass flow, O2/CO2/CO volume fractions, radiant heat flux, and smoke extinction. It also includes derived `massRemainingKg` and `smokeOpticalDepth` columns.

It intentionally does not claim thermocouple, IR-frame, or plume-height calibration because those are not present as numeric columns in this FCD CSV export.
"@
$readme | Set-Content -LiteralPath $readmePath -Encoding UTF8

Write-Host "Imported NIST FCD Methanol_1m_Pool_R1 into $OutputRoot"
Write-Host "Rows: $($filteredRows.Count)"
Write-Host "Manifest: $manifestPath"
