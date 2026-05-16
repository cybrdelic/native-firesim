param(
    [ValidateSet("Benchmark", "SliceFinder", "NsightSystems", "NsightCompute", "ComputeSanitizer", "All")]
    [string]$Mode = "Benchmark",
    [string]$OutputDir = "out\cuda-profile",
    [int]$WarmupFrames = 8,
    [int]$BenchmarkFrames = 16,
    [int]$SimEveryFrames = 1,
    [ValidateRange(0, 0)]
    [int]$Scene = 0,
    [int]$LaunchSkip = 0,
    [int]$LaunchCount = 64,
    [ValidateSet("basic", "detailed", "full", "roofline")]
    [string]$NsightSet = "basic",
    [string]$KernelRegex = "regex:.*(advect|reaction|pressure|render|pack|lighting).*",
    [switch]$FullPhysics,
    [switch]$AcceptBugcheckRisk
)

$ErrorActionPreference = "Stop"

function Invoke-CheckedProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$Label
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "$Label failed with exit code $($process.ExitCode)"
    }
}

if (-not $AcceptBugcheckRisk) {
    throw "CUDA profiling launches GPU kernels. Re-run with -AcceptBugcheckRisk when you intentionally want to exercise the driver path."
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$exePath = Join-Path $repoRoot "build\NativeFireSim.exe"
if (-not (Test-Path $exePath)) {
    throw "Missing $exePath. Run .\scripts\verify.ps1 -DiagnosticsOnly first so the executable exists."
}

New-Item -ItemType Directory -Force -Path (Join-Path $repoRoot $OutputDir) | Out-Null
$profileRoot = Resolve-Path (Join-Path $repoRoot $OutputDir)
$benchDir = Join-Path $profileRoot "worker-benchmark"

$simArgs = @(
    "--worker-benchmark",
    "--allow-gpu-kernels",
    "--accept-bugcheck-risk",
    "--output-dir=$benchDir",
    "--warmup-frames=$WarmupFrames",
    "--benchmark-frames=$BenchmarkFrames",
    "--scene=$Scene"
)
if (-not $FullPhysics) {
    $simArgs += "--sim-every-frames=$SimEveryFrames"
}

$commands = New-Object System.Collections.Generic.List[string]
$commands.Add("# Native FireSim CUDA profiling")
$commands.Add("")
$commands.Add("Generated: $(Get-Date -Format o)")
$commands.Add("")

if ($Mode -eq "SliceFinder" -or $Mode -eq "All") {
    $sliceDir = Join-Path $profileRoot "slice-finder"
    $sliceArgs = @(
        "--cuda-slice-finder",
        "--allow-gpu-kernels",
        "--accept-bugcheck-risk",
        "--output-dir=$sliceDir",
        "--frames=3",
        "--scene=$Scene"
    )
    Invoke-CheckedProcess -FilePath $exePath -Arguments $sliceArgs -Label "CUDA slice finder"
    $commands.Add("## CUDA Slice Finder")
    $commands.Add("")
    $commands.Add('```powershell')
    $commands.Add('& "' + $exePath + '" ' + ($sliceArgs -join ' '))
    $commands.Add('```')
    $commands.Add("")
}

if ($Mode -eq "Benchmark" -or $Mode -eq "All") {
    Invoke-CheckedProcess -FilePath $exePath -Arguments $simArgs -Label "worker benchmark"
    $benchmarkJson = Join-Path $benchDir "worker-benchmark.json"
    $summaryPath = Join-Path $profileRoot "gpu-timing-summary.md"
    python (Join-Path $PSScriptRoot "summarize-gpu-timings.py") $benchmarkJson $summaryPath
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

if ($Mode -eq "NsightSystems" -or $Mode -eq "All") {
    $nsys = Get-Command nsys.exe,nsys -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $nsys) {
        throw "Nsight Systems CLI was not found on PATH. Install Nsight Systems or add nsys.exe to PATH."
    }
    $nsysOut = Join-Path $profileRoot "firesim-timeline"
    $sliceDir = Join-Path $profileRoot "slice-finder-nsys"
    $sliceArgs = @(
        "--cuda-slice-finder",
        "--allow-gpu-kernels",
        "--accept-bugcheck-risk",
        "--profiler-capture",
        "--output-dir=$sliceDir",
        "--frames=3",
        "--scene=$Scene"
    )
    $nsysArgs = @(
        "profile",
        "--capture-range=cudaProfilerApi",
        "--force-overwrite=true",
        "--output=$nsysOut",
        $exePath
    ) + $sliceArgs
    $commands.Add("## Nsight Systems")
    $commands.Add("")
    $commands.Add('```powershell')
    $commands.Add('& "' + $nsys.Source + '" ' + ($nsysArgs -join ' '))
    $commands.Add('```')
    $commands.Add("")
    & $nsys.Source @nsysArgs
    if ($LASTEXITCODE -ne 0) {
        throw "nsys failed with exit code $LASTEXITCODE"
    }
}

if ($Mode -eq "NsightCompute" -or $Mode -eq "All") {
    $ncu = Get-Command ncu.exe,ncu -ErrorAction SilentlyContinue | Select-Object -First 1
    $ncuPath = if ($null -ne $ncu) { $ncu.Source } else { $null }
    if ($null -ne $ncuPath -and [System.IO.Path]::GetExtension($ncuPath).Equals(".bat", [System.StringComparison]::OrdinalIgnoreCase)) {
        $candidate = Join-Path (Split-Path -Parent $ncuPath) "target\windows-desktop-win7-x64\ncu.exe"
        if (Test-Path $candidate) {
            $ncuPath = $candidate
        }
    }
    if ($null -eq $ncuPath) {
        $ncuBat = Get-Command ncu.bat -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $ncuBat) {
            $candidate = Join-Path (Split-Path -Parent $ncuBat.Source) "target\windows-desktop-win7-x64\ncu.exe"
            if (Test-Path $candidate) {
                $ncuPath = $candidate
            } else {
                $ncuPath = $ncuBat.Source
            }
        }
    }
    if ($null -eq $ncuPath) {
        throw "Nsight Compute CLI was not found on PATH. Install Nsight Compute or add ncu.bat to PATH."
    }
    $ncuOut = Join-Path $profileRoot "firesim-speedoflight"
    $ncuArgs = @(
        "--target-processes", "all",
        "--set", $NsightSet,
        "--import-source", "yes",
        "--kernel-name", $KernelRegex,
        "--launch-skip", "$LaunchSkip",
        "--launch-count", "$LaunchCount",
        "--force-overwrite",
        "--export", $ncuOut,
        $exePath
    ) + $simArgs
    $commands.Add("## Nsight Compute")
    $commands.Add("")
    $commands.Add('```powershell')
    $commands.Add('& "' + $ncuPath + '" ' + ($ncuArgs -join ' '))
    $commands.Add('```')
    $commands.Add("")
    & $ncuPath @ncuArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ncu failed with exit code $LASTEXITCODE"
    }
}

if ($Mode -eq "ComputeSanitizer" -or $Mode -eq "All") {
    $sanitizer = Get-Command compute-sanitizer.bat,compute-sanitizer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $sanitizer) {
        throw "Compute Sanitizer was not found on PATH."
    }
    $sanitizerLog = Join-Path $profileRoot "compute-sanitizer-memcheck.log"
    $sanitizerArgs = @(
        "--tool", "memcheck",
        "--log-file", $sanitizerLog,
        $exePath,
        "--cuda-smoke-test",
        "--allow-gpu-kernels",
        "--accept-bugcheck-risk"
    )
    $commands.Add("## Compute Sanitizer")
    $commands.Add("")
    $commands.Add('```powershell')
    $commands.Add('& "' + $sanitizer.Source + '" ' + ($sanitizerArgs -join ' '))
    $commands.Add('```')
    $commands.Add("")
    & $sanitizer.Source @sanitizerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "compute-sanitizer failed with exit code $LASTEXITCODE"
    }
}

$commands.Add("## Worker Benchmark")
$commands.Add("")
$commands.Add('```powershell')
$commands.Add('& "' + $exePath + '" ' + ($simArgs -join ' '))
$commands.Add('```')
$commands.Add("")
$commands.Add("- Benchmark JSON: $benchDir\worker-benchmark.json")
$commands.Add("- Slice finder JSON: $profileRoot\slice-finder\slice-finder.json")
$commands.Add("- Nsight Systems report: $profileRoot\firesim-timeline.nsys-rep")
$commands.Add("- GPU timing summary: $profileRoot\gpu-timing-summary.md")
$commands.Add("- Nsight Compute report: $profileRoot\firesim-speedoflight.ncu-rep")
$commands.Add("- Compute Sanitizer log: $profileRoot\compute-sanitizer-memcheck.log")

$commandPath = Join-Path $profileRoot "profile-commands.md"
$commands | Set-Content -Encoding UTF8 $commandPath
Write-Host "profile command log: $commandPath"
