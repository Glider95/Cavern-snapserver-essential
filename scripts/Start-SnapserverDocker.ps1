#Requires -Version 5.1
<#
.SYNOPSIS
    Run Snapserver in Docker on Windows (easier than native build).

.DESCRIPTION
    Uses Docker Desktop/WSL2 to run Snapserver. This is much easier than
    trying to compile natively on Windows.

.PARAMETER Port
    Snapserver port. Default: 1704

.PARAMETER DataDir
    Directory for persistent data. Default: ~/.snapcast

.EXAMPLE
    .\Start-SnapserverDocker.ps1

.EXAMPLE
    .\Start-SnapserverDocker.ps1 -Port 1704 -DataDir "C:\snapcast"
#>
[CmdletBinding()]
param(
    [int]$Port = 1704,
    [string]$DataDir = ""
)

$ErrorActionPreference = "Stop"

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

# Check Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Status "Docker not found. Please install Docker Desktop:" "ERROR"
    Write-Status "  https://www.docker.com/products/docker-desktop" "INFO"
    exit 1
}

# Set data directory
if (-not $DataDir) {
    $DataDir = Join-Path $env:USERPROFILE ".snapcast"
}
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

$rootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$dockerfile = Join-Path $rootDir "docker\Dockerfile.snapserver"

Write-Status "Running Snapserver in Docker..."
Write-Status "Data directory: $DataDir"
Write-Status "Port: $Port"

# Check if image exists, build if not
$imageExists = docker images snapserver:latest -q 2>$null
if (-not $imageExists) {
    Write-Status "Building Docker image (this may take several minutes)..."
    if (Test-Path $dockerfile) {
        docker build -t snapserver:latest -f $dockerfile $rootDir
    } else {
        # Use pre-built image
        Write-Status "Using pre-built image..."
        docker pull badai/snapserver:latest
        $imageTag = "badai/snapserver:latest"
    }
} else {
    Write-Status "Using existing image"
}

# Create config
$configPath = Join-Path $DataDir "snapserver.conf"
if (-not (Test-Path $configPath)) {
    @"
[stream]
source = tcp://0.0.0.0:1705?name=Default&codec=flac&sampleformat=48000:16:2

[http]
enabled = true
port = 1780

[tcp]
enabled = true
port = 1705

[server]
port = 1704
buffer = 1000

codec = flac
sampleformat = 48000:16:2

[logging]
sink = stdout
"@ | Out-File -FilePath $configPath -Encoding UTF8
}

# Run container
Write-Status "Starting container..."
docker run --rm -it `
    --name snapserver `
    -p ${Port}:1704 `
    -p 1705:1705 `
    -p 1780:1780 `
    -v "${DataDir}:/data" `
    snapserver:latest `
    -c /data/snapserver.conf

Write-Status "Snapserver stopped"
