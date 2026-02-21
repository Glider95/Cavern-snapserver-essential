#Requires -Version 5.1
<#
.SYNOPSIS
    Start Cavern-Snapcast streaming pipeline on Windows.

.DESCRIPTION
    Starts the complete pipeline: NamedPipe server and Snapserver connection
    for Dolby Atmos streaming on Windows.

.PARAMETER Channels
    Number of output channels (2, 6, or 8). Default: 6

.PARAMETER SampleRate
    Sample rate in Hz. Default: 48000

.PARAMETER BitDepth
    Bit depth (16 or 24). Default: 16

.PARAMETER SnapserverHost
    Snapserver hostname. Default: localhost

.PARAMETER SnapserverPort
    Snapserver port. Default: 1704

.PARAMETER SnapserverPath
    Path to snapserver.exe. Auto-detected if not specified.

.PARAMETER NoSnapserver
    Don't try to start snapserver (assume it's already running).

.EXAMPLE
    .\Start-CavernStreaming.ps1

.EXAMPLE
    .\Start-CavernStreaming.ps1 -Channels 8 -SampleRate 96000

.EXAMPLE
    .\Start-CavernStreaming.ps1 -SnapserverHost 192.168.1.100
#>
[CmdletBinding()]
param(
    [ValidateSet(2, 6, 8)]
    [int]$Channels = 6,
    
    [int]$SampleRate = 48000,
    
    [ValidateSet(16, 24)]
    [int]$BitDepth = 16,
    
    [string]$SnapserverHost = "localhost",
    
    [int]$SnapserverPort = 1704,
    
    [string]$SnapserverPath = "",
    
    [switch]$NoSnapserver
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

$script:LogDir = Join-Path $script:RootDir "logs"
$script:SrcDir = Join-Path $script:RootDir "src\Streaming"

# Ensure log directory exists
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null

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

function Test-Snapserver {
    try {
        $conn = Test-NetConnection -ComputerName $SnapserverHost -Port $SnapserverPort -WarningAction SilentlyContinue
        return $conn.TcpTestSucceeded
    }
    catch {
        return $false
    }
}

function Find-Snapserver {
    $possiblePaths = @(
        "C:\Program Files\Snapcast\snapserver.exe"
        "C:\Program Files (x86)\Snapcast\snapserver.exe"
        "$env:LOCALAPPDATA\Snapcast\snapserver.exe"
        "$env:USERPROFILE\scoop\shims\snapserver.exe"
        "$env:USERPROFILE\bin\snapserver.exe"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # Try PATH
    $inPath = Get-Command snapserver.exe -ErrorAction SilentlyContinue
    if ($inPath) {
        return $inPath.Source
    }
    
    return $null
}

function Start-SnapserverProcess {
    if ($NoSnapserver) {
        Write-Status "Skipping snapserver startup (NoSnapserver specified)" "WARN"
        return
    }
    
    # Check if already running
    $existing = Get-Process -Name "snapserver" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Status "Snapserver already running (PID: $($existing.Id))" "SUCCESS"
        return
    }
    
    # Find snapserver
    $exePath = if ($SnapserverPath) { $SnapserverPath } else { Find-Snapserver }
    
    if (-not $exePath) {
        Write-Status "Snapserver not found. Please install it or specify -SnapserverPath" "ERROR"
        Write-Status "Download from: https://github.com/badaix/snapcast/releases" "INFO"
        exit 1
    }
    
    Write-Status "Found snapserver: $exePath"
    
    # Create config file
    $configPath = Join-Path $env:TEMP "snapserver-cavern.conf"
    $codec = if ($Channels -le 8) { "flac" } else { "pcm" }
    $sampleFormat = "$SampleRate`:$BitDepth`:$Channels"
    
    $configContent = @"
# Snapserver configuration for Cavern
# Auto-generated on $(Get-Date)

[stream]
source = tcp://0.0.0.0:$($SnapserverPort + 100)?name=Cavern&codec=$codec&sampleformat=$sampleFormat

[http]
enabled = true
port = 1780

[tcp]
enabled = true
port = 1705

[server]
port = $SnapserverPort
codec = $codec
buffer = 2000
send_to_muted = false

[logging]
sink = stderr
"@
    
    $configContent | Out-File -FilePath $configPath -Encoding UTF8 -Force
    Write-Status "Created config: $configPath"
    
    # Start snapserver
    $logFile = Join-Path $script:LogDir "snapserver.log"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.Arguments = "-c `"$configPath`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    
    $process = [System.Diagnostics.Process]::Start($psi)
    
    # Redirect output to log file
    $process.StandardOutput.ReadToEndAsync() | Out-Null
    $process.StandardError.ReadToEndAsync() | Out-File -FilePath $logFile -Append
    
    Write-Status "Started snapserver (PID: $($process.Id))"
    
    # Wait for it to be ready
    Write-Status "Waiting for snapserver to be ready..."
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-Snapserver) {
            Write-Status "Snapserver ready on port $SnapserverPort" "SUCCESS"
            return
        }
    }
    
    Write-Status "Timeout waiting for snapserver" "WARN"
}

function Build-Project {
    $dllPath = Join-Path $script:SrcDir "bin\Release\net8.0\CavernSnapcastStreaming.dll"
    
    if (Test-Path $dllPath) {
        Write-Status "Project already built"
        return
    }
    
    Write-Status "Building project..."
    Push-Location $script:SrcDir
    try {
        dotnet build --configuration Release
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed"
        }
        Write-Status "Build successful" "SUCCESS"
    }
    finally {
        Pop-Location
    }
}

function Start-StreamingPipeline {
    Write-Status "Starting Cavern streaming pipeline..."
    Write-Status "Configuration: $Channels ch @ $SampleRate Hz, $BitDepth-bit"
    
    $dllPath = Join-Path $script:SrcDir "bin\Release\net8.0\CavernSnapcastStreaming.dll"
    
    if (-not (Test-Path $dllPath)) {
        Write-Status "Streaming DLL not found. Building..." "WARN"
        Build-Project
    }
    
    $args = @(
        "server"
        "-c", $Channels
        "-r", $SampleRate
        "-b", $BitDepth
        "-h", $SnapserverHost
        "-p", $SnapserverPort
    )
    
    if ($SnapserverPath) {
        $args += @("--snapserver", $SnapserverPath)
    }
    
    Write-Status "Starting: dotnet $dllPath $args"
    
    try {
        & dotnet $dllPath @args
    }
    catch {
        Write-Status "Streaming error: $_" "ERROR"
    }
}

# Main execution
Clear-Host
Write-Host @"
╔═══════════════════════════════════════════════════════════╗
║     Cavern-Snapcast Streaming Pipeline for Windows        ║
╠═══════════════════════════════════════════════════════════╣
║                                                           ║
║  This pipeline enables Dolby Atmos streaming to Snapcast  ║
║  clients via Windows Named Pipes and TCP streaming.       ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Status "Root directory: $script:RootDir"
Write-Status "Log directory: $script:LogDir"

# Check prerequisites
Write-Status "Checking prerequisites..."
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Status ".NET SDK not found. Please install .NET 8.0 SDK" "ERROR"
    exit 1
}

# Start components
Start-SnapserverProcess
Build-Project
Start-StreamingPipeline

Write-Status "Pipeline stopped"
