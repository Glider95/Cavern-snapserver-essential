# CavernPipe Snapcast Bridge

Wireless Dolby Atmos spatial audio pipeline for home cinema. Renders object-based audio and distributes to network speakers via Snapcast.

## Overview

This project bridges the **Cavern** spatial audio engine with **Snapcast** for wireless multi-room audio playback. It uses a file-based mode for reliable Dolby Atmos (TrueHD) rendering.

```
Media File (TrueHD/E-AC-3/DTS)
    ↓
FFmpeg → truehdd → DAMF (cached)
    ↓
CavernPipeClient (file-based mode)
    ↓ [Unix Socket]
CavernPipeServer (spatial rendering)
    ↓ [PCM 6ch/16-bit/48kHz]
PipeToFifo → /tmp/snapcast-out
    ↓
Snapserver → Network (TCP/1704)
    ↓
Snapclients (ESP32/Speakers)
```

## Features

- ✅ **Dolby Atmos TrueHD** support via truehdd → DAMF conversion
- ✅ **File-based mode** - reliable, no streaming container issues
- ✅ **Automatic caching** - TrueHD converted once, cached forever
- ✅ **Spatial rendering** - 12ch Atmos objects → 6ch/8ch output
- ✅ **Multi-room sync** - Snapcast synchronized playback
- ✅ **Windows support** - Named pipes and TCP streaming (see [docs/WINDOWS.md](docs/WINDOWS.md))

## Prerequisites

### macOS
```bash
brew install dotnet-sdk snapcast ffmpeg
```

### Linux
```bash
sudo apt-get install dotnet-sdk-8.0 snapserver snapclient ffmpeg
```

### Windows
```powershell
# Install .NET 8.0 SDK from https://dotnet.microsoft.com/download
# Download snapserver from https://github.com/badaix/snapcast/releases
# FFmpeg is included in this repository
```

### Build truehdd (TrueHD decoder) - Linux/macOS only
```bash
git clone https://github.com/truehdd/truehdd.git /tmp/truehdd
cd /tmp/truehdd && cargo build --release
```

## Setup

Choose one of the following methods:

### Option A: Download Pre-built Binaries (Quickest)

```bash
# Download all required binaries from GitHub Release
mkdir -p bin
cd bin

# CavernPipeServer (patched version with file-based mode)
curl -LO https://github.com/Glider95/Cavern-snapserver-essential/releases/download/v1.0.0/CavernPipeServer.dll
curl -LO https://github.com/Glider95/Cavern-snapserver-essential/releases/download/v1.0.0/CavernPipeServer.runtimeconfig.json
curl -LO https://github.com/Glider95/Cavern-snapserver-essential/releases/download/v1.0.0/CavernPipeServer.deps.json
curl -LO https://github.com/Glider95/Cavern-snapserver-essential/releases/download/v1.0.0/CavernPipeServer.Logic.dll
curl -LO https://github.com/Glider95/Cavern-snapserver-essential/releases/download/v1.0.0/Cavern.dll
curl -LO https://github.com/Glider95/Cavern-snapserver-essential/releases/download/v1.0.0/Cavern.Format.dll

cd ..

# Build the client components (requires .NET 8 SDK)
./scripts/build.sh
```

### Option B: Build Everything from Source

See `docs/BUILD.md` for complete instructions on building CavernPipeServer with patches applied.

### Required Files in `bin/`

After setup, your `bin/` directory should contain:

```
bin/
├── CavernPipeServer.dll           # Server (download or build)
├── CavernPipeServer.runtimeconfig.json
├── CavernPipeServer.deps.json
├── CavernPipeServer.Logic.dll     # Patched logic
├── Cavern.dll                     # Cavern engine
├── Cavern.Format.dll              # Cavern formats
├── CavernPipeClient.dll           # Client (built locally)
├── CavernPipeClient.runtimeconfig.json
├── CavernPipeClient.deps.json
├── PipeToFifo.dll                 # FIFO bridge (built locally)
├── PipeToFifo.runtimeconfig.json
└── PipeToFifo.deps.json
```

## Quick Start

### Linux/macOS

```bash
# 1. Build
./scripts/build.sh

# 2. Start infrastructure
./scripts/run.sh

# 3. Play a movie (in another terminal)
./scripts/cavern-wireless.sh ~/Movies/demo.mkv
```

### Windows

```powershell
# 1. Build
.\scripts\Build-Windows.ps1

# 2. Option A: Snapserver Emulator (Recommended - works with real clients!)
.\scripts\Start-SnapserverEmulator.ps1   # Terminal 1
.\scripts\Play-AtmosMovie.ps1 -Path "C:\Movies\demo.mkv"   # Terminal 2

# 2. Option B: Test without snapserver (convert to WAV)
.\scripts\Convert-ToWav.ps1 -Path "C:\Movies\demo.mkv" -Output "output.wav"

# 2. Option C: Test with test receiver (mimics snapserver)
.\scripts\Start-TestServer.ps1          # Terminal 1
.\scripts\Play-AtmosMovie.ps1 -Path "C:\Movies\demo.mkv"   # Terminal 2

# 2. Option D: Use real snapserver (if installed)
.\scripts\Start-CavernStreaming.ps1     # Terminal 1
.\scripts\Play-AtmosMovie.ps1 -Path "C:\Movies\demo.mkv"   # Terminal 2
```

See [docs/WINDOWS.md](docs/WINDOWS.md) for detailed Windows instructions.

### 4. Connect Speaker

```bash
# On your ESP32/speaker device
snapclient -h <server_ip>
```

## Scripts

### Linux/macOS

| Script | Purpose |
|--------|---------|
| `run.sh` | Start CavernPipeServer + Snapserver |
| `play.sh <file>` | Play media file (auto-detects format) |
| `cavern-wireless.sh <file>` | Full pipeline with TrueHD conversion |
| `build.sh` | Build all components |

### Windows

| Script | Purpose |
|--------|---------|
| `Build-Windows.ps1` | Build all Windows components |
| `Start-CavernStreaming.ps1` | Start streaming pipeline |
| `Play-AtmosMovie.ps1` | Play Dolby Atmos movies |
| `Get-CavernStatus.ps1` | Check system status |

## Configuration

Environment variables for `run.sh` and `play.sh`:

```bash
OUTPUT_CHANNELS=6    # 2, 6 (5.1), or 8 (7.1)
SAMPLE_RATE=48000    # 48000 Hz (standard)
BIT_DEPTH=16         # 16 or 24-bit

# Example:
OUTPUT_CHANNELS=6 ./scripts/run.sh
```

Snapserver config: `config/snapserver.conf`

## How It Works

### File-Based Mode (Recommended)

1. **TrueHD files** are converted to DAMF format using `truehdd`
2. **DAMF files** are cached in `~/.cavern-wireless/cache/`
3. **CavernPipeClient** sends file path to server (negative UpdateRate = file mode)
4. **CavernPipeServer** opens file directly, renders spatial audio
5. **PCM output** flows through FIFO to Snapserver
6. **Snapclients** receive synchronized audio

### Code Flow

```
Client                              Server
  |                                   |
  |-- Handshake (UpdateRate=-1024) ->|  File-based mode
  |-- Path length (4 bytes) --------->|
  |-- Path bytes -------------------->|
  |                                   |
  |<-- PCM chunk 1 ------------------|  64KB chunks
  |<-- PCM chunk 2 ------------------|
  |<-- ... --------------------------|
  |<-- Length=0 (EOF) ---------------|
```

## Project Structure

```
├── bin/                           # REQUIRED: Binaries (not in git, see Setup)
│   ├── CavernPipeServer.dll
│   ├── CavernPipeClient.dll
│   ├── PipeToFifo.dll
│   └── *.runtimeconfig.json
├── scripts/
│   ├── *.sh                       # Linux/macOS scripts
│   ├── *.ps1                      # Windows PowerShell scripts
│   └── streaming/                 # Streaming-specific scripts
├── src/
│   ├── CavernPipeClient/          # Protocol bridge (Unix)
│   ├── PipeToFifo/                # FIFO writer (Unix)
│   └── Streaming/                 # Windows streaming implementation
│       ├── NamedPipeServer.cs
│       ├── SnapcastBridge.cs
│       └── Program.cs
├── config/
│   ├── snapserver.conf            # Unix snapserver config
│   └── snapserver.windows.conf    # Windows snapserver config
├── docs/
│   ├── PROTOCOL.md                # CavernPipe protocol
│   ├── TROUBLESHOOTING.md         # Common issues
│   └── WINDOWS.md                 # Windows setup guide
├── patches/                       # Patched Cavern files
│   └── CavernPipeServer.Logic/
│       ├── CavernPipeProtocol.cs
│       ├── CavernPipeRenderer.cs
│       └── PipeHandler.cs
└── README.md
```

## Patches

The `patches/` folder contains modified Cavern files for file-based mode support:

- **CavernPipeProtocol.cs**: Accept negative UpdateRate for file mode
- **CavernPipeRenderer.cs**: Add `ReadHeader()` and `OpenFileFromPath()`
- **PipeHandler.cs**: Handle file-based handshake and chunked transfers

Apply patches to upstream Cavern before building.

## Cache

Converted files stored in `~/.cavern-wireless/cache/`:

```
<md5_hash>.atmos              # DAMF header
<md5_hash>.atmos.audio        # PCM audio data
<md5_hash>.atmos.metadata     # Object positions
<md5_hash>.truehd             # Extracted TrueHD (temporary)
```

## Platform Notes

### Linux/macOS
- Uses Unix domain sockets and FIFOs
- Native truehdd support for TrueHD decoding
- Full feature set available

### Windows
- Uses Named Pipes for IPC
- TCP streaming to snapserver (no FIFOs)
- FFmpeg fallback for TrueHD (truehdd not yet available)
- See [docs/WINDOWS.md](docs/WINDOWS.md) for details

## Known Issues

| Issue | Workaround |
|-------|------------|
| Streaming mode has container parsing issues | Use file-based mode (default) |
| TrueHD requires conversion | Auto-converted and cached on first play |
| Minor artifacts/jitter | Known limitation of current implementation |
| Windows: No truehdd | Use FFmpeg fallback (included) |

## Credits

- [VoidXH/Cavern](https://github.com/VoidXH/Cavern) - Spatial audio engine
- [truehdd/truehdd](https://github.com/truehdd/truehdd) - TrueHD decoder
- [badaix/snapcast](https://github.com/badaix/snapcast) - Multi-room audio

## License

- CavernPipeClient, PipeToFifo: MIT
- Cavern: See upstream license
- Snapcast: GPLv3
