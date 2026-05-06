param(
    [string]$AssetId = "all",
    [string]$ManifestPath = "assets\sketchfab-fire-sources\sources.json",
    [string]$DownloadDir = "assets\sketchfab-fire-sources\_downloads",
    [string]$OutputRoot = "assets\fire-scenes",
    [string]$SketchfabToken = $env:SKETCHFAB_API_TOKEN,
    [int]$GridResolution = 32,
    [switch]$AcceptLicenseTerms,
    [switch]$ListOnly
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$manifestFullPath = Resolve-Path (Join-Path $repoRoot $ManifestPath)
$downloadFullPath = Join-Path $repoRoot $DownloadDir
$outputFullPath = Join-Path $repoRoot $OutputRoot
$processor = Join-Path $PSScriptRoot "process_fire_scene_asset.py"

function Get-SourceById {
    param([object]$Manifest, [string]$Id)
    foreach ($source in @($Manifest.sources)) {
        if ($source.id -eq $Id) {
            return $source
        }
    }
    throw "Unknown asset id '$Id'"
}

function Find-LocalArchive {
    param([object]$Source)
    foreach ($name in @($Source.downloadArchiveNames)) {
        $candidate = Join-Path $downloadFullPath ([string]$name)
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

function Invoke-SketchfabDownload {
    param([object]$Source)
    if ([string]::IsNullOrWhiteSpace($SketchfabToken)) {
        return $null
    }

    New-Item -ItemType Directory -Force -Path $downloadFullPath | Out-Null
    $headersList = @(
        @{ Authorization = "Bearer $SketchfabToken"; Accept = "application/json" },
        @{ Authorization = "Token $SketchfabToken"; Accept = "application/json" }
    )
    $downloadInfo = $null
    foreach ($headers in $headersList) {
        try {
            $downloadInfo = Invoke-RestMethod -Uri "https://api.sketchfab.com/v3/models/$($Source.uid)/download" -Headers $headers
            break
        } catch {
            $downloadInfo = $null
        }
    }
    if ($null -eq $downloadInfo) {
        throw "Sketchfab download API rejected the provided token for $($Source.id)."
    }

    $url = $null
    if ($null -ne $downloadInfo.gltf -and -not [string]::IsNullOrWhiteSpace([string]$downloadInfo.gltf.url)) {
        $url = [string]$downloadInfo.gltf.url
    } elseif ($null -ne $downloadInfo.source -and -not [string]::IsNullOrWhiteSpace([string]$downloadInfo.source.url)) {
        $url = [string]$downloadInfo.source.url
    }
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "Sketchfab download response for $($Source.id) did not include a glTF/source URL."
    }

    $archivePath = Join-Path $downloadFullPath "$($Source.id).zip"
    Invoke-WebRequest -Uri $url -OutFile $archivePath
    return (Resolve-Path $archivePath).Path
}

$manifest = Get-Content $manifestFullPath -Raw | ConvertFrom-Json
$sources = if ($AssetId -eq "all") { @($manifest.sources) } else { @(Get-SourceById -Manifest $manifest -Id $AssetId) }

if ($ListOnly) {
    foreach ($source in $sources) {
        Write-Host "$($source.id): $($source.title) by $($source.author) / $($source.license) / $($source.url)"
    }
    exit 0
}

if (-not $AcceptLicenseTerms) {
    throw "Pass -AcceptLicenseTerms after confirming each source license and attribution requirement."
}

if (-not (Test-Path $processor)) {
    throw "Missing processor: $processor"
}

foreach ($source in $sources) {
    $archive = Find-LocalArchive -Source $source
    if ($null -eq $archive) {
        $archive = Invoke-SketchfabDownload -Source $source
    }
    if ($null -eq $archive) {
        $expected = (@($source.downloadArchiveNames) -join ", ")
        throw "Missing $($source.id) archive. Add one of [$expected] to $downloadFullPath or set SKETCHFAB_API_TOKEN."
    }

    & python $processor `
        --source-manifest $manifestFullPath `
        --asset-id $source.id `
        --input $archive `
        --output-root $outputFullPath `
        --grid-resolution $GridResolution
    if ($LASTEXITCODE -ne 0) {
        throw "Processing failed for $($source.id)"
    }
}

