$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$audit = Get-Content (Join-Path $root "scripts/scene_visual_audit.py") -Raw
function Require-Text($text, $needle, $message) { if (-not $text.Contains($needle)) { Write-Error $message } }
Require-Text $audit "def silhouette_issues" "scene silhouette target function is missing"
Require-Text $audit "activeWidthFraction" "active width fraction metric is missing"
Require-Text $audit "activeAspectRatio" "active aspect ratio metric is missing"
Require-Text $audit "activeCenter" "active center metric is missing"
Require-Text $audit "room fire silhouette is not wider than burner source" "room silhouette target is missing"
Require-Text $audit "campfire silhouette is too similar to low room tray flame" "campfire silhouette target is missing"
Require-Text $audit "burner silhouette is too tall compared with campfire" "burner silhouette target is missing"
Require-Text $audit "scene silhouettes share the same centered plume alignment" "shared centered plume target is missing"
Write-Host "scene silhouette target gate ok"
