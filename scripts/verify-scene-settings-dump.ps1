param(
    [switch]$SkipRun
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root "build\NativeFireSim.exe"
$dumpPath = Join-Path $root "out\scene-settings-dump.json"

if (-not $SkipRun) {
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "NativeFireSim.exe was not found at $exe"
    }
    $process = Start-Process -FilePath $exe -ArgumentList "--dump-scene-settings" -WorkingDirectory $root -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "--dump-scene-settings failed with exit code $($process.ExitCode)"
    }
}

if (-not (Test-Path -LiteralPath $dumpPath)) {
    throw "missing scene settings dump: $dumpPath"
}

$dump = Get-Content -LiteralPath $dumpPath -Raw | ConvertFrom-Json
if ($dump.sceneSettingsDumpOk -ne $true) {
    throw "scene settings dump did not report ok"
}
if ([int]$dump.sceneCount -ne 1) {
    throw "scene settings dump must include exactly the methanol product scene"
}
if ([int]$dump.productSceneId -ne 0) {
    throw "scene settings dump must identify scene id 0 as the only product scene"
}
if ([string]$dump.productSceneKey -ne "methanol-pool") {
    throw "scene settings dump must identify methanol-pool as the product scene"
}
if ($dump.referenceScenesRemovedFromProductDump -ne $true) {
    throw "scene settings dump must report that reference scenes are removed from the product dump"
}
$scenes = @($dump.scenes)
if ($scenes.Count -ne 1 -or [int]$scenes[0].id -ne 0) {
    throw "scene settings dump leaked non-product scene settings"
}

foreach ($scene in $scenes) {
    $settings = @($scene.settingsSourceMeters)
    $instance = @($scene.sceneInstanceSourceMeters)
    if ($settings.Count -ne 3 -or $instance.Count -ne 3) {
        throw "scene $($scene.id) source coordinates are malformed"
    }
    for ($i = 0; $i -lt 3; ++$i) {
        if ([Math]::Abs([double]$settings[$i] - [double]$instance[$i]) -gt 0.0025) {
            throw "scene $($scene.id) settings and scene-instance source coordinates disagree"
        }
    }
    if (-not $scene.emitterSourcePolicy) {
        throw "scene $($scene.id) is missing emitterSourcePolicy"
    }
    if ([string]$scene.key -ne "methanol-pool") {
        throw "product scene dump must be methanol-pool"
    }
}

Write-Host "scene settings dump ok"
