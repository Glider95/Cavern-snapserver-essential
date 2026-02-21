#Requires -Version 5.1
<#
.SYNOPSIS
    Quick start script: Launch emulator and optionally stream a file.
#>
[CmdletBinding()]
param(
    [string]$Path = "",
    [int]$Port = 1704
)

$rootDir = $PSScriptRoot
while ($rootDir -and -not (Test-Path (Join-Path $rootDir "src\Streaming"))) {
    $rootDir = Split-Path -Parent $rootDir
}
if (-not $rootDir) {
    $rootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

# Start emulator in new window
Write-Host "Starting Snapserver Emulator in new window..." -ForegroundColor Cyan
Start-Process powershell -ArgumentList "-NoExit", "-Command", "& '$rootDir\scripts\Start-SnapserverEmulator.ps1' -Port $Port"

if ($Path) {
    Write-Host "Waiting for emulator to start..." -ForegroundColor Yellow
    Start-Sleep -Seconds 2
    
    Write-Host "Starting playback of: $Path" -ForegroundColor Green
    & "$rootDir\scripts\Simple-Stream.ps1" -Path $Path -Port $Port
}
