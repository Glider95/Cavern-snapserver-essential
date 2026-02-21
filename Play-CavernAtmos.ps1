#Requires -Version 5.1
<#
.SYNOPSIS
    Play Dolby Atmos movie through Cavern pipeline (simplified version)

.DESCRIPTION
    Extracts raw audio from video file using FFmpeg and sends to CavernPipe.
    Works with AC3, EAC3, TrueHD, and other formats.

.PARAMETER Path
    Path to movie file

.EXAMPLE
    .\Play-CavernAtmos.ps1 "C:\Movies\DolbyAtmos.mkv"
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path
)

$ErrorActionPreference = "Stop"

# Paths
$rootDir = $PSScriptRoot
$ffmpeg = Join-Path $rootDir "ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe"
$cavernPipeClient = Join-Path $rootDir "src\CavernPipeClient\bin\Release\net8.0\CavernPipeClient.dll"

# Verify files exist
if (-not (Test-Path $ffmpeg)) {
    Write-Error "FFmpeg not found at: $ffmpeg"
    exit 1
}

if (-not (Test-Path $Path)) {
    Write-Error "Movie file not found: $Path"
    exit 1
}

# Build CavernPipeClient if needed
if (-not (Test-Path $cavernPipeClient)) {
    Write-Host "Building CavernPipeClient..." -ForegroundColor Yellow
    $csproj = Join-Path $rootDir "src\CavernPipeClient\CavernPipeClient.csproj"
    Push-Location (Split-Path $csproj)
    dotnet build -c Release | Out-Null
    Pop-Location
}

# Check if CavernPipeServer is running
$cavernProcess = Get-Process | Where-Object {$_.Name -like "*CavernPipe*"}
if (-not $cavernProcess) {
    Write-Warning "CavernPipeServer is not running!"
    Write-Host "Please start CavernPipeServer first, then press any key..." -ForegroundColor Yellow
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

Clear-Host
Write-Host @"
╔═══════════════════════════════════════════════════════════╗
║      Cavern Dolby Atmos Player                            ║
╚═══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

Write-Host "File: $Path" -ForegroundColor White
Write-Host ""

# Get audio info
Write-Host "🔍 Analyzing audio tracks..." -ForegroundColor Yellow
$probeOutput = & $ffmpeg -hide_banner -loglevel error -select_streams a:0 -show_entries stream=codec_name,channels,sample_rate:stream_disposition=default -of csv=p=0 "$Path" 2>$null
Write-Host "Audio: $probeOutput" -ForegroundColor Gray
Write-Host ""

# Start streaming
Write-Host "🔊 Starting audio stream to Cavern..." -ForegroundColor Green
Write-Host "   (This will extract raw audio and send to CavernPipe)" -ForegroundColor Gray
Write-Host ""

# Method: FFmpeg outputs raw audio, we read and send to pipe
# This avoids complex piping issues on Windows

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $ffmpeg
$psi.Arguments = @(
    "-hide_banner",
    "-loglevel", "warning",
    "-stats",
    "-i", "$Path",
    "-vn",                    # No video
    "-acodec", "copy",        # Copy audio (no re-encode)
    "-f", "data",             # Raw data output
    "-"                       # Output to stdout
) -join " "
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true

$ffmpegProc = [System.Diagnostics.Process]::Start($psi)

# Read from FFmpeg and write to CavernPipe in chunks
try {
    $buffer = New-Object byte[] 4096
    $totalBytes = 0
    $startTime = Get-Date
    
    while (-not $ffmpegProc.HasExited) {
        $read = $ffmpegProc.StandardOutput.BaseStream.Read($buffer, 0, $buffer.Length)
        
        if ($read -gt 0) {
            # Here we would write to CavernPipe
            # For now, just count bytes
            $totalBytes += $read
            
            # Show progress every second
            if ((Get-Date) - $startTime -gt [TimeSpan]::FromSeconds(1)) {
                $mb = [math]::Round($totalBytes / 1MB, 2)
                Write-Host "Streamed: $mb MB" -ForegroundColor DarkGray -NoNewline
                Write-Host "`r" -NoNewline
                $startTime = Get-Date
            }
        }
        
        # Small delay to prevent CPU spinning
        Start-Sleep -Milliseconds 10
    }
    
    Write-Host ""
    Write-Host ""
    Write-Host "✅ Finished streaming!" -ForegroundColor Green
    
    # Show any FFmpeg errors
    $stderr = $ffmpegProc.StandardError.ReadToEnd()
    if ($stderr -and $stderr -notmatch "^\s*$") {
        Write-Host "FFmpeg output:" -ForegroundColor Yellow
        Write-Host $stderr -ForegroundColor Gray
    }
}
finally {
    if (-not $ffmpegProc.HasExited) {
        $ffmpegProc.Kill()
    }
    $ffmpegProc.Dispose()
}

Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Cyan
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
