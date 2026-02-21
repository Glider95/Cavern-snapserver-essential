#Requires -Version 5.1
<#
.SYNOPSIS
    Play a Dolby Atmos movie through the Cavern-Snapcast pipeline.

.DESCRIPTION
    Plays media files (TrueHD, E-AC-3, DTS, or regular files) through the
    Cavern spatial audio engine and streams to Snapcast clients.

.PARAMETER Path
    Path to the media file to play.

.PARAMETER Channels
    Number of output channels (2, 6, or 8). Default: 6

.PARAMETER SampleRate
    Sample rate in Hz. Default: 48000

.PARAMETER BitDepth
    Bit depth (16 or 24). Default: 16

.PARAMETER StartTime
    Start playback at specified time (HH:MM:SS format).

.PARAMETER SnapserverHost
    Snapserver hostname. Default: localhost

.PARAMETER SnapserverPort
    Snapserver port. Default: 1704

.PARAMETER CacheDir
    Directory for cached DAMF files. Default: ~/.cavern-wireless/cache

.EXAMPLE
    .\Play-AtmosMovie.ps1 -Path "C:\Movies\AtmosMovie.mkv"

.EXAMPLE
    .\Play-AtmosMovie.ps1 -Path "movie.mkv" -Channels 8 -StartTime "00:10:00"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias("File")]
    [string]$Path,
    
    [ValidateSet(2, 6, 8)]
    [int]$Channels = 6,
    
    [int]$SampleRate = 48000,
    
    [ValidateSet(16, 24)]
    [int]$BitDepth = 16,
    
    [string]$StartTime = "",
    
    [string]$SnapserverHost = "localhost",
    
    [int]$SnapserverPort = 1704,
    
    [string]$CacheDir = ""
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
$script:FfmpegDir = Join-Path $script:RootDir "ffmpeg-8.0.1-essentials_build\bin"

# Default cache directory
if (-not $CacheDir) {
    $CacheDir = Join-Path $env:USERPROFILE ".cavern-wireless\cache"
}

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Status) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        "PLAY" { "Magenta" }
        default { "Cyan" }
    }
    Write-Host "[$timestamp] [$Status] $Message" -ForegroundColor $color
}

function Find-FFmpeg {
    # Check multiple possible locations for ffmpeg
    $possiblePaths = @(
        # Direct in script folder
        (Join-Path $script:RootDir "ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe")
        # In parent folder (common structure)
        (Join-Path (Split-Path -Parent $script:RootDir) "ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe")
        # Two levels up
        (Join-Path (Split-Path -Parent (Split-Path -Parent $script:RootDir)) "ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe")
        # In src folder
        (Join-Path $script:SrcDir "..\..\ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe")
    )
    
    foreach ($path in $possiblePaths) {
        $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
        if ($resolved -and (Test-Path $resolved)) {
            return $resolved.Path
        }
    }
    
    # Try PATH
    $inPath = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($inPath) {
        return $inPath.Source
    }
    
    return $null
}

function Find-Truehdd {
    $possiblePaths = @(
        Join-Path $script:RootDir "bin\truehdd.exe"
        Join-Path $script:RootDir "tools\truehdd.exe"
        "C:\tools\truehdd.exe"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            return $path
        }
    }
    
    # Try PATH
    $inPath = Get-Command truehdd.exe -ErrorAction SilentlyContinue
    if ($inPath) {
        return $inPath.Source
    }
    
    return $null
}

function Get-FileHash {
    param([string]$FilePath)
    
    $hash = Get-FileHash -Path $FilePath -Algorithm MD5
    return $hash.Hash.ToLower()
}

function Get-AudioCodec {
    param([string]$FilePath)
    
    $ffmpeg = Find-FFmpeg
    if (-not $ffmpeg) {
        return "unknown"
    }
    
    try {
        $output = & $ffmpeg -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 $FilePath 2>&1
        return $output.Trim()
    }
    catch {
        return "unknown"
    }
}

function Convert-TrueHDToDAMF {
    param(
        [string]$InputFile,
        [string]$OutputFile
    )
    
    $truehdd = Find-Truehdd
    
    if (-not $truehdd) {
        Write-Status "truehdd not found. Using FFmpeg fallback..." "WARN"
        return Convert-WithFFmpeg -InputFile $InputFile -OutputFile $OutputFile
    }
    
    Write-Status "Converting TrueHD to DAMF with truehdd..."
    
    try {
        & $truehdd "$InputFile" "$OutputFile"
        
        if (Test-Path $OutputFile) {
            Write-Status "Conversion successful: $OutputFile" "SUCCESS"
            return $true
        }
    }
    catch {
        Write-Status "truehdd conversion failed: $_" "WARN"
    }
    
    return $false
}

function Convert-WithFFmpeg {
    param(
        [string]$InputFile,
        [string]$OutputFile
    )
    
    $ffmpeg = Find-FFmpeg
    if (-not $ffmpeg) {
        Write-Status "FFmpeg not found!" "ERROR"
        return $false
    }
    
    Write-Status "Converting with FFmpeg..."
    
    # For now, just extract to raw PCM (real DAMF would need proper encoder)
    $pcmFile = "$OutputFile.pcm"
    
    try {
        & $ffmpeg -y -i "$InputFile" -vn -acodec pcm_s16le -ar 48000 -ac 2 "$pcmFile" 2>&1 | Out-Null
        
        if (Test-Path $pcmFile) {
            # Rename to .atmos extension (this is a simplified approach)
            Move-Item $pcmFile $OutputFile -Force
            Write-Status "FFmpeg conversion successful" "SUCCESS"
            return $true
        }
    }
    catch {
        Write-Status "FFmpeg conversion failed: $_" "ERROR"
    }
    
    return $false
}

function Get-CachedDAMF {
    param([string]$FilePath)
    
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    
    $fileHash = Get-FileHash -FilePath $FilePath
    $cachedPath = Join-Path $CacheDir "$fileHash.atmos"
    
    if (Test-Path $cachedPath) {
        Write-Status "Found cached DAMF: $cachedPath" "SUCCESS"
        return $cachedPath
    }
    
    return $null
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

function Play-DAMFFile {
    param([string]$FilePath)
    
    Write-Status "Playing DAMF file: $FilePath" "PLAY"
    
    if (-not (Test-Snapserver)) {
        Write-Status "Snapserver not running on $SnapserverHost`:$SnapserverPort" "ERROR"
        Write-Status "Start it first with: .\Start-CavernStreaming.ps1" "INFO"
        exit 1
    }
    
    $dllPath = Join-Path $script:SrcDir "bin\Release\net8.0\CavernSnapcastStreaming.dll"
    
    if (-not (Test-Path $dllPath)) {
        Write-Status "Building project..."
        Push-Location $script:SrcDir
        dotnet build --configuration Release | Out-Null
        Pop-Location
    }
    
    $args = @(
        "play"
        "$FilePath"
        "-c", $Channels
        "-r", $SampleRate
        "-b", $BitDepth
        "-h", $SnapserverHost
        "-p", $SnapserverPort
    )
    
    if ($StartTime) {
        # Note: StartTime support would need to be implemented in the C# code
        Write-Status "Start time specified: $StartTime" "WARN"
    }
    
    & dotnet $dllPath @args
}

function Play-MediaFile {
    param([string]$FilePath)
    
    Write-Status "Analyzing: $FilePath"
    
    $codec = Get-AudioCodec -FilePath $FilePath
    Write-Status "Audio codec: $codec"
    
    if ($codec -eq "truehd") {
        Write-Status "TrueHD detected - checking cache..."
        $cachedDAMF = Get-CachedDAMF -FilePath $FilePath
        
        if ($cachedDAMF) {
            Play-DAMFFile -FilePath $cachedDAMF
            return
        }
        
        Write-Status "Not in cache, converting..." "WARN"
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        
        $fileHash = Get-FileHash -FilePath $FilePath
        $outputPath = Join-Path $CacheDir "$fileHash.atmos"
        
        if (Convert-TrueHDToDAMF -InputFile $FilePath -OutputFile $outputPath) {
            Play-DAMFFile -FilePath $outputPath
            return
        }
        
        Write-Status "Conversion failed, attempting direct playback..." "WARN"
    }
    
    # Direct playback with FFmpeg extraction
    Write-Status "Direct playback mode" "PLAY"
    
    $ffmpeg = Find-FFmpeg
    if (-not $ffmpeg) {
        Write-Status "FFmpeg not found!" "ERROR"
        exit 1
    }
    
    $dllPath = Join-Path $script:SrcDir "bin\Release\net8.0\CavernSnapcastStreaming.dll"
    
    $ffArgs = "-i `"$FilePath`" -vn -acodec pcm_s16le -ar $SampleRate -ac $Channels -f s16le -"
    if ($StartTime) {
        $ffArgs = "-ss $StartTime " + $ffArgs
    }
    
    Write-Status "Starting FFmpeg + Streaming pipeline..."
    Write-Status "FFmpeg args: $ffArgs"
    
    # Simpler approach: use cmd to pipe FFmpeg to the streaming app
    $streamArgs = "stream -c $Channels -r $SampleRate -b $BitDepth -h $SnapserverHost -p $SnapserverPort"
    
    Write-Status "Starting FFmpeg..."
    
    # Build the command - use cmd.exe to handle the pipe properly
    $cmd = @"
"$ffmpeg" $ffArgs | dotnet "$dllPath" $streamArgs 2>&1
"@
    
    Write-Status "Command: $cmd" "DEBUG"
    
    # Execute using cmd with proper window handling
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c $cmd"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $false  # Show window to see output
    
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.WaitForExit()
    
    Write-Status "Playback finished (exit code: $($process.ExitCode))"
}

# Main execution
Clear-Host
Write-Host @"
╔═══════════════════════════════════════════════════════════╗
║          Cavern Dolby Atmos Movie Player                  ║
╚═══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Magenta

# Validate input file
if (-not (Test-Path $Path)) {
    Write-Status "File not found: $Path" "ERROR"
    exit 1
}

$resolvedPath = Resolve-Path $Path
Write-Status "File: $resolvedPath"
Write-Status "Output: $Channels ch @ $SampleRate Hz, $BitDepth-bit"
Write-Status "Cache: $CacheDir"

# Check prerequisites
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Status ".NET SDK not found!" "ERROR"
    exit 1
}

# Get file extension
$ext = [System.IO.Path]::GetExtension($Path).ToLower()

if ($ext -eq ".atmos") {
    Play-DAMFFile -FilePath $resolvedPath
}
else {
    Play-MediaFile -FilePath $resolvedPath
}
