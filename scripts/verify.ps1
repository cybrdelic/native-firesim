param(
    [switch]$CudaSmoke
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$vcvars = "C:\VSBuildTools\VC\Auxiliary\Build\vcvars64.bat"

& (Join-Path $PSScriptRoot "lint.ps1")

if (-not (Test-Path -LiteralPath $vcvars)) {
    throw "Visual Studio Build Tools were not found at $vcvars"
}

$buildCommand = "`"$vcvars`" && cmake -S `"$root`" -B `"$root\build`" -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build `"$root\build`" --config Release"
cmd.exe /c $buildCommand
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Push-Location $root
try {
    & ".\build\NativeFireSim.exe" --diagnostics
    $diagCode = $LASTEXITCODE

    & ".\build\NativeFireSim.exe" --smoke-test
    $cpuCode = $LASTEXITCODE

    & ".\build\NativeFireSim.exe" --input-stress-test
    $inputCode = $LASTEXITCODE

    if ($CudaSmoke) {
        & ".\build\NativeFireSim.exe" --cuda-smoke-test
        $cudaCode = $LASTEXITCODE
    } else {
        $cudaCode = 0
    }
} finally {
    Pop-Location
}

if ($diagCode -ne 0) {
    Write-Error "Diagnostics failed with exit code $diagCode"
    exit $diagCode
}
if ($cpuCode -ne 0) {
    Write-Error "CPU smoke test failed with exit code $cpuCode"
    exit $cpuCode
}
if ($inputCode -ne 0) {
    Write-Error "Input stress test failed with exit code $inputCode"
    exit $inputCode
}
if ($cudaCode -ne 0) {
    Write-Error "CUDA smoke test failed with exit code $cudaCode"
    exit $cudaCode
}

Write-Host "verify ok"
