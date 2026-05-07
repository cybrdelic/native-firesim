$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$script = Get-Content (Join-Path $root "scripts/compare_visual_frames.py") -Raw
function Require-Text($text, $needle, $message) { if (-not $text.Contains($needle)) { Write-Error $message } }
Require-Text $script "meanAbsDelta" "visual diff must report mean absolute delta"
Require-Text $script "meanLumaDelta" "visual diff must report mean luma delta"
Require-Text $script "changedPixelFraction" "visual diff must report changed pixel fraction"
Require-Text $script "minChangedFraction" "visual diff must record threshold"
Require-Text $script "difference.png" "visual diff must emit a difference image"
Require-Text $script "visual-diff.md" "visual diff must emit PR-ready markdown"
Write-Host "before-after pixel proof gate ok"
