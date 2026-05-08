$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$runtimeFiles = @(
    "README.md",
    "docs\gpu-engineering.md",
    "scripts\verify-scene-assets.ps1",
    "scripts\verify-roadmap-gates.ps1"
)

foreach ($relative in $runtimeFiles) {
    $path = Join-Path $root $relative
    if (-not (Test-Path $path)) {
        Write-Error "runtime contract file is missing: $relative"
    }
    $text = Get-Content $path -Raw
    if ($text.Contains("built-in native mesh fallback will be used")) {
        Write-Error "runtime contract drift: $relative still permits missing scene assets as a fallback"
    }
    if ($text.Contains("NativeFireSimViewportFrameV6") -or $text.Contains("NativeFireSimViewportFrameV7") -or $text.Contains("NativeFireSimViewportFrameV8")) {
        Write-Error "runtime contract drift: $relative references a stale shared viewport frame version"
    }
}

$main = Get-Content (Join-Path $root "src\main.cpp") -Raw
if (-not $main.Contains("mainViewportMode=real CUDA worker volume; no animated simulation fallback")) {
    Write-Error "diagnostics must keep the no-animated-fallback viewport contract explicit"
}

Write-Host "runtime contract drift gate ok"
