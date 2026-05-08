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
        $auditRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("native-firesim-slop-audit-" + $PID)
        if (Test-Path -LiteralPath $auditRoot) {
            Remove-Item -LiteralPath $auditRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $auditRoot | Out-Null
        try {
            $textExtensions = @(
                ".bat", ".cmake", ".cpp", ".cu", ".h", ".hpp", ".json", ".md",
                ".ps1", ".py", ".txt", ".yaml", ".yml"
            )
            $textNames = @(
                ".clang-format", ".editorconfig", ".gitattributes", ".gitignore",
                "CMakeLists.txt", "README.md"
            )
            $trackedFiles = git ls-files
            foreach ($file in $trackedFiles) {
                $name = Split-Path -Leaf $file
                $extension = [System.IO.Path]::GetExtension($file)
                if (-not ($textExtensions -contains $extension) -and -not ($textNames -contains $name)) {
                    continue
                }
                $source = Join-Path $root $file
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                    continue
                }
                $destination = Join-Path $auditRoot $file
                $destinationDir = Split-Path -Parent $destination
                if (-not (Test-Path -LiteralPath $destinationDir)) {
                    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
                }
                Copy-Item -LiteralPath $source -Destination $destination
            }
            python $slopScript $auditRoot --format markdown
        } finally {
            if (Test-Path -LiteralPath $auditRoot) {
                Remove-Item -LiteralPath $auditRoot -Recurse -Force
            }
        }
    } else {
        Write-Host "AI slop audit script not found; skipping slop check"
    }
} finally {
    Pop-Location
}
