$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$main = Get-Content (Join-Path $root "src/main.cpp") -Raw
$diag = Join-Path $root "out\diagnostics\startup.txt"
function Require-Text($text, $needle, $message) { if (-not $text.Contains($needle)) { Write-Error $message } }
Require-Text $main "drawProjectedBoxOverlay" "projected box overlay helper is missing"
Require-Text $main '"VOLUME"' "volume bounds overlay is missing"
Require-Text $main '"FUEL BED"' "fuel-bed bounds overlay is missing"
Require-Text $main '"GLB BOUNDS"' "GLB bounds overlay is missing"
Require-Text $main '"FRAME AGE %llums  RING %ld>%ld"' "frame age and ring freshness overlay is missing"
Require-Text $main '"SRC ACTIVE"' "selected burner/source overlay is missing"
Require-Text $main "debugOverlaySystem=source markers, selected burner ports, GLB bounds, volume bounds, fuel-bed bounds, origin axes, frame age, and texture ring freshness" "diagnostics debug overlay string is missing from source"
if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "debugOverlaySystem=source markers, selected burner ports, GLB bounds, volume bounds, fuel-bed bounds, origin axes, frame age, and texture ring freshness" "diagnostics do not report debug overlay system"
}
Write-Host "debug overlay gate ok"
