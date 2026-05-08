$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Require-Text {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Needle,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not $Text.Contains($Needle)) {
        throw $Message
    }
}

function Forbid-Text {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Needle,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if ($Text.Contains($Needle)) {
        throw $Message
    }
}

function Read-RepoText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )
    return Get-Content -LiteralPath (Join-Path $script:RepoRoot $RelativePath) -Raw
}
