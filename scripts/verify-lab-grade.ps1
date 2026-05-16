param(
    [string]$GeometryPath = "",
    [string]$CalibrationCsvPath = "",
    [string]$ManifestPath = "",
    [switch]$RequireRealDataset
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$realDatasetRoot = Join-Path $root "benchmarks\nist-fcd\methanol-1m-pool-r1"
$allPathsDefaulted = [string]::IsNullOrWhiteSpace($GeometryPath) -and
    [string]::IsNullOrWhiteSpace($CalibrationCsvPath) -and
    [string]::IsNullOrWhiteSpace($ManifestPath)

if ($RequireRealDataset -and $allPathsDefaulted -and (Test-Path -LiteralPath (Join-Path $realDatasetRoot "manifest.json"))) {
    $GeometryPath = Join-Path $realDatasetRoot "geometry.json"
    $CalibrationCsvPath = Join-Path $realDatasetRoot "calibration.csv"
    $ManifestPath = Join-Path $realDatasetRoot "manifest.json"
} else {
    if ([string]::IsNullOrWhiteSpace($GeometryPath)) {
        $GeometryPath = Join-Path $root "benchmarks\geometry-template.json"
    }
    if ([string]::IsNullOrWhiteSpace($CalibrationCsvPath)) {
        $CalibrationCsvPath = Join-Path $root "benchmarks\real-burn-calibration-template.csv"
    }
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $root "benchmarks\lab-grade-manifest-template.json"
    }
}

$outDir = Join-Path $root "out"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$checks = New-Object System.Collections.Generic.List[object]
$invariantCulture = [Globalization.CultureInfo]::InvariantCulture

function Add-Check {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail
    )
    $checks.Add([pscustomobject]@{
        name = $Name
        status = $Status
        detail = $Detail
    }) | Out-Null
}

function Test-UnfilledValue {
    param([object]$Value)
    if ($null -eq $Value) {
        return $true
    }
    $text = [string]$Value
    return [string]::IsNullOrWhiteSpace($text) -or $text -match "replace-with|template"
}

function Select-Status {
    param(
        [bool]$Condition,
        [string]$TrueStatus,
        [string]$FalseStatus
    )
    if ($Condition) {
        return $TrueStatus
    }
    return $FalseStatus
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing JSON file: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-ObjectPropertyNames {
    param([object]$Object)
    if ($null -eq $Object) {
        return @()
    }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Convert-ToDoubleOrNull {
    param([object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, $invariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Resolve-ManifestPath {
    param(
        [string]$ManifestDirectory,
        [string]$PathValue
    )
    if (Test-UnfilledValue $PathValue) {
        return ""
    }
    if ([IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }
    return Join-Path $ManifestDirectory $PathValue
}

function Get-NumericColumnSampleCount {
    param(
        [object[]]$Rows,
        [string]$Column
    )
    $count = 0
    foreach ($row in $Rows) {
        $value = Get-ObjectPropertyValue $row $Column
        if ($null -ne (Convert-ToDoubleOrNull $value)) {
            $count += 1
        }
    }
    return $count
}

function Test-DeclaredChannel {
    param(
        [string]$Channel,
        [object]$ChannelObject,
        [string]$ChannelKind
    )
    $hasUnits = $null -ne $ChannelObject -and -not (Test-UnfilledValue $ChannelObject.units)
    $hasUncertainty = $null -ne $ChannelObject -and -not (Test-UnfilledValue $ChannelObject.uncertainty)
    $missingStatus = Select-Status ([bool]$RequireRealDataset) "fail" "warn"
    Add-Check "manifest:${ChannelKind}:$Channel" (Select-Status ($null -ne $ChannelObject) "pass" "fail") "$ChannelKind channel declared"
    Add-Check "manifest:units:$Channel" (Select-Status $hasUnits "pass" $missingStatus) "units required for real dataset"
    Add-Check "manifest:uncertainty:$Channel" (Select-Status $hasUncertainty "pass" $missingStatus) "uncertainty required for real dataset"

    if ($ChannelKind -eq "derived") {
        $hasDerivation = $null -ne $ChannelObject -and -not (Test-UnfilledValue $ChannelObject.derivation)
        Add-Check "manifest:derivation:$Channel" (Select-Status $hasDerivation "pass" $missingStatus) "derived channels must state how they were produced"
    }
}

foreach ($requiredPath in @(
    (Join-Path $root "docs\lab-grade-roadmap.md"),
    (Join-Path $root "docs\infrastructure-hardening-plan.md"),
    $GeometryPath,
    $CalibrationCsvPath,
    $ManifestPath
)) {
    if (Test-Path -LiteralPath $requiredPath) {
        Add-Check "file:$([IO.Path]::GetFileName($requiredPath))" "pass" $requiredPath
    } else {
        Add-Check "file:$([IO.Path]::GetFileName($requiredPath))" "fail" "Missing required file: $requiredPath"
    }
}

$manifest = $null
try {
    $manifest = Read-JsonFile $ManifestPath
    Add-Check "manifest:json" "pass" "manifest JSON parsed"
} catch {
    Add-Check "manifest:json" "fail" $_.Exception.Message
}

$measurementChannels = @()
$derivedChannels = @()
$declaredChannels = @()
if ($null -ne $manifest) {
    $measurementChannels = Get-ObjectPropertyNames $manifest.measurementChannels
    $derivedChannels = Get-ObjectPropertyNames $manifest.derivedChannels
    $declaredChannels = @($measurementChannels + $derivedChannels | Select-Object -Unique)
}

$geometry = $null
try {
    $geometry = Read-JsonFile $GeometryPath
    Add-Check "geometry:json" "pass" "geometry JSON parsed"
} catch {
    Add-Check "geometry:json" "fail" $_.Exception.Message
}

if ($null -ne $geometry) {
    if ($geometry.units -eq "meters") {
        Add-Check "geometry:units" "pass" "units=meters"
    } else {
        Add-Check "geometry:units" "fail" "geometry units must be meters"
    }

    $roomOk = $geometry.room.width -gt 0 -and $geometry.room.height -gt 0 -and $geometry.room.depth -gt 0
    Add-Check "geometry:room" (Select-Status $roomOk "pass" "fail") "room width/height/depth must be positive"

    $fuelOk = -not (Test-UnfilledValue $geometry.fuelBed.material)
    $massOk = $geometry.fuelBed.initialMassKg -gt 0
    if ($RequireRealDataset) {
        Add-Check "geometry:fuel-material" (Select-Status $fuelOk "pass" "fail") "real dataset must name fuel material"
        Add-Check "geometry:fuel-mass" (Select-Status $massOk "pass" "fail") "real dataset must provide fuel mass or documented derived fuel mass"
    } else {
        Add-Check "geometry:fuel-material" (Select-Status $fuelOk "pass" "warn") "template values are allowed outside -RequireRealDataset"
        Add-Check "geometry:fuel-mass" (Select-Status $massOk "pass" "warn") "template mass is allowed outside -RequireRealDataset"
    }

    $tcCount = @($geometry.sensors.thermocouples).Count
    $cameraTypes = @($geometry.sensors.cameras | ForEach-Object { $_.type })
    $needsThermocouples = $declaredChannels -contains "thermocouplesC"
    $needsRgbCamera = ($declaredChannels -contains "plumeHeightM") -or @($manifest.files.videoFrames).Count -gt 0
    $needsIrCamera = ($declaredChannels -contains "irMeanC") -or ($declaredChannels -contains "irMaxC") -or @($manifest.files.irFrames).Count -gt 0

    if ($needsThermocouples) {
        Add-Check "geometry:thermocouples" (Select-Status ($tcCount -gt 0) "pass" "fail") "thermocouple count=$tcCount"
    } else {
        Add-Check "geometry:thermocouples" "pass" "not required by declared channels"
    }

    if ($needsRgbCamera) {
        Add-Check "geometry:rgb-camera" (Select-Status ($cameraTypes -contains "RGB") "pass" "fail") "RGB camera required by declared channels/files"
    } else {
        Add-Check "geometry:rgb-camera" "pass" "not required by declared channels"
    }

    if ($needsIrCamera) {
        Add-Check "geometry:ir-camera" (Select-Status ($cameraTypes -contains "IR") "pass" "fail") "IR camera required by declared channels/files"
    } else {
        Add-Check "geometry:ir-camera" "pass" "not required by declared channels"
    }
}

if (Test-Path -LiteralPath $CalibrationCsvPath) {
    $csvLines = Get-Content -LiteralPath $CalibrationCsvPath
    if ($csvLines.Count -gt 0) {
        $headers = @($csvLines[0].Split(",") | ForEach-Object { $_.Trim('" ') })
        Add-Check "csv:header:timeSeconds" (Select-Status ($headers -contains "timeSeconds") "pass" "fail") "time column required"

        $rows = @(Import-Csv -LiteralPath $CalibrationCsvPath)
        $timeValues = @()
        foreach ($row in $rows) {
            $parsedTime = Convert-ToDoubleOrNull (Get-ObjectPropertyValue $row "timeSeconds")
            if ($null -ne $parsedTime) {
                $timeValues += $parsedTime
            }
        }
        $monotonic = $timeValues.Count -gt 0
        for ($i = 1; $i -lt $timeValues.Count; ++$i) {
            if ($timeValues[$i] -lt $timeValues[$i - 1]) {
                $monotonic = $false
            }
        }
        Add-Check "csv:time-monotonic" (Select-Status $monotonic "pass" "fail") "time samples=$($timeValues.Count)"

        $channelsWithData = 0
        $measuredChannelsWithData = 0
        foreach ($channel in $declaredChannels) {
            if ($channel -eq "thermocouplesC") {
                $candidateColumns = @($headers | Where-Object { $_ -match "^tc_.+_C$" })
            } else {
                $candidateColumns = @($headers | Where-Object { $_ -eq $channel })
            }

            if ($candidateColumns.Count -eq 0) {
                $missingColumnStatus = Select-Status ([bool]$RequireRealDataset) "fail" "warn"
                Add-Check "csv:header:$channel" $missingColumnStatus "declared channel has no calibration CSV column"
                continue
            }

            $sampleCount = 0
            foreach ($column in $candidateColumns) {
                $sampleCount = [Math]::Max($sampleCount, (Get-NumericColumnSampleCount $rows $column))
            }

            if ($sampleCount -ge 3) {
                $channelsWithData += 1
                if ($measurementChannels -contains $channel) {
                    $measuredChannelsWithData += 1
                }
                Add-Check "csv:data:$channel" "pass" "samples=$sampleCount"
            } elseif ($RequireRealDataset) {
                Add-Check "csv:data:$channel" "fail" "real dataset requires at least 3 numeric samples for declared channels"
            } else {
                Add-Check "csv:data:$channel" "warn" "template channel has no numeric calibration samples"
            }
        }

        if ($RequireRealDataset) {
            Add-Check "csv:required-hrr" (Select-Status ($declaredChannels -contains "hrrKW") "pass" "fail") "real fire calibration requires HRR"
            Add-Check "csv:required-fuel-mass" (Select-Status ($declaredChannels -contains "massRemainingKg") "pass" "fail") "real fire calibration requires a measured or derived fuel-mass curve"
            Add-Check "csv:data-coverage" (Select-Status ($channelsWithData -ge 4) "pass" "fail") "declared channels with data=$channelsWithData"
            Add-Check "csv:measured-data-coverage" (Select-Status ($measuredChannelsWithData -ge 3) "pass" "fail") "direct measured channels with data=$measuredChannelsWithData"
        } else {
            Add-Check "csv:data-coverage" "warn" "template is structurally valid but not real calibration evidence"
        }
    } else {
        Add-Check "csv:read" "fail" "calibration CSV is empty"
    }
}

if ($null -ne $manifest) {
    foreach ($field in @("experimentId", "claimScope")) {
        $isReal = -not (Test-UnfilledValue $manifest.$field)
        $missingStatus = Select-Status ([bool]$RequireRealDataset) "fail" "warn"
        Add-Check "manifest:$field" (Select-Status $isReal "pass" $missingStatus) "specific value required for real dataset"
    }

    $hasSource = -not (Test-UnfilledValue $manifest.source.url) -or -not (Test-UnfilledValue $manifest.source.doi)
    $missingSourceStatus = Select-Status ([bool]$RequireRealDataset) "fail" "warn"
    Add-Check "manifest:source" (Select-Status $hasSource "pass" $missingSourceStatus) "source URL or DOI required"

    $hasLicense = -not (Test-UnfilledValue $manifest.source.license)
    $missingLicenseStatus = Select-Status ([bool]$RequireRealDataset) "fail" "warn"
    Add-Check "manifest:license" (Select-Status $hasLicense "pass" $missingLicenseStatus) "license/terms required"

    $hasChannels = $declaredChannels.Count -gt 0
    Add-Check "manifest:channels" (Select-Status $hasChannels "pass" "fail") "declared channels=$($declaredChannels.Count)"

    foreach ($channel in $measurementChannels) {
        Test-DeclaredChannel $channel (Get-ObjectPropertyValue $manifest.measurementChannels $channel) "measurement"
    }
    foreach ($channel in $derivedChannels) {
        Test-DeclaredChannel $channel (Get-ObjectPropertyValue $manifest.derivedChannels $channel) "derived"
    }

    $manifestDir = Split-Path -Parent $ManifestPath
    $manifestFileEntries = New-Object System.Collections.Generic.List[object]
    if ($null -ne $manifest.files) {
        foreach ($field in @("geometry", "calibrationCsv")) {
            $value = Get-ObjectPropertyValue $manifest.files $field
            if (-not (Test-UnfilledValue $value)) {
                $manifestFileEntries.Add([pscustomobject]@{ name = $field; relativePath = [string]$value }) | Out-Null
            }
        }
        foreach ($field in @("rawData", "processedData", "videoFrames", "irFrames")) {
            foreach ($value in @((Get-ObjectPropertyValue $manifest.files $field))) {
                if (-not (Test-UnfilledValue $value)) {
                    $manifestFileEntries.Add([pscustomobject]@{ name = $field; relativePath = [string]$value }) | Out-Null
                }
            }
        }
    }

    foreach ($entry in $manifestFileEntries) {
        $resolvedPath = Resolve-ManifestPath $manifestDir $entry.relativePath
        Add-Check "manifest:file:$($entry.name):$($entry.relativePath)" (Select-Status (Test-Path -LiteralPath $resolvedPath) "pass" "fail") $resolvedPath
    }

    if ($RequireRealDataset) {
        $hashes = $manifest.hashes
        $geometryHash = Get-ObjectPropertyValue $hashes "geometrySha256"
        $calibrationHash = Get-ObjectPropertyValue $hashes "calibrationCsvSha256"
        foreach ($hashTarget in @(
            [pscustomobject]@{ name = "geometry"; path = $GeometryPath; expected = $geometryHash },
            [pscustomobject]@{ name = "calibrationCsv"; path = $CalibrationCsvPath; expected = $calibrationHash }
        )) {
            if (Test-UnfilledValue $hashTarget.expected) {
                Add-Check "manifest:hash:$($hashTarget.name)" "fail" "real dataset requires SHA-256 hash"
                continue
            }
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $hashTarget.path).Hash.ToLowerInvariant()
            Add-Check "manifest:hash:$($hashTarget.name)" (Select-Status ($actual -eq ([string]$hashTarget.expected).ToLowerInvariant()) "pass" "fail") "sha256=$actual"
        }

        foreach ($rawHash in Get-ObjectPropertyNames $manifest.hashes.rawDataSha256) {
            $expected = Get-ObjectPropertyValue $manifest.hashes.rawDataSha256 $rawHash
            $resolvedPath = Resolve-ManifestPath $manifestDir $rawHash
            if (-not (Test-Path -LiteralPath $resolvedPath)) {
                Add-Check "manifest:hash:raw:$rawHash" "fail" "raw file missing"
                continue
            }
            $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedPath).Hash.ToLowerInvariant()
            Add-Check "manifest:hash:raw:$rawHash" (Select-Status ($actual -eq ([string]$expected).ToLowerInvariant()) "pass" "fail") "sha256=$actual"
        }
    }
}

$failCount = @($checks | Where-Object { $_.status -eq "fail" }).Count
$warnCount = @($checks | Where-Object { $_.status -eq "warn" }).Count
$labGradeReady = $failCount -eq 0 -and $warnCount -eq 0 -and $RequireRealDataset

$report = [pscustomobject]@{
    labGradeReady = $labGradeReady
    requireRealDataset = [bool]$RequireRealDataset
    geometryPath = $GeometryPath
    calibrationCsvPath = $CalibrationCsvPath
    manifestPath = $ManifestPath
    failCount = $failCount
    warnCount = $warnCount
    checkedAt = (Get-Date).ToString("o")
    checks = $checks
}

$reportPath = Join-Path $outDir "lab-grade-readiness.json"
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8

if ($failCount -gt 0) {
    Write-Error "Lab-grade preflight failed with $failCount failures. See $reportPath"
    exit 1
}

Write-Host "lab-grade preflight ok; warnings=$warnCount; report=$reportPath"
