#Requires -Version 5.1
<#
.SYNOPSIS
    Convert a media file to WAV format without needing snapserver.

.DESCRIPTION
    Extracts audio from media files and saves as WAV. Useful for testing
    the pipeline without installing snapserver.

.PARAMETER Path
    Path to the input media file.

.PARAMETER Output
    Path to the output WAV file. If not specified, uses input name with .wav extension.

.PARAMETER Channels
    Number of output channels (2, 6, or 8). Default: 6

.PARAMETER SampleRate
    Sample rate in Hz. Default: 48000

.PARAMETER BitDepth
    Bit depth (16 or 24). Default: 16

.EXAMPLE
    .\Convert-ToWav.ps1 -Path "C:\Movies\movie.mkv"

.EXAMPLE
    .\Convert-ToWav.ps1 -Path "movie.mkv" -Output "output.wav" -Channels 2
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias("Input", "File")]
    [string]$Path,
    
    [Parameter(Position = 1)]
    [Alias("Out")]
    [string]$Output = "",
    
    [ValidateSet(2, 6, 8)]
    [int]$Channels = 6,
    
    [int]$SampleRate = 48000,
    
    [ValidateSet(16, 24)]
    [int]$BitDepth = 16
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

function Find-FFmpeg {
    # Check multiple possible locations for ffmpeg
    $possiblePaths = @(
        (Join-Path $script:RootDir "ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe")
        (Join-Path (Split-Path -Parent $script:RootDir) "ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe")
        (Join-Path (Split-Path -Parent (Split-Path -Parent $script:RootDir)) "ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe")
    )
    
    foreach ($path in $possiblePaths) {
        $resolved = Resolve-Path $path -ErrorAction SilentlyContinue
        if ($resolved -and (Test-Path $resolved)) {
            return $resolved.Path
        }
    }
    
    $inPath = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($inPath) { return $inPath.Source }
    return $null
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

# Validate input
if (-not (Test-Path $Path)) {
    Write-Status "File not found: $Path" "ERROR"
    exit 1
}

# Determine output path
if (-not $Output) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $Output = Join-Path (Get-Location) "$baseName.wav"
}

$resolvedInput = Resolve-Path $Path
$resolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)

Write-Status "Input:  $resolvedInput"
Write-Status "Output: $resolvedOutput"
Write-Status "Format: $Channels ch @ $SampleRate Hz, $BitDepth-bit"

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

# Run conversion
$args = @(
    "wav"
    "$resolvedOutput"
    "-i", "$resolvedInput"
    "-c", $Channels
    "-r", $SampleRate
    "-b", $BitDepth
)

Write-Status "Starting conversion..."
& dotnet $dllPath @args

if ($LASTEXITCODE -eq 0 -and (Test-Path $resolvedOutput)) {
    $fileInfo = Get-Item $resolvedOutput
    Write-Status "Conversion successful!" "SUCCESS"
    Write-Status "Output: $($fileInfo.FullName)" 
    Write-Status "Size: $([math]::Round($fileInfo.Length / 1MB, 2)) MB"
    
    # Calculate duration estimate
    $bytesPerSecond = $SampleRate * $Channels * ($BitDepth / 8)
    $estimatedSeconds = $fileInfo.Length / $bytesPerSecond
    $duration = [TimeSpan]::FromSeconds($estimatedSeconds)
    Write-Status "Estimated duration: $duration"
} else {
    Write-Status "Conversion failed" "ERROR"
}
