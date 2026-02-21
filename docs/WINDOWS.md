# Cavern-Snapcast Streaming on Windows

This guide covers the Windows implementation of the Dolby Atmos to Snapcast streaming pipeline.

## Overview

The Windows implementation uses:
- **Named Pipes** for inter-process communication (replaces Unix sockets)
- **TCP Streaming** for Snapserver integration (replaces FIFOs)
- **PowerShell Scripts** for operation (replaces Bash scripts)

## Architecture

```
Media File (TrueHD/E-AC-3/DTS)
    ↓
FFmpeg → Extract/Decode audio
    ↓
CavernSnapcastStreaming (NamedPipe Server)
    ↓ [CavernPipe Protocol]
Cavern Engine (spatial rendering)
    ↓ [PCM 6ch/16-bit/48kHz]
Snapcast Wire Protocol (TCP)
    ↓
Snapserver → Network (TCP/1704)
    ↓
Snapclients (ESP32/Speakers)
```

## Prerequisites

1. **.NET 8.0 SDK** or later
   - Download: https://dotnet.microsoft.com/download

2. **Snapserver for Windows**
   - Download: https://github.com/badaix/snapcast/releases
   - Extract to a location in PATH or use `-SnapserverPath` parameter

3. **FFmpeg** (included in this repository)
   - Located at `ffmpeg-8.0.1-essentials_build/`

4. **(Optional) truehdd** for TrueHD decoding
   - Not yet available for Windows; FFmpeg fallback is used

## Installation

### 1. Clone/Extract the Repository

```powershell
cd C:\path\to\Cavern-snapserver-essential
```

### 2. Build the Project

```powershell
.\scripts\Build-Windows.ps1
```

### 3. Install Snapserver (Optional)

Since official Windows builds are limited, you have several options:

#### Option A: Use the Test Receiver (Easiest)
No snapserver installation needed! Use the built-in test receiver:
```powershell
.\scripts\Start-TestServer.ps1
```

#### Option B: Convert to WAV
Convert audio to WAV file and play with any media player:
```powershell
.\scripts\Convert-ToWav.ps1 -Path "movie.mkv" -Output "output.wav"
```

#### Option C: Snapserver Emulator (Recommended!)
A native Windows replacement that works with real snapclients:
```powershell
# Terminal 1: Start the emulator (replaces snapserver)
.\scripts\Start-SnapserverEmulator.ps1

# Terminal 2: Stream a movie to it
.\scripts\Play-AtmosMovie.ps1 -Path "movie.mkv"
```

This emulator implements enough of the Snapcast protocol to work with real clients (ESP32, Android, Linux). This is the **best option for Windows**.

#### Option D: Run Snapserver in Docker
If you have Docker Desktop installed:
```powershell
.\scripts\Start-SnapserverDocker.ps1
```

#### Option E: Build from Source (Advanced/Experimental)
**Note:** Native Windows build has known issues (Windows SDK header conflicts).
See: https://github.com/badaix/snapcast/issues/1380

```powershell
# Install prerequisites:
# - Visual Studio 2022 with C++ workload
# - Windows SDK
# - Git, CMake, vcpkg
# Then run:
.\scripts\Build-SnapserverWindows.ps1
```

## Usage

### Testing Without Snapserver

If you don't have snapserver installed, you have several options:

#### Option 1: Test Receiver (TCP)
Start the test receiver in one PowerShell window:
```powershell
.\scripts\Start-TestServer.ps1
```

Then play a movie in another window:
```powershell
.\scripts\Play-AtmosMovie.ps1 -Path "C:\Movies\movie.mkv"
```

#### Option 2: Convert to WAV
Convert the audio to a WAV file you can play anywhere:
```powershell
.\scripts\Convert-ToWav.ps1 -Path "C:\Movies\movie.mkv" -Output "output.wav"
# Then play with any media player
```

#### Option 3: Direct WAV Output
Use the CLI directly:
```powershell
cd src\Streaming
dotnet run -- wav "output.wav" -i "C:\Movies\movie.mkv" -c 6
```

### Using Real Snapserver

If you have snapserver installed:

```powershell
# Basic usage (6 channels @ 48kHz)
.\scripts\Start-CavernStreaming.ps1

# Custom configuration
.\scripts\Start-CavernStreaming.ps1 -Channels 8 -SampleRate 96000

# Connect to remote snapserver
.\scripts\Start-CavernStreaming.ps1 -SnapserverHost 192.168.1.100
```

### Play a Movie

```powershell
# Play a Dolby Atmos movie
.\scripts\Play-AtmosMovie.ps1 -Path "C:\Movies\AtmosMovie.mkv"

# With options
.\scripts\Play-AtmosMovie.ps1 `
    -Path "C:\Movies\movie.mkv" `
    -Channels 8 `
    -SampleRate 48000 `
    -StartTime "00:10:00"

# Play a cached DAMF file
.\scripts\Play-AtmosMovie.ps1 -Path "C:\Cache\file.atmos"
```

### Check Status

```powershell
.\scripts\Get-CavernStatus.ps1
```

## Command Reference

### Start-CavernStreaming.ps1

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Channels` | 6 | Output channels (2, 6, or 8) |
| `-SampleRate` | 48000 | Sample rate in Hz |
| `-BitDepth` | 16 | Bit depth (16 or 24) |
| `-SnapserverHost` | localhost | Snapserver hostname |
| `-SnapserverPort` | 1704 | Snapserver port |
| `-SnapserverPath` | auto | Path to snapserver.exe |
| `-NoSnapserver` | false | Don't start snapserver |

### Play-AtmosMovie.ps1

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-Path` | Yes | Path to media file |
| `-Channels` | No | Output channels (default: 6) |
| `-SampleRate` | No | Sample rate (default: 48000) |
| `-BitDepth` | No | Bit depth (default: 16) |
| `-StartTime` | No | Start position (HH:MM:SS) |
| `-CacheDir` | No | Cache directory for DAMF files |

## Configuration

### Audio Format

The default output format is **6 channels (5.1) @ 48kHz, 16-bit**.

Supported configurations:
- 2 channels (stereo)
- 6 channels (5.1 surround)
- 8 channels (7.1 surround)

Higher sample rates (88200, 96000) are supported but increase network bandwidth.

### Snapserver Configuration

Edit `config/snapserver.windows.conf` for advanced settings:

```ini
[stream]
source = tcp://0.0.0.0:1804?name=Cavern&codec=flac&sampleformat=48000:16:6

[server]
buffer = 2000  ; End-to-end latency in ms
codec = flac   ; or 'pcm' for lower latency
```

### Caching

TrueHD files are automatically converted and cached:

- **Location**: `%USERPROFILE%\.cavern-wireless\cache\`
- **Format**: `<md5_hash>.atmos` (DAMF format)
- **Behavior**: Files are converted once and reused

## Troubleshooting

### "Snapserver not found"

Download Snapcast from https://github.com/badaix/snapcast/releases and either:
- Add to PATH, or
- Use `-SnapserverPath` parameter

### "Pipe not found"

The named pipe `\.|CavernPipe` is created automatically. If connection fails:
1. Ensure no other instance is running
2. Check Windows Firewall settings
3. Run `Get-CavernStatus.ps1` to diagnose

### Audio dropouts or sync issues

Increase the buffer size in `snapserver.windows.conf`:

```ini
[server]
buffer = 3000  ; Increase from 2000 to 3000ms
```

### High CPU usage

- Reduce output channels: `-Channels 6` instead of 8
- Use lower sample rate: `-SampleRate 48000`
- Use FLAC codec instead of PCM

### FFmpeg not found

The local FFmpeg should be auto-detected. If not:
- Ensure `ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe` exists
- Or install FFmpeg and add to PATH

## Technical Details

### Named Pipe Protocol

The Windows implementation uses Named Pipes instead of Unix domain sockets:

```
Server: NamedPipeServerStream("CavernPipe")
Client: NamedPipeClientStream(".", "CavernPipe")
```

### TCP Streaming

Audio is streamed to Snapserver via TCP on port 1804 (configurable), avoiding the need for FIFOs on Windows.

### Differences from Linux/macOS

| Feature | Linux/macOS | Windows |
|---------|-------------|---------|
| IPC | Unix sockets | Named pipes |
| Snapserver source | FIFO (`/tmp/snapcast-out`) | TCP (`tcp://0.0.0.0:1804`) |
| Scripts | Bash | PowerShell |
| TrueHD decoding | truehdd | FFmpeg (fallback) |

## Development

### Project Structure

```
src/
└── Streaming/
    ├── CavernSnapcastStreaming.csproj
    ├── Program.cs              # Entry point and modes
    ├── NamedPipeServer.cs      # Windows named pipe server
    └── SnapcastBridge.cs       # Bridge to Snapserver
```

### Building

```powershell
cd src\Streaming
dotnet build --configuration Release
dotnet run -- server -c 6
```

### Running in Debug Mode

```powershell
$env:DEBUG = "1"
.\scripts\Start-CavernStreaming.ps1
```

## Known Limitations

1. **truehdd not available on Windows**: TrueHD decoding uses FFmpeg fallback (less efficient)
2. **No virtual audio device capture**: System audio capture not yet implemented
3. **Snapserver for Windows is limited**: Official Windows builds may not be available
4. **Native compilation issues**: Building snapserver natively on Windows has known issues with Windows SDK headers

## Building Snapserver on Windows

### Option 1: Docker (Recommended)
The easiest way to run Snapserver on Windows is using Docker:

```powershell
.\scripts\Start-SnapserverDocker.ps1
```

This builds and runs Snapserver in a Linux container via Docker Desktop.

### Option 2: Native Build (Experimental)
Native Windows compilation is **experimental** and known to have issues:

**Prerequisites:**
- Visual Studio 2022 with C++ workload
- Windows SDK 10.0.22621.0 or later
- CMake 3.20+
- vcpkg
- Git

**Known Issues:**
```
ipifcons.h(248,15): error C2146: syntax error: missing ';' before identifier 'IFTYPE'
iprtrmib.h(145,12): error C3646: 'dwVarId': unknown override specifier
```

These are Windows SDK header compatibility issues. See:
- https://github.com/badaix/snapcast/issues/1380

**Build Script:**
```powershell
.\scripts\Build-SnapserverWindows.ps1
```

**If the build fails:**
1. Try running from "Developer Command Prompt for VS 2022"
2. Check that Windows SDK is properly installed
3. Try with different Windows SDK versions
4. Use Docker method instead

## Testing Without Snapserver

Since snapserver for Windows can be hard to find, the project includes alternatives:

### Test Receiver Mode
Mimics snapserver's TCP protocol for testing:
```powershell
# Terminal 1: Start receiver
.\scripts\Start-TestServer.ps1 -Port 1704

# Terminal 2: Stream to it
.\scripts\Play-AtmosMovie.ps1 -Path "movie.mkv" -SnapserverPort 1704
```

### WAV Output Mode
Save processed audio as WAV for playback in any media player:
```powershell
# Convert entire movie to WAV
.\scripts\Convert-ToWav.ps1 -Path "movie.mkv" -Channels 6

# Or use CLI directly for more control
dotnet run -- project CavernSnapcastStreaming wav "output.wav" -i "movie.mkv" -c 6 -r 48000
```

The WAV file will contain the spatial-rendered audio (e.g., 5.1 surround) that would normally go to snapserver.

## Future Enhancements

- [ ] WASAPI audio capture for system-wide streaming
- [ ] truehdd Windows port for native TrueHD decoding
- [ ] GUI application for easier management
- [ ] Windows service mode for headless operation

## Support

For issues specific to the Windows implementation:
1. Check `logs/` directory for detailed logs
2. Run `Get-CavernStatus.ps1` for diagnostics
3. Enable debug mode for verbose output
