param(
    [string]$DumpPath = "C:\Windows\Minidump\050126-21062-01.dmp"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root "out"
$localDump = Join-Path $outDir (Split-Path -Leaf $DumpPath)
$analysis = Join-Path $outDir "dump-analysis.txt"
$symbols = "srv*C:\Symbols*https://msdl.microsoft.com/download/symbols"

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Copy-Item -LiteralPath $DumpPath -Destination $localDump -Force

$package = Get-AppxPackage Microsoft.WinDbg | Select-Object -First 1
if (-not $package) {
    throw "Microsoft.WinDbg package is not installed."
}

$cdb = Join-Path $package.InstallLocation "amd64\cdb.exe"
if (-not (Test-Path -LiteralPath $cdb)) {
    throw "cdb.exe was not found at $cdb"
}

& $cdb -y $symbols -z $localDump -c "!analyze -v; kv; lmvm nvlddmkm; lm; q" *> $analysis
exit $LASTEXITCODE
