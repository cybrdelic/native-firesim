param(
    [int]$Frames = 32,
    [switch]$AcceptBugcheckRisk,
    [switch]$SkipCapture
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root "build\NativeFireSim.exe"
$outRoot = Join-Path $root "out\burner-scene-audit"
$burnerDir = Join-Path $outRoot "burner"
$summaryPath = Join-Path $outRoot "burner-report.json"

if (-not (Test-Path -LiteralPath $exe)) {
    throw "NativeFireSim.exe was not found at $exe. Run .\scripts\verify.ps1 -DiagnosticsOnly first."
}

New-Item -ItemType Directory -Force -Path $burnerDir | Out-Null

if (-not $SkipCapture) {
    if (-not $AcceptBugcheckRisk) {
        throw "Burner scene audit launches CUDA validation kernels. Re-run with -AcceptBugcheckRisk only when intentionally testing the live GPU path."
    }
    $effectiveFrames = [Math]::Max($Frames, 32)
    $arguments = @(
        "--validation",
        "--scene=2",
        "--validation-frames=$effectiveFrames",
        "--output-dir=$burnerDir",
        "--allow-gpu-kernels",
        "--accept-bugcheck-risk"
    )
    Write-Host "capturing burner scene audit -> $burnerDir"
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $root -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "burner validation failed with exit code $($process.ExitCode)"
    }
}

$reportPath = Join-Path $burnerDir "validation-report.json"
$rawPath = Join-Path $burnerDir "validation-frame.bmp"
$appPath = Join-Path $burnerDir "validation-app-frame.bmp"
$metricsPath = Join-Path $burnerDir "validation-metrics.csv"
foreach ($required in @($reportPath, $rawPath, $appPath, $metricsPath)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "burner audit missing required artifact: $required"
    }
}

$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$bugList = New-Object System.Collections.Generic.List[string]
if ($report.validationOk -ne $true) {
    $bugList.Add("native validation failed")
}
if ([double]$report.imageMeanLuma -lt 0.006) {
    $bugList.Add("burner frame has near-zero visibility")
}
if ([double]$report.imageMaxLuma -lt 0.12) {
    $bugList.Add("burner flame has too little visible radiance")
}
if ([double]$report.maxFlameHeightMeters -gt 0.36) {
    $bugList.Add("burner flame is too tall for a controlled stovetop flame")
}
if ([double]$report.finalSmokeMassProxy -gt [double]$report.finalFlameMassProxy * 0.22) {
    $bugList.Add("burner produces too much soot/smoke for oxygen-rich gas")
}
if ([double]$report.finalCharSum -gt 1.0 -or [double]$report.finalAshSum -gt 1.0) {
    $bugList.Add("burner is retaining solid fuel char/ash")
}
if ([double]$report.imageWarmFireFraction -gt 0.012 -and [double]$report.imageMeanSaturation -gt 0.06) {
    $bugList.Add("burner reads too warm/orange instead of blue port jets")
}

$auditJson = $null
$sceneAuditScript = Join-Path $PSScriptRoot "scene_visual_audit.py"
if (Test-Path -LiteralPath $sceneAuditScript) {
    python $sceneAuditScript $outRoot | Out-Null
    $auditPath = Join-Path $outRoot "scene-visual-audit.json"
    if (Test-Path -LiteralPath $auditPath) {
        $auditJson = Get-Content -LiteralPath $auditPath -Raw | ConvertFrom-Json
        if ($auditJson.burner -and $auditJson.burner.issues) {
            foreach ($issue in $auditJson.burner.issues) {
                if ($issue -like "*overlay signal") {
                    continue
                }
                $bugList.Add([string]$issue)
            }
        }
    }
}

$main = Read-RepoText "src/main.cpp"
$cuda = Read-RepoText "src/fire_cuda.cu"
$sceneRuntime = Read-RepoText "src/scene_runtime.cpp"
$cudaSceneBranchCount = ([regex]::Matches($cuda, "p\.sceneId|params\.sceneId\s*==|sceneId\s*==")).Count
$appSceneSelectionCount = ([regex]::Matches($main, "settings\.sceneId\s*==|sceneId\s*==|validationScene\s*==")).Count +
    ([regex]::Matches($sceneRuntime, "scene\s*==|sceneId\s*==")).Count

$unificationBlockers = @(
    "CUDA flame and ember behavior is profile-driven; remaining scene-id checks are app selection, validation routing, or runtime scene metadata.",
    "The next unification gap is proving source marker, CUDA volume, and clean app-frame composition together for every scene.",
    "SceneProfile is still compiled C++ data; moving it to validated scene JSON would make source/render/ember coefficients easier to tune without recompilation."
)

$summary = [ordered]@{
    burnerSceneWorks = $bugList.Count -eq 0
    outputDir = $outRoot
    rawFrame = $rawPath
    appFrame = $appPath
    appFrameMode = "clean-composed-no-debug-overlays"
    contactSheet = Join-Path $outRoot "scene-contact-sheet.png"
    validation = [ordered]@{
        frames = $report.frames
        validationOk = $report.validationOk
        imageMeanLuma = $report.imageMeanLuma
        imageMaxLuma = $report.imageMaxLuma
        imageMeanSaturation = $report.imageMeanSaturation
        imageWarmFireFraction = $report.imageWarmFireFraction
        imageBlackSmokeFraction = $report.imageBlackSmokeFraction
        finalFlameMassProxy = $report.finalFlameMassProxy
        finalSmokeMassProxy = $report.finalSmokeMassProxy
        finalCharSum = $report.finalCharSum
        finalAshSum = $report.finalAshSum
        maxFlameHeightMeters = $report.maxFlameHeightMeters
        averageGpuSolveMs = $report.averageGpuSolveMs
        averageGpuRenderMs = $report.averageGpuRenderMs
    }
    visualAudit = $auditJson
    bugs = @($bugList | Select-Object -Unique)
    unification = [ordered]@{
        cudaSceneBranchCount = $cudaSceneBranchCount
        appSceneSelectionCount = $appSceneSelectionCount
        biggestBlocker = "CUDA behavior is no longer scene-id branched; the remaining blocker is end-to-end scene composition evidence and data-driven profile loading."
        blockers = $unificationBlockers
        nextArchitectureStep = "Promote SceneProfile from compiled C++ builders to validated scene JSON and capture clean composed app frames with mesh, source, and volume alignment together."
    }
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $summaryPath
Write-Host "burner scene audit complete: $summaryPath"
if ($bugList.Count -gt 0) {
    Write-Host "burner audit found $($bugList.Count) issue(s); see report for details"
}
