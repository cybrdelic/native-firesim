$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$main = Get-Content (Join-Path $root "src/main.cpp") -Raw
$sceneRuntime = Get-Content (Join-Path $root "src/scene_runtime.h") -Raw
$diag = Join-Path $root "out\diagnostics\startup.txt"
function Require-Text($text, $needle, $message) { if (-not $text.Contains($needle)) { Write-Error $message } }
Require-Text $main "drawProjectedBoxOverlay" "projected box overlay helper is missing"
Require-Text $main '"VOLUME"' "volume bounds overlay is missing"
Require-Text $main '"FUEL BED"' "fuel-bed bounds overlay is missing"
Require-Text $main '"GLB BOUNDS"' "GLB bounds overlay is missing"
Require-Text $main '"FRAME AGE %llums  RING %ld>%ld"' "frame age and ring freshness overlay is missing"
Require-Text $main '"SRC ACTIVE"' "selected burner/source overlay is missing"
Require-Text $sceneRuntime "struct PlacementCoordinateState" "central placement coordinate state is missing"
Require-Text $main "g_placement.scene(scene)" "source placement is not read from the central placement state"
Require-Text $main "g_placement.scene(scene).meshOffset" "mesh placement is not read from the central placement state"
Require-Text $main "sceneSourceWorld" "source placement world coordinates are not centralized"
Require-Text $main "applyPlacementOverrides(settings)" "placement debug offsets are not applied to CUDA source settings"
Require-Text $main "MeshOffset.xyz" "placement debug offsets are not applied to GLTF mesh vertices"
Require-Text $main "copyPlacementToClipboard" "placement debug coordinates cannot be copied"
Require-Text $main '"SRC XYZ %.3f %.3f %.3f"' "placement debug source coordinate readout is missing"
Require-Text $main "hitTestPlacementHandle" "placement debug handles cannot be selected directly"
Require-Text $main "beginPlacementDrag" "placement debug drag start is missing"
Require-Text $main "updatePlacementDrag" "placement debug drag update is missing"
Require-Text $main '"DRAG CENTER XZ"' "placement debug drag help is missing"
Require-Text $main "debugOverlaySystem=source markers, selected burner ports, GLB bounds, volume bounds, fuel-bed bounds, origin axes, frame age, and texture ring freshness" "diagnostics debug overlay string is missing from source"
if (Test-Path $diag) {
    $diagText = Get-Content $diag -Raw
    Require-Text $diagText "debugOverlaySystem=source markers, selected burner ports, GLB bounds, volume bounds, fuel-bed bounds, origin axes, frame age, and texture ring freshness" "diagnostics do not report debug overlay system"
}
Write-Host "debug overlay gate ok"
