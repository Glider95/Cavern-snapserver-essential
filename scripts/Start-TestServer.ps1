#Requires -Version 5.1
<#
.SYNOPSIS
    Start a test receiver that mimics snapserver for testing.

.DESCRIPTION
    Starts a test TCP server that receives audio from the streaming pipeline.
    Useful for testing without installing snapserver.

.PARAMETER Port
    TCP port to listen on. Default: 1704

.PARAMETER Output
    Optional: Save received audio to a raw PCM file.

.EXAMPLE
    .\Start-TestServer.ps1

.EXAMPLE
    .\Start-TestServer.ps1 -Port 1804 -Output "test.pcm"
#>
[CmdletBinding()]
param(
    [int]$Port = 1704,
    
    [string]$Output = ""
)

$ErrorActionPreference = "Stop"

# Detect project root (handle nested directory structure)
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
        "RECV" { "Magenta" }
        default { "Cyan" }
    }
    Write-Host "[$timestamp] [$Status] $Message" -ForegroundColor $color
}

Clear-Host
Write-Host @"
╔═══════════════════════════════════════════════════════════╗
║          Cavern Test Receiver                             ║
║          (Snapserver replacement for testing)             ║
╚═══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Yellow

# Build project if needed
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

Write-Status "Port: $Port"
if ($Output) {
    Write-Status "Output file: $Output"
}
Write-Status ""
Write-Status "This is a test receiver - NOT a real snapserver!" "WARN"
Write-Status "To stream to this receiver, run in another window:" "INFO"
Write-Status "  .\Play-AtmosMovie.ps1 -Path 'movie.mkv' -SnapserverPort $Port" "SUCCESS"
Write-Status ""

# Start test receiver
$args = @(
    "test"
    "-p", $Port
)

if ($Output) {
    $args += @("-o", $Output)
}

& dotnet $dllPath @args
