param(
    [switch]$SmokeTest,
    [switch]$Validation,
    [switch]$DiagnosticsOnly,
    [switch]$AllowGpuKernels,
    [switch]$AcceptBugcheckRisk,
    [switch]$DisableCudaWorker,
    [switch]$NoDialog,
    [switch]$PlumeTest,
    [ValidateSet("final", "vertical-velocity", "temperature", "fuel", "reaction", "product", "soot", "flow", "source", "active-bricks", "skipped-bricks", "emission", "extinction", "plume-test")]
    [string]$View = "final",
    [int]$Scene = 0,
    [ValidateRange(0, 600000)]
    [int]$SelfCloseMs = 0
)

$ErrorActionPreference = "Stop"

$nativeRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $nativeRoot "build\NativeFireSim.exe"
$outDir = Join-Path $nativeRoot "out"
$logPath = Join-Path $outDir "launcher-status.txt"
$vcvars = "C:\VSBuildTools\VC\Auxiliary\Build\vcvars64.bat"

[void][System.IO.Directory]::CreateDirectory($outDir)

function Write-LauncherStatus {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
    Set-Content -LiteralPath $logPath -Value "$timestamp`r`n$Message`r`n" -Encoding UTF8
}

function Show-LauncherMessage {
    param(
        [string]$Message,
        [string]$Title = "Native FireSim Launcher"
    )
    Write-LauncherStatus $Message
    if ($NoDialog) {
        Write-Host $Message
        return
    }
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Message, $Title) | Out-Null
}

trap {
    $message = "Native FireSim launcher failed:`r`n$($_.Exception.Message)`r`n`r`nScript line: $($_.InvocationInfo.ScriptLineNumber)`r`n$($_.InvocationInfo.Line)"
    Write-LauncherStatus $message
    Write-Host $message
    if (-not $NoDialog) {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show($message, "Native FireSim Launcher Error") | Out-Null
        Write-Host "Press Enter to close this launcher window."
        [void][System.Console]::ReadLine()
    }
    exit 1
}

function Get-LiveCudaArguments {
    return @("--allow-gpu-kernels", "--accept-bugcheck-risk")
}

if ($Scene -ne 0) {
    Write-LauncherStatus "Requested scene $Scene is no longer available; forcing NIST methanol product scene 0."
    $Scene = 0
}

function Get-RenderDebugMode {
    param([string]$ViewName)
    switch ($ViewName) {
        "vertical-velocity" { return 6 }
        "temperature" { return 4 }
        "fuel" { return 5 }
        "reaction" { return 15 }
        "product" { return 16 }
        "soot" { return 2 }
        "flow" { return 8 }
        "source" { return 9 }
        "active-bricks" { return 11 }
        "skipped-bricks" { return 12 }
        "emission" { return 13 }
        "extinction" { return 14 }
        "plume-test" { return 6 }
        default { return 0 }
    }
}

function Test-CudaPreflightFresh {
    param([int]$SceneId)
    $preflightPath = Join-Path $outDir "cuda-preflight.json"
    if (-not (Test-Path -LiteralPath $preflightPath)) {
        return $false
    }
    $item = Get-Item -LiteralPath $preflightPath
    if (((Get-Date) - $item.LastWriteTime).TotalMinutes -gt 55) {
        return $false
    }
    try {
        $json = Get-Content -LiteralPath $preflightPath -Raw | ConvertFrom-Json
        return $json.preflightOk -eq $true -and $json.interactiveLaunchAllowed -eq $true -and [int]$json.scene -eq $SceneId
    } catch {
        return $false
    }
}

function Ensure-CudaPreflight {
    param([int]$SceneId)
    if (Test-CudaPreflightFresh -SceneId $SceneId) {
        return
    }
    $commonArgs = Get-LiveCudaArguments
    $preflightArgs = @(
        "--cuda-preflight",
        "--frames=5",
        "--scene=$SceneId",
        "--volume-slice-depth=128",
        "--render-slice-rows=512",
        "--output-dir=out"
    ) + $commonArgs
    Write-LauncherStatus "Refreshing CUDA preflight before live worker launch."
    $code = Invoke-NativeFireSim -Arguments $preflightArgs
    if ($code -ne 0 -or -not (Test-CudaPreflightFresh -SceneId $SceneId)) {
        Show-LauncherMessage "CUDA preflight failed with exit code $code. The live CUDA worker was not started. See $nativeRoot\out\cuda-preflight.json."
        exit 6
    }
    Remove-Item -LiteralPath (Join-Path $outDir "gpu-safety-stop.txt") -Force -ErrorAction SilentlyContinue
}

function Ensure-NativeFireSimBuilt {
    if (Test-NativeFireSimBuildFresh) {
        return
    }
    if (-not (Test-Path -LiteralPath $vcvars)) {
        Show-LauncherMessage "Native FireSim is not built, and Visual Studio Build Tools were not found at $vcvars"
        exit 1
    }

    $buildLog = Join-Path $outDir "launcher-build.log"
    $buildCommand = "`"$vcvars`" && cmake -S `"$nativeRoot`" -B `"$nativeRoot\build`" -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build `"$nativeRoot\build`" --config Release"
    Push-Location $nativeRoot
    try {
        $buildOutput = cmd.exe /c $buildCommand 2>&1
        $buildExitCode = $LASTEXITCODE
        Set-Content -LiteralPath $buildLog -Value ($buildOutput -join "`r`n") -Encoding UTF8
    } finally {
        Pop-Location
    }
    if ($buildExitCode -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
        Show-LauncherMessage "Native FireSim build failed. Build log: $buildLog. Run scripts\verify.ps1 -DiagnosticsOnly in $nativeRoot for full checks."
        exit 1
    }
}

function Get-NewestSourceWriteTimeUtc {
    $nativeUiRoot = "C:\Users\alexf\projects\native-ui-engine"
    $paths = @(
        (Join-Path $nativeRoot "CMakeLists.txt"),
        (Join-Path $nativeRoot "src"),
        (Join-Path $nativeUiRoot "CMakeLists.txt"),
        (Join-Path $nativeUiRoot "include"),
        (Join-Path $nativeUiRoot "src")
    )
    $newest = [DateTime]::MinValue
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        if ((Get-Item -LiteralPath $path).PSIsContainer) {
            $items = Get-ChildItem -LiteralPath $path -Recurse -File -Include *.c,*.cpp,*.cu,*.h,*.hpp,*.cmake -ErrorAction SilentlyContinue
        } else {
            $items = @(Get-Item -LiteralPath $path)
        }
        foreach ($item in $items) {
            if ($item.LastWriteTimeUtc -gt $newest) {
                $newest = $item.LastWriteTimeUtc
            }
        }
    }
    return $newest
}

function Test-NativeFireSimBuildFresh {
    if (-not (Test-Path -LiteralPath $exe)) {
        return $false
    }
    $exeTime = (Get-Item -LiteralPath $exe).LastWriteTimeUtc
    $sourceTime = Get-NewestSourceWriteTimeUtc
    return $exeTime -ge $sourceTime
}

function Invoke-NativeFireSim {
    param([string[]]$Arguments)
    $process = Start-Process -FilePath $exe -ArgumentList $Arguments -WorkingDirectory $nativeRoot -Wait -PassThru -WindowStyle Normal
    return $process.ExitCode
}

function Start-NativeFireSimInteractive {
    param(
        [string[]]$Arguments,
        [string]$SuccessMessage
    )
    $process = Start-Process -FilePath $exe -ArgumentList $Arguments -WorkingDirectory $nativeRoot -PassThru -WindowStyle Normal
    Start-Sleep -Seconds 2
    if ($process.HasExited) {
        if ($SelfCloseMs -gt 0 -and $process.ExitCode -eq 0) {
            Write-LauncherStatus "$SuccessMessage`r`nSelfCloseMs=$SelfCloseMs`r`nExitCode=0"
            return
        }
        Show-LauncherMessage "NativeFireSim.exe exited immediately with code $($process.ExitCode). See $nativeRoot\out\worker-events.log and $nativeRoot\out\launcher-status.txt."
        exit $process.ExitCode
    }
    if ($SelfCloseMs -gt 0) {
        $waitMs = [Math]::Max(3000, $SelfCloseMs + 3000)
        if (-not $process.WaitForExit($waitMs)) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Show-LauncherMessage "NativeFireSim.exe did not self-close within ${waitMs}ms during launcher smoke test."
            exit 7
        }
        if ($process.ExitCode -ne 0) {
            Show-LauncherMessage "NativeFireSim.exe self-close smoke test failed with code $($process.ExitCode). See $nativeRoot\out\worker-events.log and $nativeRoot\out\launcher-status.txt."
            exit $process.ExitCode
        }
        Write-LauncherStatus "$SuccessMessage`r`nSelfCloseMs=$SelfCloseMs`r`nExitCode=0"
        return
    }
    Write-LauncherStatus "$SuccessMessage`r`nProcessId=$($process.Id)"
}

if (-not (Test-Path -LiteralPath $nativeRoot)) {
    Show-LauncherMessage "Native FireSim was not found at $nativeRoot"
    exit 1
}

Ensure-NativeFireSimBuilt

if ($DiagnosticsOnly) {
    $code = Invoke-NativeFireSim -Arguments @("--diagnostics")
    if ($code -eq 0) {
        Show-LauncherMessage "Native FireSim diagnostics completed. Output: $nativeRoot\out\diagnostics.txt"
    } else {
        Show-LauncherMessage "Native FireSim diagnostics failed with exit code $code. Output: $nativeRoot\out\diagnostics.txt"
    }
    exit $code
}

if ($SmokeTest) {
    if (-not ($AllowGpuKernels -and $AcceptBugcheckRisk)) {
        Show-LauncherMessage "CUDA smoke-test is blocked. Re-run with -SmokeTest -AllowGpuKernels -AcceptBugcheckRisk only when intentionally testing the driver path."
        exit 6
    }
    $commonArgs = Get-LiveCudaArguments
    exit (Invoke-NativeFireSim -Arguments (@("--smoke-test") + $commonArgs))
}
if ($Validation) {
    if (-not ($AllowGpuKernels -and $AcceptBugcheckRisk)) {
        Show-LauncherMessage "NIST methanol CUDA calibration is blocked. Re-run with -Validation -AllowGpuKernels -AcceptBugcheckRisk only when intentionally testing the driver path."
        exit 6
    }
    $calibrationScript = Join-Path $nativeRoot "scripts\run-nist-calibration.ps1"
    if (-not (Test-Path -LiteralPath $calibrationScript)) {
        Show-LauncherMessage "NIST calibration runner was not found at $calibrationScript"
        exit 1
    }
    Push-Location $nativeRoot
    try {
        & $calibrationScript -RunGpuKernels -AcceptBugcheckRisk -SkipBuild
        exit $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

$debugMode = Get-RenderDebugMode -ViewName $View
$appArgs = @("--scene=$Scene", "--focus-scene", "--debug-mode=$debugMode")
if ($View -eq "plume-test") {
    $PlumeTest = $true
}
if ($PlumeTest) {
    $appArgs += "--plume-test"
}
if ($SelfCloseMs -gt 0) {
    $appArgs += "--auto-close-ms=$SelfCloseMs"
}
if ($DisableCudaWorker) {
    $appArgs += "--disable-cuda-worker"
} else {
    Ensure-CudaPreflight -SceneId $Scene
    Remove-Item -LiteralPath (Join-Path $outDir "gpu-safety-stop.txt") -Force -ErrorAction SilentlyContinue
    $appArgs += Get-LiveCudaArguments
}
if ($appArgs.Count -gt 0) {
    if ($DisableCudaWorker) {
        Start-NativeFireSimInteractive -Arguments $appArgs -SuccessMessage "Started NativeFireSim.exe safe animated preview with CUDA worker disabled."
    } else {
        Start-NativeFireSimInteractive -Arguments $appArgs -SuccessMessage "Started NativeFireSim.exe with live CUDA worker enabled after successful preflight."
    }
} else {
    Start-NativeFireSimInteractive -Arguments @() -SuccessMessage "Started NativeFireSim.exe safe animated preview."
}
