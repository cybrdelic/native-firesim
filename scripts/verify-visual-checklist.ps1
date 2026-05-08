$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-helpers.ps1")
$root = Split-Path -Parent $PSScriptRoot
$audit = Read-RepoText "scripts/scene_visual_audit.py"
Require-Text $audit "validation-app-frame.bmp" "visual audit must inspect app-frame captures"
Require-Text $audit "app_metrics" "visual audit app metrics are missing"
Require-Text $audit "uiTopMean" "UI top bar metric is missing"
Require-Text $audit "uiLeftMean" "UI left tools metric is missing"
Require-Text $audit "uiRightMean" "UI right panel metric is missing"
Require-Text $audit "uiBottomMean" "UI bottom bar metric is missing"
Require-Text $audit "gridArtifactScore" "grid artifact score is missing"
Require-Text $audit "warmSmokeFraction" "warm smoke score is missing"
Require-Text $audit "app frame is missing expected UI chrome" "missing UI issue is missing"
Require-Text $audit "GLB or scene content may be missing" "missing GLB/scene issue is missing"
Require-Text $audit "excessive grid/line artifact score" "grid artifact issue is missing"
Require-Text $audit "excessive warm/sepia smoke pixels" "warm smoke issue is missing"
Write-Host "visual checklist gate ok"
