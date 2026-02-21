#Requires -Version 5.1
<#
.SYNOPSIS
    Stream raw PCM file directly to snapserver (no FFmpeg needed)
#>
param(
    [string]$PcmFile = "..\test.pcm",
    [int]$Port = 1704,
    [int]$Channels = 6,
    [int]$SampleRate = 48000,
    [int]$BitDepth = 16
)

$rootDir = Split-Path -Parent $PSScriptRoot
$dllPath = Join-Path $rootDir "src\Streaming\bin\Release\net8.0\CavernSnapcastStreaming.dll"

if (-not (Test-Path $dllPath)) {
    Write-Host "Building..." -ForegroundColor Yellow
    Push-Location (Join-Path $rootDir "src\Streaming")
    dotnet build -c Release | Out-Null
    Pop-Location
}

$pcmFullPath = if ([System.IO.Path]::IsPathRooted($PcmFile)) { $PcmFile } else { Join-Path $rootDir $PcmFile }
Write-Host "Streaming: $pcmFullPath" -ForegroundColor Cyan
Write-Host "To: localhost:$Port ($Channels ch @ ${SampleRate}Hz)" -ForegroundColor Cyan

# Read PCM and pipe to streamer
$streamArgs = @(
    "stream"
    "-c", $Channels
    "-r", $SampleRate
    "-b", $BitDepth
    "-h", "localhost"
    "-p", $Port
)

# Use FileStream to read PCM and pipe to dotnet process
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "dotnet"
$psi.Arguments = "$dllPath $($streamArgs -join ' ')"
$psi.RedirectStandardInput = $true
$psi.UseShellExecute = $false

$proc = [System.Diagnostics.Process]::Start($psi)

# Read and stream file
$fs = [System.IO.File]::OpenRead($pcmFullPath)
$buffer = New-Object byte[] 8192

try {
    while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $proc.StandardInput.BaseStream.Write($buffer, 0, $read)
        $proc.StandardInput.BaseStream.Flush()
        Start-Sleep -Milliseconds 10  # Rate limit to simulate real-time
    }
}
finally {
    $fs.Close()
    $proc.StandardInput.Close()
    $proc.WaitForExit(5000)
    $proc.Dispose()
}

Write-Host "Done!" -ForegroundColor Green
