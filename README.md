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

## Prerequisites

```bash
# macOS
brew install dotnet-sdk snapcast ffmpeg

# Linux
sudo apt-get install dotnet-sdk-8.0 snapserver snapclient ffmpeg

# Build truehdd (TrueHD decoder)
git clone https://github.com/truehdd/truehdd.git /tmp/truehdd
cd /tmp/truehdd && cargo build --release
```

## Quick Start

### 1. Build

```bash
./scripts/build.sh
```

### 2. Start Infrastructure

```bash
# Terminal 1
./scripts/run.sh
```

### 3. Play Audio

```bash
# Terminal 2 - Play a movie (auto-converts TrueHD to DAMF)
./scripts/cavern-wireless.sh ~/Movies/demo.mkv

# Or play a cached DAMF file directly
./scripts/play.sh ~/.cavern-wireless/cache/<hash>.atmos
```

### 4. Connect Speaker

```bash
# On your ESP32/speaker device
snapclient -h <server_ip>
```

## Scripts

| Script | Purpose |
|--------|---------|
| `run.sh` | Start CavernPipeServer + Snapserver |
| `play.sh <file>` | Play media file (auto-detects format) |
| `cavern-wireless.sh <file>` | Full pipeline with TrueHD conversion |
| `build.sh` | Build all components |

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
├── scripts/
│   ├── run.sh              # Start infrastructure
│   ├── play.sh             # Play media files
│   ├── cavern-wireless.sh  # Full automation
│   └── build.sh            # Build components
├── src/
│   ├── CavernPipeClient/   # Protocol bridge
│   └── PipeToFifo/         # FIFO writer
├── config/
│   └── snapserver.conf     # Snapserver config
├── docs/
│   ├── PROTOCOL.md         # CavernPipe protocol
│   └── TROUBLESHOOTING.md  # Common issues
├── patches/                # Patched Cavern files
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

## Known Issues

| Issue | Workaround |
|-------|------------|
| Streaming mode has container parsing issues | Use file-based mode (default) |
| TrueHD requires conversion | Auto-converted and cached on first play |
| Minor artifacts/jitter | Known limitation of current implementation |

## Credits

- [VoidXH/Cavern](https://github.com/VoidXH/Cavern) - Spatial audio engine
- [truehdd/truehdd](https://github.com/truehdd/truehdd) - TrueHD decoder
- [badaix/snapcast](https://github.com/badaix/snapcast) - Multi-room audio

## License

- CavernPipeClient, PipeToFifo: MIT
- Cavern: See upstream license
- Snapcast: GPLv3
