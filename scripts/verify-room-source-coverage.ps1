$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$cuda = Get-Content (Join-Path $root "src/fire_cuda.cu") -Raw
function Require-Text($text, $needle, $message) { if (-not $text.Contains($needle)) { Write-Error $message } }
Require-Text $cuda "roomTraySheet" "room source coverage must add a room-only lower tray sheet term"
Require-Text $cuda "roomCoverageBoost" "room source coverage must boost scene 0 coverage explicitly"
Require-Text $cuda "smoothstepf(1.08f, 0.030f, fabsf(x))" "room tray width must be widened"
Require-Text $cuda "smoothstepf(0.56f, 0.026f, fabsf(z))" "room tray depth must be widened"
Require-Text $cuda "0.058f + chunkNoise * 0.028f" "room pyrolysis seed must be increased"
Write-Host "room source coverage gate ok"
