#Requires -Version 5.1
<#
.SYNOPSIS
    Simple streaming script that pipes FFmpeg directly to the snapserver emulator.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    
    [int]$Port = 1704,
    
    [ValidateSet(2, 6, 8)]
    [int]$Channels = 6,
    
    [int]$SampleRate = 48000,
    
    [ValidateSet(16, 24)]
    [int]$BitDepth = 16,
    
    [int]$Duration = 0  # 0 = full file, otherwise seconds for testing
)

$ErrorActionPreference = "Stop"

# Find project root
$rootDir = $PSScriptRoot
while ($rootDir -and -not (Test-Path (Join-Path $rootDir "src\Streaming"))) {
    $rootDir = Split-Path -Parent $rootDir
}
if (-not $rootDir) {
    $rootDir = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$srcDir = Join-Path $rootDir "src\Streaming"
$dllPath = Join-Path $srcDir "bin\Release\net8.0\CavernSnapcastStreaming.dll"

# Store the input file path
$inputFile = $Path

# Find FFmpeg
$ffmpegPaths = @(
    (Join-Path $rootDir "ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe")
    (Join-Path (Split-Path -Parent $rootDir) "ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe")
    "ffmpeg.exe"  # PATH
)

$ffmpeg = $null
foreach ($ffPath in $ffmpegPaths) {
    $resolved = Resolve-Path $ffPath -ErrorAction SilentlyContinue
    if ($resolved -and (Test-Path $resolved)) {
        $ffmpeg = $resolved.Path
        break
    }
}

if (-not $ffmpeg) {
    Write-Error "FFmpeg not found!"
    exit 1
}

if (-not (Test-Path $inputFile)) {
    Write-Error "Input file not found: $inputFile"
    exit 1
}

Write-Host "FFmpeg: $ffmpeg" -ForegroundColor Cyan
Write-Host "Streaming: $inputFile" -ForegroundColor Cyan
Write-Host "To: localhost:$Port ($Channels ch @ ${SampleRate}Hz)" -ForegroundColor Cyan
Write-Host ""

# Test connection to emulator first
Write-Host "Testing connection to emulator on port $Port..." -ForegroundColor Yellow
$testConnection = Test-NetConnection -ComputerName localhost -Port $Port -WarningAction SilentlyContinue
if (-not $testConnection.TcpTestSucceeded) {
    Write-Error "Cannot connect to emulator on port $Port! Is it running?"
    Write-Host "Start the emulator first with: .\Start-SnapserverEmulator.ps1" -ForegroundColor Yellow
    exit 1
}
Write-Host "Connection OK!`n" -ForegroundColor Green

# Build FFmpeg args
$ffArgs = @(
    "-hide_banner"
    "-loglevel", "warning"  # Show warnings to diagnose issues
    "-stats"
)

if ($Duration -gt 0) {
    $ffArgs += @("-t", $Duration)
}

$ffArgs += @(
    "-i", "$inputFile"
    "-vn"
    "-acodec", "pcm_s${BitDepth}le"
    "-ar", $SampleRate
    "-ac", $Channels
    "-f", "s${BitDepth}le"
    "-"
)

# Build streaming args
$streamArgs = @(
    "stream"
    "-c", $Channels
    "-r", $SampleRate
    "-b", $BitDepth
    "-h", "localhost"
    "-p", $Port
)

# Start processes
Write-Host "Starting FFmpeg..." -ForegroundColor Yellow
$ffmpegPsi = New-Object System.Diagnostics.ProcessStartInfo
$ffmpegPsi.FileName = $ffmpeg
$ffmpegPsi.Arguments = $ffArgs -join " "
$ffmpegPsi.RedirectStandardOutput = $true
$ffmpegPsi.RedirectStandardError = $true
$ffmpegPsi.UseShellExecute = $false
$ffmpegPsi.CreateNoWindow = $true

$ffmpegProc = [System.Diagnostics.Process]::Start($ffmpegPsi)

Write-Host "Starting Streamer..." -ForegroundColor Yellow
$streamPsi = New-Object System.Diagnostics.ProcessStartInfo
$streamPsi.FileName = "dotnet"
$streamPsi.Arguments = "$dllPath $($streamArgs -join ' ')"
$streamPsi.RedirectStandardInput = $true
$streamPsi.RedirectStandardOutput = $true
$streamPsi.RedirectStandardError = $true
$streamPsi.UseShellExecute = $false
$streamPsi.CreateNoWindow = $true

$streamProc = [System.Diagnostics.Process]::Start($streamPsi)

# Handle async copying and output
$copyJob = Start-Job -ScriptBlock {
    param($ffmpegOut, $streamIn)
    try {
        $buffer = New-Object byte[] 8192
        while (($read = $ffmpegOut.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $streamIn.Write($buffer, 0, $read)
            $streamIn.Flush()
        }
    } catch {
        # Pipe closed
    }
} -ArgumentList $ffmpegProc.StandardOutput.BaseStream, $streamProc.StandardInput.BaseStream

# Display FFmpeg stats
$stderrJob = Start-Job -ScriptBlock {
    param($stderr)
    while ($line = $stderr.ReadLine()) {
        if ($line -match "size=|time=") {
            Write-Host "[FFmpeg] $line" -ForegroundColor DarkGray
        }
    }
} -ArgumentList $ffmpegProc.StandardError

# Display Streamer output
$stdoutJob = Start-Job -ScriptBlock {
    param($stdout)
    while ($line = $stdout.ReadLine()) {
        Write-Host "[Streamer] $line" -ForegroundColor Cyan
    }
} -ArgumentList $streamProc.StandardOutput

$stderrStreamJob = Start-Job -ScriptBlock {
    param($stderr)
    while ($line = $stderr.ReadLine()) {
        Write-Host "[Streamer] $line" -ForegroundColor Red
    }
} -ArgumentList $streamProc.StandardError

Write-Host "`nStreaming... Press Ctrl+C to stop`n" -ForegroundColor Green

# Check if processes started correctly
if ($ffmpegProc.HasExited) {
    $errorOutput = $ffmpegProc.StandardError.ReadToEnd()
    Write-Host "`nFFmpeg failed immediately!" -ForegroundColor Red
    Write-Host "Exit code: $($ffmpegProc.ExitCode)" -ForegroundColor Red
    Write-Host "Error: $errorOutput" -ForegroundColor Red
    exit 1
}

if ($streamProc.HasExited) {
    $errorOutput = $streamProc.StandardError.ReadToEnd()
    Write-Host "`nStreamer failed immediately!" -ForegroundColor Red
    Write-Host "Exit code: $($streamProc.ExitCode)" -ForegroundColor Red
    Write-Host "Error: $errorOutput" -ForegroundColor Red
    exit 1
}

# Wait for FFmpeg to finish or user to cancel
try {
    $startTime = Get-Date
    while (-not $ffmpegProc.HasExited) {
        Start-Sleep -Milliseconds 100
        
        # Show status every 5 seconds
        if (((Get-Date) - $startTime).TotalSeconds -gt 5) {
            Write-Host "Still streaming... ($([math]::Round(((Get-Date) - $startTime).TotalSeconds))s)" -ForegroundColor DarkGray
            $startTime = Get-Date
        }
    }
    Write-Host "`nFFmpeg finished." -ForegroundColor Yellow
} finally {
    # Cleanup
    Stop-Job $copyJob, $stderrJob, $stdoutJob, $stderrStreamJob -ErrorAction SilentlyContinue
    Remove-Job $copyJob, $stderrJob, $stdoutJob, $stderrStreamJob -ErrorAction SilentlyContinue
    
    if (-not $ffmpegProc.HasExited) { $ffmpegProc.Kill() }
    if (-not $streamProc.HasExited) { $streamProc.Kill() }
    
    $ffmpegProc.Dispose()
    $streamProc.Dispose()
}

Write-Host "Done!" -ForegroundColor Green
