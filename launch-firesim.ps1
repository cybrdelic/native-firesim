param(
    [switch]$SmokeTest,
    [switch]$Validation,
    [switch]$DiagnosticsOnly,
    [switch]$AllowGpuKernels,
    [switch]$AcceptBugcheckRisk,
    [switch]$DisableCudaWorker,
    [switch]$NoDialog,
    [ValidateRange(0, 3)]
    [int]$Scene = 0
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
    if (Test-Path -LiteralPath $exe) {
        return
    }
    if (-not (Test-Path -LiteralPath $vcvars)) {
        Show-LauncherMessage "Native FireSim is not built, and Visual Studio Build Tools were not found at $vcvars"
        exit 1
    }

    $buildCommand = "`"$vcvars`" && cmake -S `"$nativeRoot`" -B `"$nativeRoot\build`" -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build `"$nativeRoot\build`" --config Release"
    $build = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $buildCommand) -WorkingDirectory $nativeRoot -Wait -PassThru -WindowStyle Hidden
    if ($build.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
        Show-LauncherMessage "Native FireSim build failed. Run scripts\verify.ps1 -DiagnosticsOnly in $nativeRoot for details."
        exit 1
    }
}

function Invoke-NativeFireSim {
    param([string[]]$Arguments)
    $process = Start-Process -FilePath $exe -ArgumentList $Arguments -WorkingDirectory $nativeRoot -Wait -PassThru -WindowStyle Normal
    return $process.ExitCode
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
        Show-LauncherMessage "CUDA validation is blocked. Re-run with -Validation -AllowGpuKernels -AcceptBugcheckRisk only when intentionally testing the driver path."
        exit 6
    }
    $commonArgs = Get-LiveCudaArguments
    exit (Invoke-NativeFireSim -Arguments (@("--validation", "--scene=$Scene") + $commonArgs))
}

$appArgs = @("--scene=$Scene")
if ($DisableCudaWorker) {
    $appArgs += "--disable-cuda-worker"
} else {
    Ensure-CudaPreflight -SceneId $Scene
    Remove-Item -LiteralPath (Join-Path $outDir "gpu-safety-stop.txt") -Force -ErrorAction SilentlyContinue
    $appArgs += Get-LiveCudaArguments
}
if ($appArgs.Count -gt 0) {
    Start-Process -FilePath $exe -ArgumentList $appArgs -WorkingDirectory $nativeRoot -WindowStyle Normal
    if ($DisableCudaWorker) {
        Write-LauncherStatus "Started NativeFireSim.exe safe animated preview with CUDA worker disabled."
    } else {
        Write-LauncherStatus "Started NativeFireSim.exe with live CUDA worker enabled after successful preflight."
    }
} else {
    Start-Process -FilePath $exe -WorkingDirectory $nativeRoot -WindowStyle Normal
    Write-LauncherStatus "Started NativeFireSim.exe safe animated preview."
}
