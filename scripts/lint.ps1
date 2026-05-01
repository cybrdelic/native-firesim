$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    git diff --check
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    $clangFormat = Get-Command clang-format -ErrorAction SilentlyContinue
    if ($clangFormat) {
        $files = git ls-files '*.cpp' '*.h' '*.cu'
        foreach ($file in $files) {
            & $clangFormat.Source --dry-run --Werror $file
        }
    } else {
        Write-Host "clang-format not found; skipping format check"
    }

    $slopScript = "C:\Users\alexf\.codex\plugins\cache\alexf-local\ai-slop-audit\0.1.0\scripts\ai_slop_check.py"
    if (Test-Path -LiteralPath $slopScript) {
        python $slopScript $root --format markdown
    } else {
        Write-Host "AI slop audit script not found; skipping slop check"
    }
} finally {
    Pop-Location
}
