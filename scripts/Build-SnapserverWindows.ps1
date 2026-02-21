#Requires -Version 5.1
<#
.SYNOPSIS
    Build Snapserver for Windows from source.

.DESCRIPTION
    Attempts to build Snapserver on Windows using CMake and vcpkg.
    Based on: https://github.com/badaix/snapcast/issues/1380

.PARAMETER InstallPath
    Directory where snapserver will be installed. Default: C:\Snapcast

.PARAMETER BuildType
    Build configuration: Release or Debug. Default: Release

.PARAMETER Branch
    Git branch to build. Default: develop

.EXAMPLE
    .\Build-SnapserverWindows.ps1

.EXAMPLE
    .\Build-SnapserverWindows.ps1 -InstallPath "C:\tools\snapcast" -BuildType Release
#>
[CmdletBinding()]
param(
    [string]$InstallPath = "C:\Snapcast",
    
    [ValidateSet("Release", "Debug")]
    [string]$BuildType = "Release",
    
    [string]$Branch = "develop"
)

$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Status) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        "CMD" { "DarkGray" }
        default { "Cyan" }
    }
    Write-Host "[$timestamp] [$Status] $Message" -ForegroundColor $color
}

function Test-Command {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Install-Prerequisites {
    Write-Status "Checking prerequisites..."
    
    # Check Git
    if (-not (Test-Command "git")) {
        Write-Status "Git not found. Installing via winget..." "WARN"
        winget install Git.Git --accept-package-agreements --accept-source-agreements
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    }
    Write-Status "Git: OK"
    
    # Check CMake
    if (-not (Test-Command "cmake")) {
        Write-Status "CMake not found. Installing via winget..." "WARN"
        winget install Kitware.CMake --accept-package-agreements --accept-source-agreements
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    }
    Write-Status "CMake: OK"
    
    # Check for Visual Studio
    $vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vsWhere)) {
        Write-Status "Visual Studio not found. Please install Visual Studio 2022 with C++ workload" "ERROR"
        Write-Status "Download: https://visualstudio.microsoft.com/downloads/" "INFO"
        exit 1
    }
    
    $vsPath = & $vsWhere -latest -property installationPath
    if (-not $vsPath) {
        Write-Status "Visual Studio installation not found" "ERROR"
        exit 1
    }
    Write-Status "Visual Studio: $vsPath"
    
    # Check vcpkg
    $vcpkgRoot = "C:\vcpkg"
    if (-not (Test-Path $vcpkgRoot)) {
        Write-Status "vcpkg not found. Installing..." "WARN"
        git clone https://github.com/Microsoft/vcpkg.git $vcpkgRoot
        & "$vcpkgRoot\bootstrap-vcpkg.bat"
    }
    Write-Status "vcpkg: OK"
    
    return $vcpkgRoot
}

function Install-Dependencies {
    param([string]$VcpkgRoot)
    
    Write-Status "Installing dependencies via vcpkg..."
    
    $deps = @(
        "boost-asio"
        "boost-beast"
        "boost-circular-buffer"
        "boost-lockfree"
        "boost-process"
        "flac"
        "libogg"
        "libvorbis"
        "opus"
        "soxr"
    )
    
    foreach ($dep in $deps) {
        Write-Status "Installing $dep..."
        & "$VcpkgRoot\vcpkg.exe" install $dep:x64-windows-static
        if ($LASTEXITCODE -ne 0) {
            Write-Status "Failed to install $dep" "WARN"
        }
    }
}

function Build-Snapcast {
    param(
        [string]$VcpkgRoot,
        [string]$SourcePath,
        [string]$BuildPath
    )
    
    Write-Status "Cloning Snapcast repository..."
    if (-not (Test-Path $SourcePath)) {
        git clone --branch $Branch --recursive https://github.com/badaix/snapcast.git $SourcePath
    } else {
        Push-Location $SourcePath
        git pull
        git submodule update --init --recursive
        Pop-Location
    }
    
    Write-Status "Creating build directory..."
    New-Item -ItemType Directory -Force -Path $BuildPath | Out-Null
    Push-Location $BuildPath
    
    try {
        Write-Status "Running CMake..."
        $cmakeArgs = @(
            ".."
            "-DCMAKE_TOOLCHAIN_FILE=$VcpkgRoot\scripts\buildsystems\vcpkg.cmake"
            "-DBUILD_SERVER=ON"
            "-DBUILD_CLIENT=OFF"
            "-DCMAKE_BUILD_TYPE=$BuildType"
            "-DVCPKG_TARGET_TRIPLET=x64-windows-static"
            "-A", "x64"
        )
        
        Write-Status "cmake $cmakeArgs" "CMD"
        & cmake @cmakeArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "CMake configuration failed"
        }
        
        Write-Status "Building Snapserver (this may take a while)..."
        & cmake --build . --config $BuildType --parallel
        
        if ($LASTEXITCODE -ne 0) {
            throw "Build failed - see errors above"
        }
        
        Write-Status "Build completed successfully!" "SUCCESS"
    }
    finally {
        Pop-Location
    }
}

function Install-Snapcast {
    param(
        [string]$BuildPath,
        [string]$InstallDir
    )
    
    Write-Status "Installing to $InstallDir..."
    
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    
    $exePath = Join-Path $BuildPath "server\$BuildType\snapserver.exe"
    if (Test-Path $exePath) {
        Copy-Item $exePath $InstallDir -Force
        Write-Status "Installed: $InstallDir\snapserver.exe" "SUCCESS"
    } else {
        # Try alternative path
        $exePath = Join-Path $BuildPath "bin\$BuildType\snapserver.exe"
        if (Test-Path $exePath) {
            Copy-Item $exePath $InstallDir -Force
            Write-Status "Installed: $InstallDir\snapserver.exe" "SUCCESS"
        } else {
            Write-Status "snapserver.exe not found in build output" "WARN"
            Write-Status "Searched: $BuildPath" "INFO"
        }
    }
    
    # Copy config file
    $configSource = Join-Path $BuildPath "..\server\etc\snapserver.conf"
    if (Test-Path $configSource) {
        Copy-Item $configSource $InstallDir -Force
        Write-Status "Installed config: $InstallDir\snapserver.conf" "SUCCESS"
    }
}

# Main execution
Clear-Host
Write-Host @"
╔═══════════════════════════════════════════════════════════╗
║          Build Snapserver for Windows                     ║
╚═══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Yellow

Write-Status "This script will attempt to build Snapserver from source."
Write-Status "Note: This is EXPERIMENTAL and may not work on all systems."
Write-Status ""
Write-Status "Prerequisites:"
Write-Status "  - Visual Studio 2022 with C++ workload"
Write-Status "  - Windows SDK"
Write-Status "  - Git"
Write-Status "  - CMake"
Write-Status "  - vcpkg (will be installed if missing)"
Write-Status ""

$continue = Read-Host "Continue? (y/N)"
if ($continue -ne 'y' -and $continue -ne 'Y') {
    exit 0
}

$sourcePath = Join-Path $InstallPath "src"
$buildPath = Join-Path $InstallPath "build"

try {
    $vcpkgRoot = Install-Prerequisites
    Install-Dependencies -VcpkgRoot $vcpkgRoot
    Build-Snapcast -VcpkgRoot $vcpkgRoot -SourcePath $sourcePath -BuildPath $buildPath
    Install-Snapcast -BuildPath $buildPath -InstallDir $InstallPath
    
    Write-Status ""
    Write-Status "═══════════════════════════════════════════════════════════"
    Write-Status "Build process completed!"
    Write-Status "═══════════════════════════════════════════════════════════"
    Write-Status ""
    Write-Status "Installation directory: $InstallPath"
    Write-Status ""
    Write-Status "To use with Cavern:"
    Write-Status "  .\Start-CavernStreaming.ps1 -SnapserverPath '$InstallPath\snapserver.exe'"
    Write-Status ""
}
catch {
    Write-Status "ERROR: $_" "ERROR"
    Write-Status ""
    Write-Status "Troubleshooting:"
    Write-Status "  1. Ensure Visual Studio 2022 with C++ workload is installed"
    Write-Status "  2. Check that Windows SDK is installed"
    Write-Status "  3. Try running from 'Developer Command Prompt for VS 2022'"
    Write-Status "  4. See: https://github.com/badaix/snapcast/issues/1380"
    Write-Status ""
    exit 1
}
