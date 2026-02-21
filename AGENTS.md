# CavernPipe Snapcast Bridge - Agent Guide

## Project Overview

This project bridges the **Cavern** spatial audio engine with **Snapcast** for wireless multi-room Dolby Atmos audio playback. It renders object-based audio (TrueHD/E-AC-3/DTS) and distributes to network speakers via Snapcast.

### Key Features
- Dolby Atmos TrueHD support via `truehdd` → DAMF conversion
- File-based mode for reliable playback (no streaming container issues)
- Automatic caching of converted TrueHD files
- Spatial rendering: 12ch Atmos objects → 6ch/8ch output
- Multi-room synchronized playback via Snapcast
- Streaming mode from any application (VLC, Stremio, browsers)
- Dynamic audio parameter detection (auto-detect codec, sample rate, channels)
- Customizable speaker layouts (stereo to 7.1.4 Atmos)
- Web UI for monitoring and control

### Architecture Pipeline

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

## Technology Stack

| Component | Technology |
|-----------|------------|
| Runtime | .NET 8.0 |
| Language | C# 12.0 |
| Scripts | Bash |
| Audio Engine | Cavern (NuGet v2.1.0) |
| Multi-room Sync | Snapcast |
| Media Processing | FFmpeg |
| TrueHD Decoder | truehdd (Rust) |
| Web UI | Python 3 + Flask |

## Project Structure

```
├── bin/                          # REQUIRED: Binaries (not in git)
│   ├── CavernPipeServer.dll      # Server (download or build)
│   ├── CavernPipeServer.Logic.dll
│   ├── Cavern.dll                # Cavern engine
│   ├── Cavern.Format.dll
│   ├── CavernPipeClient.dll      # Client (built locally)
│   ├── PipeToFifo.dll            # FIFO bridge (built locally)
│   ├── StreamingAdapter.dll      # Streaming adapter (built locally)
│   └── *.runtimeconfig.json
├── src/
│   ├── CavernPipeClient/         # Protocol bridge client
│   │   ├── Program.cs            # Main client logic
│   │   └── CavernPipeClient.csproj
│   ├── PipeToFifo/               # FIFO writer
│   │   ├── Program.cs            # Stdin → FIFO bridge
│   │   └── PipeToFifo.csproj
│   └── StreamingAdapter/         # Streaming mode adapter
│       ├── Program.cs            # Auto-detecting stream adapter
│       └── StreamingAdapter.csproj
├── patches/                      # Patched Cavern files for file-based mode
│   └── CavernPipeServer.Logic/
│       ├── CavernPipeProtocol.cs # Accept negative UpdateRate for file mode
│       ├── CavernPipeRenderer.cs # Add OpenFileFromPath() method
│       └── PipeHandler.cs        # Handle chunked file transfers
├── scripts/
│   ├── build.sh                  # Build all components
│   ├── run.sh                    # Start infrastructure
│   ├── play.sh                   # Play media files
│   ├── play-detected.sh          # Play with auto-detection
│   ├── cavern-wireless.sh        # Full automation with TrueHD conversion
│   ├── configure-speakers.sh     # Speaker layout configuration
│   ├── diagnose.sh               # Diagnostic tool
│   ├── web-ui.sh                 # Web UI launcher
│   └── streaming/                # Streaming mode scripts
│       ├── capture-system-audio.sh   # System audio capture
│       └── stream-from-app.sh        # Application streaming
├── config/
│   ├── snapserver.conf           # Snapserver configuration
│   └── speaker-layouts.json      # Speaker layout definitions
├── web-ui/                       # Web control panel
│   ├── index.html                # Frontend interface
│   ├── server.py                 # Backend API server
│   ├── server_enhanced.py        # Enhanced server with more features
│   ├── server_original.py        # Original server implementation
│   └── requirements.txt          # Python dependencies
├── docs/
│   ├── PROTOCOL.md               # CavernPipe protocol spec
│   ├── TROUBLESHOOTING.md        # Common issues and solutions
│   ├── NEW_FEATURES.md           # New features documentation
│   ├── PROJECT_PURPOSE.md        # Project specification and roadmap
│   └── Snapcast_configuration.md # Detailed Snapcast configuration
├── cavern64/                     # Pre-built Cavern Unity application (Windows)
│   ├── Cavern.exe                # Cavern GUI application
│   └── Cavern_Data/              # Unity data files
├── ffmpeg-8.0.1-essentials_build/ # FFmpeg binaries
├── logs/                         # Runtime logs (created at runtime)
└── .gitignore                    # Git ignore rules
```

## Build Commands

### Prerequisites
```bash
# macOS
brew install dotnet-sdk snapcast ffmpeg

# Linux
sudo apt-get install dotnet-sdk-8.0 snapserver snapclient ffmpeg

# Build truehdd (TrueHD decoder)
git clone https://github.com/truehdd/truehdd.git /tmp/truehdd
cd /tmp/truehdd && cargo build --release
```

### Building Components

```bash
# Build CavernPipeClient, PipeToFifo, StreamingAdapter, and setup Web UI
./scripts/build.sh

# Manual build steps:
cd src/CavernPipeClient
dotnet build -c Release
cd ../PipeToFifo
dotnet build -c Release
cd ../StreamingAdapter
dotnet build -c Release
```

### Building CavernPipeServer (from source)

The CavernPipeServer requires patched upstream Cavern source:

```bash
# 1. Clone upstream Cavern
git clone https://github.com/VoidXH/Cavern.git /tmp/cavern-upstream

# 2. Apply patches
cp patches/CavernPipeServer.Logic/*.cs /tmp/cavern-upstream/CavernSamples/Reusable/CavernPipeServer.Logic/

# 3. Build
cd /tmp/cavern-upstream
dotnet build CavernSamples/CavernPipeServer.Multiplatform/CavernPipeServer.Multiplatform.csproj -c Release

# 4. Copy to bin/:
cp /tmp/cavern-upstream/CavernSamples/CavernPipeServer.Multiplatform/bin/Release/net8.0/* bin/
```

## Runtime Commands

### Start Infrastructure
```bash
# Terminal 1: Start CavernPipeServer + Snapserver
./scripts/run.sh

# With custom output configuration:
OUTPUT_CHANNELS=8 ./scripts/run.sh  # 7.1 surround
```

### Play Audio
```bash
# Terminal 2: Play a movie (auto-converts TrueHD to DAMF)
./scripts/cavern-wireless.sh ~/Movies/demo.mkv

# Play with options:
./scripts/cavern-wireless.sh -n movie.mkv    # Force re-conversion (no cache)
./scripts/cavern-wireless.sh -l movie.mkv    # Local playback only (ffplay)
./scripts/cavern-wireless.sh -d movie.mkv    # Dry run

# Or play a cached DAMF file directly:
./scripts/play.sh ~/.cavern-wireless/cache/<hash>.atmos
```

### Play with Auto-Detection (Recommended)
```bash
# Auto-detect audio parameters and optimize playback
./scripts/play-detected.sh movie.mkv

# Show detection info only:
./scripts/play-detected.sh --detect-only movie.mkv

# Override detected parameters:
./scripts/play-detected.sh -c 8 -r 96000 movie.mkv
```

### Stream from Applications (VLC, Stremio, Browsers)

**Setup virtual audio device:**
```bash
# macOS: Install BlackHole
brew install blackhole-16ch

# Then run:
./scripts/streaming/capture-system-audio.sh --setup  # Show setup instructions
```

**Capture system audio:**
```bash
# Terminal 2: Capture all system audio
./scripts/streaming/capture-system-audio.sh /tmp/snapcast-out
```

**Stream from specific apps:**
```bash
# VLC setup instructions
./scripts/streaming/stream-from-app.sh --vlc

# Stremio setup instructions
./scripts/streaming/stream-from-app.sh --stremio

# Stream from URL
./scripts/streaming/stream-from-app.sh http://example.com/stream.mp3
```

### Speaker Layout Configuration
```bash
# List available layouts
./scripts/configure-speakers.sh list

# Set layout (e.g., 7.1 surround)
./scripts/configure-speakers.sh set surround_71

# Visualize layout
./scripts/configure-speakers.sh visualize surround_714

# Apply layout to pipeline
eval $(./scripts/configure-speakers.sh env)
./scripts/run.sh

# Or directly:
SPEAKER_LAYOUT=surround_71 OUTPUT_CHANNELS=8 ./scripts/run.sh
```

### Web Control Panel
```bash
# Start Web UI
./scripts/web-ui.sh

# Access at http://localhost:8080

# With custom port:
./scripts/web-ui.sh -p 9090
```

### Stop Pipeline
```bash
# Press Ctrl+C in the terminal running run.sh
# Or manually:
pkill -f CavernPipeServer
pkill -f snapserver
rm -f /tmp/snapcast-out
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OUTPUT_CHANNELS` | 6 | Output channels: 2, 6 (5.1), or 8 (7.1) |
| `SAMPLE_RATE` | 48000 | Sample rate in Hz |
| `BIT_DEPTH` | 16 | Bit depth: 16 or 24 |
| `DEBUG` | 0 | Enable debug mode (1 = enabled) |
| `SPEAKER_LAYOUT` | surround_51 | Speaker layout from speaker-layouts.json |

### Snapserver Configuration

Location: `config/snapserver.conf`

Key settings:
- Source: `pipe:///tmp/snapcast-out?name=Cavern&sampleformat=48000:16:6`
- Stream port: 1704
- Control port: 1705
- HTTP interface: 1780
- Buffer: 2000ms (end-to-end latency)
- Codec: flac (for up to 8 channels)

### Cache Directory

Converted files stored in `~/.cavern-wireless/cache/`:
```
<md5_hash>.atmos              # DAMF header
<md5_hash>.atmos.audio        # PCM audio data
<md5_hash>.atmos.metadata     # Object positions
<md5_hash>.truehd             # Extracted TrueHD (temporary)
```

## Code Style Guidelines

### C# Code Style
- Use explicit access modifiers (`public`, `private`, etc.)
- Use `var` for local variables when type is obvious
- Async/await pattern for I/O operations
- Constants use PascalCase (e.g., `DefaultUpdateRate`)
- Private fields use camelCase
- XML documentation comments for public APIs

### Bash Script Style
- Use `set -euo pipefail` for error handling
- Use lowercase for local variables, UPPERCASE for constants
- Quote all variable expansions: `"$variable"`
- Use `[[ ]]` for conditionals
- Log functions: `log_info()`, `log_warn()`, `log_error()`

## Testing and Debugging

### View Logs
```bash
# Watch all logs
tail -f logs/*.log

# Individual component logs
tail -f logs/cavernpipe.log   # CavernPipeServer
tail -f logs/client.log       # CavernPipeClient
tail -f logs/snapserver.log   # Snapserver
```

### Enable Debug Mode
```bash
export DEBUG=1
./scripts/run.sh
```

### Run Diagnostics
```bash
# Comprehensive diagnostic check
./scripts/diagnose.sh
```

### Test Individual Components
```bash
# Test CavernPipeClient handshake
echo "test" | dotnet src/CavernPipeClient/bin/Debug/net8.0/CavernPipeClient.dll \
  2 48000 16 2>&1 | grep "Handshake"

# Test with generated audio
ffmpeg -f lavfi -i "sine=frequency=1000:duration=5" -c:a ac3 -f ac3 - | \
  dotnet src/CavernPipeClient/bin/Debug/net8.0/CavernPipeClient.dll 2 48000 16 | \
  dotnet src/PipeToFifo/bin/Debug/net8.0/PipeToFifo.dll /tmp/test-output.fifo
```

### Quick Diagnostics
```bash
# Check if pipeline is running
ps aux | grep -E "(CavernPipe|snapserver)"

# Check FIFO
ls -la /tmp/snapcast-out

# Check ports
lsof -i :1704  # Snapcast stream
lsof -i :1705  # Snapcast control
lsof -i :1780  # Snapcast HTTP
```

## Protocol Specification

### CavernPipe Protocol Handshake (8 bytes)

| Byte | Type | Description |
|------|------|-------------|
| 0 | Byte | BitDepth enum value: 8=Int8, 16=Int16, 24=Int24, 32=Float32 |
| 1 | Byte | Mandatory frames before response |
| 2-3 | UInt16 | Output channel count (LE) |
| 4-7 | Int32 | Sample rate/UpdateRate (LE) |

**File-based mode**: Negative UpdateRate indicates file mode (e.g., -1024)
**Streaming mode**: Positive UpdateRate (e.g. 1024)

**Note**: Byte 0 is the raw bit depth value (8, 16, 24, or 32). The Cavern `BitDepth` enum uses these values directly.

### Data Exchange

After handshake:
- **Client → Server**: `[4 bytes: length] [N bytes: compressed audio or file path]`
- **Server → Client**: `[4 bytes: length] [N bytes: PCM audio]`

### Codec Sync Words
- AC-3 / E-AC-3: `0B 77`
- TrueHD: `F8 72 6F BA`
- DTS: `7F FE 80 01`

## Key Implementation Details

### File-based Mode (Recommended)
1. TrueHD files are converted to DAMF format using `truehdd`
2. DAMF files are cached in `~/.cavern-wireless/cache/`
3. CavernPipeClient sends file path to server with negative UpdateRate
4. CavernPipeServer opens file directly, renders spatial audio
5. PCM output flows through FIFO to Snapserver

### Two Operation Modes

**CavernPipeClient modes:**
1. **File-based mode** (args[0] is a file path or -f flag):
   - Sends negative UpdateRate in handshake
   - Sends length-prefixed file path
   - Receives PCM until EOF marker (length=0)

2. **Streaming mode** (args are numeric):
   - Sends positive UpdateRate in handshake
   - Streams audio chunks from stdin
   - Uses lockstep protocol (send → receive)

### Critical Code Paths

**Handshake creation** (`src/CavernPipeClient/Program.cs`):
```csharp
// BitDepth must be converted to enum values:
// 16-bit -> 16 (BitDepth.Int16), 24-bit -> 24 (BitDepth.Int24), etc.
static byte ConvertToBitDepthEnum(byte bitDepth)
{
    return bitDepth switch
    {
        8 => 8,   // BitDepth.Int8
        16 => 16,  // BitDepth.Int16
        24 => 24,  // BitDepth.Int24
        32 => 32,  // BitDepth.Float32
        _ => 16    // Default to 16-bit
    };
}
```

**File path sending** (`src/CavernPipeClient/Program.cs`):
```csharp
byte[] pathBytes = System.Text.Encoding.UTF8.GetBytes(Path.GetFullPath(audioFile));
byte[] pathLength = BitConverter.GetBytes(pathBytes.Length);
await stream.WriteAsync(pathLength, 0, 4);
await stream.WriteAsync(pathBytes, 0, pathBytes.Length);
```

**Argument Parsing** (`src/CavernPipeClient/Program.cs`):
```csharp
// File-based mode: -f <file> [channels] [bitDepth]
// Streaming mode: [channels] [sampleRate] [bitDepth]
```

## Security Considerations

1. **Unix Domain Sockets**: Uses temp directory sockets (`/var/folders/.../CoreFxPipe_CavernPipe`)
2. **FIFO in /tmp**: World-writable directory, but FIFO permissions depend on umask
3. **No Authentication**: Snapcast and CavernPipe have no authentication mechanisms
4. **Network Exposure**: Snapserver binds to all interfaces by default (ports 1704, 1705, 1780)
5. **File Path Validation**: CavernPipeServer should validate file paths in file-based mode

## Dependencies and Licenses

| Component | License |
|-----------|---------|
| CavernPipeClient, PipeToFifo, StreamingAdapter | MIT |
| Cavern | See upstream license (https://github.com/VoidXH/Cavern) |
| Snapcast | GPLv3 |
| truehdd | Check upstream repository |

## Troubleshooting Quick Reference

| Issue | Solution |
|-------|----------|
| No sound | Check `ffprobe` for codec, verify logs, restart pipeline |
| Decoder hang | Increase `InitialBurst` in client, rebuild |
| Server not found | Run `./scripts/run.sh`, check socket path |
| FIFO issues | Ensure `run.sh` is running or create with `mkfifo` |
| Build failures | Install .NET 8.0 SDK, clean and rebuild |
| Missing runtimeconfig.json | Run `./scripts/build.sh` to copy config files |
| Format mismatch | Ensure snapserver.conf sampleformat matches environment variables |
| TrueHD not playing | Run cavern-wireless.sh first to convert and cache |
| Abort trap: 6 | Check BitDepth enum values in handshake (16→16, 24→24) |

## References

- Cavern: https://github.com/VoidXH/Cavern
- truehdd: https://github.com/truehdd/truehdd
- Snapcast: https://github.com/badaix/snapcast
- CavernPipe Protocol: `docs/PROTOCOL.md`
- Troubleshooting: `docs/TROUBLESHOOTING.md`
- New Features: `docs/NEW_FEATURES.md`
- Project Purpose: `docs/PROJECT_PURPOSE.md`
