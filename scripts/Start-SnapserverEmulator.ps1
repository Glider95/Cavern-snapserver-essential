#Requires -Version 5.1
<#
.SYNOPSIS
    Start the Snapserver Emulator - a Windows-native replacement for snapserver.

.DESCRIPTION
    Runs a lightweight Snapserver emulator that implements enough of the Snapcast
    protocol to work with real snapclients (ESP32, Android, Linux clients).
    This is the recommended alternative since native Windows builds have issues.

.PARAMETER Port
    TCP port for streaming. Default: 1704

.PARAMETER Channels
    Number of audio channels. Default: 6

.PARAMETER SampleRate
    Sample rate in Hz. Default: 48000

.PARAMETER BitDepth
    Bit depth (16 or 24). Default: 16

.EXAMPLE
    .\Start-SnapserverEmulator.ps1

.EXAMPLE
    .\Start-SnapserverEmulator.ps1 -Port 1704 -Channels 8
#>
[CmdletBinding()]
param(
    [int]$Port = 1704,
    
    [ValidateSet(2, 6, 8)]
    [int]$Channels = 6,
    
    [int]$SampleRate = 48000,
    
    [ValidateSet(16, 24)]
    [int]$BitDepth = 16
)

$ErrorActionPreference = "Stop"

# Detect project root
$script:RootDir = $PSScriptRoot
while ($script:RootDir -and -not (Test-Path (Join-Path $script:RootDir "src\Streaming"))) {
    $script:RootDir = Split-Path -Parent $script:RootDir
}
if (-not $script:RootDir) {
    $script:RootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$script:SrcDir = Join-Path $script:RootDir "src\Streaming"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Status) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        "CLIENT" { "Magenta" }
        default { "Cyan" }
    }
    Write-Host "[$timestamp] [$Status] $Message" -ForegroundColor $color
}

Clear-Host
Write-Host @"
╔═══════════════════════════════════════════════════════════╗
║          Snapserver Emulator for Windows                  ║
║          (Native Windows Snapserver Replacement)          ║
╚═══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Status "This is a lightweight Snapserver replacement for Windows." "SUCCESS"
Write-Status "It works with real snapclients (ESP32, Android, Linux)!" "SUCCESS"
Write-Status ""

# Build if needed
$dllPath = Join-Path $script:SrcDir "bin\Release\net8.0\CavernSnapcastStreaming.dll"
if (-not (Test-Path $dllPath)) {
    Write-Status "Building project..."
    Push-Location $script:SrcDir
    try {
        dotnet build --configuration Release | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed"
        }
    }
    finally {
        Pop-Location
    }
}

# Get IP addresses for client connection info
try {
    $ipAddresses = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | 
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -ExpandProperty IPAddress)
} catch {
    # Fallback to ipconfig
    $ipAddresses = @()
}

Write-Status "Configuration:"
Write-Status "  TCP Port:  $Port (streaming)"
Write-Status "  HTTP Port: $($Port + 76) (web control)"
Write-Status "  RPC Port:  $($Port + 1) (JSON-RPC)"
Write-Status "  Format:    $Channels ch @ $SampleRate Hz, $BitDepth-bit"
Write-Status ""
Write-Status "Server IP addresses:"
if ($ipAddresses -and $ipAddresses.Count -gt 0) {
    $ipAddresses | ForEach-Object { Write-Status "  $_" "SUCCESS" }
    $firstIp = $ipAddresses | Select-Object -First 1
} else {
    Write-Status "  (Run 'ipconfig' to see your IP addresses)" "WARN"
    $firstIp = "YOUR_IP_ADDRESS"
}
Write-Status ""
Write-Status "Connect snapclients with:"
Write-Status "  snapclient -h $firstIp -p $Port" "CLIENT"
Write-Status ""
Write-Status "Or stream audio from another terminal:"
Write-Status "  .\Play-AtmosMovie.ps1 -Path 'movie.mkv' -SnapserverPort $Port"
Write-Status ""

# Run emulator
$args = @(
    "emulator"
    "-p", $Port
    "-c", $Channels
    "-r", $SampleRate
    "-b", $BitDepth
)

& dotnet $dllPath @args
