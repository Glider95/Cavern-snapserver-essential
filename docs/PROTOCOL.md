# CavernPipe Protocol

Complete specification for the CavernPipe inter-process audio rendering protocol.

## Connection

Client connects to CavernPipeServer via Unix domain socket:
- **macOS/Linux:** `/var/folders/.../CoreFxPipe_CavernPipe` (temp directory)
- **Windows:** `\\.\pipe\CavernPipe` (named pipe)

## Handshake (8 bytes)

**MUST be sent immediately after connection, before any audio data.**

| Byte | Type | Description | Example |
|------|------|-------------|---------|
| 0 | Byte | Bit depth enum (8/16/24/32) | `16` |
| 1 | Byte | Mandatory frames before response | `6` |
| 2-3 | UInt16 | Output channel count (LE) | `2` |
| 4-7 | Int32 | Sample rate in Hz (LE) | `48000` |

**Example:** `10-06-02-00-80-BB-00-00`
- Bit depth: 16-bit
- Mandatory frames: 6
- Channels: 2 (stereo)
- Sample rate: 48000 Hz

## Data Exchange

After handshake, client and server use lockstep protocol:

**Client → Server:**
```
[4 bytes: length] [N bytes: compressed audio]
```

**Server → Client:**
```
[4 bytes: length] [N bytes: PCM audio]
```

### Codec Sync Words

Compressed audio starts with codec-specific sync patterns:
- **AC-3 / E-AC-3:** `0B 77`
- **TrueHD:** `F8 72 6F BA`
- **DTS:** `7F FE 80 01`

### PCM Format

PCM is interlaced by channel, little-endian:
- **16-bit:** `[L_LSB][L_MSB][R_LSB][R_MSB]...`
- **24-bit:** `[L_B0][L_B1][L_B2][R_B0][R_B1][R_B2]...`

## Initial Burst Optimization

To prevent decoder initialization deadlock:
1. Client sends 10 chunks immediately
2. Server buffers and initializes decoder
3. Server responds with PCM
4. Normal lockstep continues

**Why needed:**
- Decoder needs multiple frames to initialize
- Strict lockstep would deadlock (client waits, server needs more data)

## Complete Pipeline

```
FFmpeg
  ↓ Raw bitstream (AC-3/E-AC-3/TrueHD)
CavernPipeClient
  ↓ [Handshake] then [Length + Data]...
CavernPipeServer (Unix Socket)
  ↓ [Length + PCM]...
CavernPipeClient
  ↓ PCM stream
PipeToFifo
  ↓ FIFO write
Snapserver
  ↓ Network
Clients
```

## Reference

Official specification: [CavernPipe Bitstream.md](../../docs/Format%20bitstream%20definitions/CavernPipe%20Bitstream.md)
