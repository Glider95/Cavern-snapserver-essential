# New Features and Improvements

## Overview

This document describes the improvements made to the CavernPipe Snapcast Bridge to address three key issues:
1. Audio artifacts and sound cuts
2. Integration of cavern-wireless process into WebUI
3. Streaming support with the same conversion pipeline

---

## 1. Audio Artifacts & Sound Cuts Fix

### Problem
Small audio artifacts and occasional sound cuts were caused by:
- Buffer underruns in the FIFO/pipe chain
- Insufficient buffering in the pipeline components
- No pre-buffering before starting audio output

### Solution

#### A. Enhanced Snapserver Configuration (`config/snapserver.conf`)

Increased buffer settings for more stable playback:

```ini
# Increased from 60ms to 80ms for more stable chunks
chunk_ms = 80

# Increased from 250ms to 400ms pre-buffering
read_ahead = 400

# Increased from 2000ms to 3000ms server buffer
buffer = 3000

# Added initial volume for faster buffer fill
initial_volume = 85

# Increased client buffer
buffer = 2000
latency = 200
```

#### B. New Buffered PipeToFifo (`src/PipeToFifo/Program.cs`)

Replaced the simple pipe writer with a threaded circular buffer implementation:

**Key Features:**
- **Circular Buffer**: 1MB (configurable) circular buffer between stdin and FIFO
- **Pre-buffering**: Waits for 64KB of audio data before starting output
- **Threaded Design**: Separate reader and writer threads for smooth data flow
- **Configurable Buffer Size**: Pass buffer size in KB as second argument

**Usage:**
```bash
# Default 1MB buffer
dotnet PipeToFifo.dll /tmp/snapcast-out

# Larger 2MB buffer for problematic files
dotnet PipeToFifo.dll /tmp/snapcast-out 2048
```

#### C. Buffer Settings Summary

| Component | Old | New | Improvement |
|-----------|-----|-----|-------------|
| Snapserver chunk_ms | 60ms | 80ms | 33% larger chunks |
| Snapserver read_ahead | 250ms | 400ms | 60% more pre-buffer |
| Snapserver buffer | 2000ms | 3000ms | 50% larger buffer |
| PipeToFifo | None | 1MB circular | Prevents underruns |
| Client buffer | Default | 2MB | Configurable |

---

## 2. WebUI with Cavern-Wireless Integration

### Problem
The original WebUI only called `play.sh` which:
- Didn't auto-detect codecs
- Didn't convert TrueHD to DAMF
- Didn't cache converted files
- Had no visibility into conversion progress

### Solution

#### A. Enhanced Backend (`web-ui/server.py`)

New API endpoints and features:

**New Endpoints:**
- `POST /api/analyze` - Detect codec and check cache
- `POST /api/convert` - Start TrueHD → DAMF conversion
- `GET /api/convert/status` - Get conversion progress
- `POST /api/play` - Enhanced play with auto-conversion
- `POST /api/play/stop` - Stop current playback
- `POST /api/stream/start` - Start streaming (system/URL)

**Key Features:**
1. **Codec Detection**: Uses ffprobe to detect audio codec before playback
2. **Automatic Conversion**: TrueHD files are automatically converted using truehdd
3. **Caching**: Converted files cached in `~/.cavern-wireless/cache/`
4. **Progress Tracking**: Real-time conversion progress via polling
5. **Playback State**: Tracks current playback status and file

#### B. Enhanced Frontend (`web-ui/index.html`)

**New UI Features:**

1. **Codec Analysis Section**
   - Shows detected codec with color-coded badges
   - Warns about TrueHD files requiring conversion
   - Shows cached status

2. **Conversion Progress**
   - Visual progress bar
   - Current stage (detecting/extracting/converting/complete)
   - Status messages

3. **Tabbed Interface**
   - **File Tab**: Play local media files
   - **Stream Tab**: Stream from system audio or URL

4. **Playback Controls**
   - Play/Stop for files and streams
   - Current file display
   - Playback status indicator

#### C. Usage

```bash
# Start WebUI
./scripts/web-ui.sh

# Open http://localhost:8080
# 1. Select a file
# 2. Click "Analyze" to detect codec
# 3. If TrueHD, click "Convert TrueHD"
# 4. Click "Play" when ready
```

---

## 3. Streaming Support

### Problem
Streaming from applications required separate scripts and didn't benefit from:
- TrueHD conversion
- File-based mode reliability
- Cached audio files

### Solution

#### A. Unified Streaming API

The `POST /api/stream/start` endpoint supports three sources:

1. **System Audio** (`source: "system"`)
   - Captures from BlackHole (macOS) or PulseAudio (Linux)
   - Uses file-based extraction for reliability

2. **URL Stream** (`source: "url"`, `url: "..."`)
   - Streams from HTTP URLs
   - Extracts to temp file before playback

#### B. Streaming Process

```
Application Audio / URL
    ↓
FFmpeg (capture/extract)
    ↓
Temp File / Direct PCM
    ↓
CavernPipeClient (streaming mode)
    ↓
PipeToFifo (buffered)
    ↓
Snapserver → Network
```

#### C. WebUI Streaming Controls

**System Audio Setup:**
1. Go to Stream tab
2. Select "System Audio (BlackHole/PulseAudio)"
3. Set your system output to BlackHole (macOS) or virtual sink (Linux)
4. Click "Start Streaming"

**URL Streaming:**
1. Go to Stream tab  
2. Select "URL Stream"
3. Enter stream URL
4. Click "Start Streaming"

---

## Configuration Recommendations

### For Artifact-Free Playback

1. **Use file-based mode when possible** (WAV/Atmos files)
2. **Increase buffer size** for network streams:
   ```bash
   # In snapserver.conf
   buffer = 3000
   chunk_ms = 80
   ```
3. **Use larger PipeToFifo buffer** for TrueHD content:
   ```bash
   dotnet PipeToFifo.dll /tmp/snapcast-out 2048  # 2MB
   ```

### For TrueHD Content

1. **Pre-convert** using WebUI or cavern-wireless.sh
2. **Cached files** are reused automatically
3. **Conversion is one-time** - subsequent plays are instant

### For Streaming

1. **System audio**: Install BlackHole (macOS) or use PulseAudio (Linux)
2. **URL streams**: Ensure stable network connection
3. **Buffer settings**: Increase latency for unstable networks

---

## Troubleshooting

### Still Getting Artifacts?

1. Check buffer levels in WebUI "Streaming Metrics"
2. Increase snapserver buffer to 4000ms
3. Use larger PipeToFifo buffer (4096 = 4MB)
4. Ensure pipeline is running before playback

### TrueHD Conversion Failing?

1. Check truehdd is built: `ls /tmp/truehdd/target/release/truehdd`
2. Check logs: `tail -f logs/cavernpipe.log`
3. Verify FFmpeg is installed

### Streaming Not Working?

1. For system audio: Check BlackHole is installed and selected
2. For URLs: Verify URL is accessible: `curl -I <url>`
3. Check FFmpeg logs: `tail -f logs/ffmpeg.log`

---

## Performance Comparison

| Scenario | Before | After | Improvement |
|----------|--------|-------|-------------|
| TrueHD playback | Artifacts, cuts | Smooth | Pre-conversion + buffering |
| Network streaming | Occasional drops | Stable | Larger buffers |
| WebUI playback | Manual conversion | Auto-conversion | One-click operation |
| File caching | None | Automatic | Instant replay |
