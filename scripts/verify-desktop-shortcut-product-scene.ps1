param(
    [switch]$NoLaunch,
    [switch]$AllowGpuKernels,
    [switch]$AcceptBugcheckRisk
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")

$shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "FireSim.lnk"
if (-not (Test-Path -LiteralPath $shortcutPath)) {
    throw "FireSim desktop shortcut is missing: $shortcutPath"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$targetPath = [string]$shortcut.TargetPath
$arguments = [string]$shortcut.Arguments
$launcherPath = Join-Path $script:RepoRoot "launch-firesim.ps1"

if ($targetPath -notmatch "powershell(\.exe)?$") {
    throw "FireSim shortcut target must be powershell.exe; actual target: $targetPath"
}
if ($arguments -notlike "*launch-firesim.ps1*") {
    throw "FireSim shortcut does not call launch-firesim.ps1; actual arguments: $arguments"
}
if ($arguments -notlike "*native-firesim*") {
    throw "FireSim shortcut does not point at this native-firesim checkout; actual arguments: $arguments"
}
if ($arguments -like "*-Scene 3*" -or $arguments -like "*--scene=3*") {
    throw "FireSim shortcut still passes the removed scene 3 argument; actual arguments: $arguments"
}

$launcherText = Get-Content -LiteralPath $launcherPath -Raw
Require-Text $launcherText "[int]`$Scene = 0" "launcher default scene must be the methanol product scene"
Require-Text $launcherText 'forcing NIST methanol product scene 0' "launcher must clamp stale nonzero scene arguments"
Require-Text $launcherText "--focus-scene" "launcher must open in focused product-scene mode"
Require-Text $launcherText "Ensure-CudaPreflight -SceneId `$Scene" "launcher must preflight the same product scene it opens"
Require-Text $launcherText "--auto-close-ms=`$SelfCloseMs" "launcher must support self-closing desktop smoke tests"

if (-not $NoLaunch) {
    $launcherParams = @{
        NoDialog = $true
        Scene = 0
        SelfCloseMs = 1500
    }
    if ($AllowGpuKernels -and $AcceptBugcheckRisk) {
        $launcherParams.AllowGpuKernels = $true
        $launcherParams.AcceptBugcheckRisk = $true
    } else {
        $launcherParams.DisableCudaWorker = $true
    }
    & $launcherPath @launcherParams
    if (-not $? -or ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0)) {
        throw "desktop launcher self-test failed with exit code $LASTEXITCODE"
    }
}

Write-Host "desktop shortcut product scene gate ok"
