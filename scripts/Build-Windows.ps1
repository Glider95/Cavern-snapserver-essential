#Requires -Version 5.1
<#
.SYNOPSIS
    Build the Cavern-Snapcast streaming components for Windows.

.DESCRIPTION
    Builds the .NET projects required for Dolby Atmos streaming on Windows.

.EXAMPLE
    .\Build-Windows.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# Detect project root (handle nested directory structure)
$script:RootDir = $PSScriptRoot
while ($script:RootDir -and -not (Test-Path (Join-Path $script:RootDir "src\Streaming"))) {
    $script:RootDir = Split-Path -Parent $script:RootDir
}
if (-not $script:RootDir) {
    $script:RootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Status) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "Cyan" }
    }
    Write-Host "[$timestamp] [$Status] $Message" -ForegroundColor $color
}

Write-Status "Building Cavern-Snapcast Streaming for Windows..."
Write-Status "Root directory: $script:RootDir"

# Check prerequisites
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Status ".NET 8.0 SDK is required but not found!" "ERROR"
    Write-Status "Download from: https://dotnet.microsoft.com/download" "INFO"
    exit 1
}

$dotnetVersion = dotnet --version
Write-Status "Found .NET SDK: $dotnetVersion"

# Build Streaming project
$streamingDir = Join-Path $script:RootDir "src\Streaming"
if (Test-Path $streamingDir) {
    Write-Status "Building Streaming project..."
    Push-Location $streamingDir
    try {
        dotnet restore
        dotnet build --configuration Release
        
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed"
        }
        
        Write-Status "Streaming project built successfully" "SUCCESS"
    }
    finally {
        Pop-Location
    }
}

# Build CavernPipeClient (for compatibility)
$clientDir = Join-Path $script:RootDir "src\CavernPipeClient"
if (Test-Path $clientDir) {
    Write-Status "Building CavernPipeClient..."
    Push-Location $clientDir
    try {
        dotnet build --configuration Release
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "CavernPipeClient built successfully" "SUCCESS"
        }
    }
    finally {
        Pop-Location
    }
}

# Build PipeToFifo (for compatibility)
$fifoDir = Join-Path $script:RootDir "src\PipeToFifo"
if (Test-Path $fifoDir) {
    Write-Status "Building PipeToFifo..."
    Push-Location $fifoDir
    try {
        dotnet build --configuration Release
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "PipeToFifo built successfully" "SUCCESS"
        }
    }
    finally {
        Pop-Location
    }
}

# Summary
Write-Status ""
Write-Status "═══════════════════════════════════════════════════════════"
Write-Status "Build completed!"
Write-Status "═══════════════════════════════════════════════════════════"
Write-Status ""
Write-Status "Next steps:"
Write-Status "  1. Install Snapserver: https://github.com/badaix/snapcast/releases"
Write-Status "  2. Start streaming: .\Start-CavernStreaming.ps1"
Write-Status "  3. Play a movie: .\Play-AtmosMovie.ps1 -Path 'C:\Movies\movie.mkv'"
Write-Status ""
