param(
    [switch]$NoRestartMessage
)

$ErrorActionPreference = "Stop"

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    throw "Run this script from an elevated PowerShell session."
}

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root "out"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$logPath = Join-Path $outDir "gpu-recovery-settings.log"
Start-Transcript -Path $logPath -Append | Out-Null

$snapshot = [ordered]@{
    Timestamp = (Get-Date).ToString("o")
    EdgeUserHardwareAccelerationPolicy = (Get-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Edge" -Name HardwareAccelerationModeEnabled -ErrorAction SilentlyContinue).HardwareAccelerationModeEnabled
    EdgeMachineHardwareAccelerationPolicy = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name HardwareAccelerationModeEnabled -ErrorAction SilentlyContinue).HardwareAccelerationModeEnabled
    HagsHwSchMode = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
}

$snapshot | ConvertTo-Json | Set-Content -Path (Join-Path $outDir "gpu-recovery-before-elevated.json") -Encoding UTF8

New-Item -Path "HKCU:\Software\Policies\Microsoft\Edge" -Force | Out-Null
New-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Edge" -Name HardwareAccelerationModeEnabled -PropertyType DWord -Value 0 -Force | Out-Null

New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name HardwareAccelerationModeEnabled -PropertyType DWord -Value 0 -Force | Out-Null

New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -PropertyType DWord -Value 1 -Force | Out-Null

$result = [ordered]@{
    Timestamp = (Get-Date).ToString("o")
    EdgeUserHardwareAccelerationPolicy = (Get-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Edge" -Name HardwareAccelerationModeEnabled -ErrorAction SilentlyContinue).HardwareAccelerationModeEnabled
    EdgeMachineHardwareAccelerationPolicy = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Edge" -Name HardwareAccelerationModeEnabled -ErrorAction SilentlyContinue).HardwareAccelerationModeEnabled
    HagsHwSchMode = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
}

$result | ConvertTo-Json | Set-Content -Path (Join-Path $outDir "gpu-recovery-after-elevated.json") -Encoding UTF8
$result | ConvertTo-Json

if (-not $NoRestartMessage) {
    Write-Host "Restart Windows for the hardware scheduling setting to take effect."
}

Stop-Transcript | Out-Null
