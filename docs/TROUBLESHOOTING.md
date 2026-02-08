# Troubleshooting Guide

## Quick Diagnostics

```bash
# Check if pipeline is running
ps aux | grep -E "(CavernPipe|snapserver)"

# Check FIFO
ls -la /tmp/snapcast-out

# Check logs
tail -f logs/*.log
```

## Common Issues

### 1. No Sound

**Symptoms:** Pipeline runs but no audio output

**Checks:**
```bash
# 1. Verify file has supported codec
ffprobe -v error -select_streams a:0 -show_entries stream=codec_name file.mkv

# 2. Check CavernPipeServer is receiving data
grep "First input chunk" logs/client.log

# 3. Check CavernPipeServer is outputting PCM
grep "First PCM chunk" logs/client.log

# 4. Check FIFO is being written
ls -la /tmp/snapcast-out
```

**Solutions:**
- Ensure file contains AC-3, E-AC-3, or TrueHD audio
- Check logs for errors: `tail -f logs/*.log`
- Restart pipeline: `pkill -f CavernPipe; pkill snapserver; ./scripts/run.sh`

### 2. Decoder Initialization Hang

**Symptoms:** CavernPipeClient connects but never receives PCM

**Logs show:**
```
[CavernPipeClient] Connected
[CavernPipeClient] Handshake sent
[CavernPipeClient] First input chunk: 4096 bytes
(no "First PCM chunk" message)
```

**Solution:** Increase initial burst in `src/CavernPipeClient/Program.cs`:
```csharp
const int InitialBurst = 10;  // Try 15 or 20
```

Rebuild: `./scripts/build.sh`

### 3. CavernPipeServer Not Found

**Symptoms:** `CavernPipe socket not found`

**Check:**
```bash
# Server running?
ps aux | grep CavernPipeServer

# Socket exists?
find /var/folders -name "CoreFxPipe_CavernPipe" 2>/dev/null
```

**Solution:**
```bash
# Start pipeline
./scripts/run.sh
```

### 4. FIFO Issues

**Symptoms:** `No such file or directory: /tmp/snapcast-out`

**Solution:**
```bash
# FIFO created by run.sh, ensure it's running
./scripts/run.sh

# Or create manually
mkfifo /tmp/snapcast-out
```

### 5. Snapserver Connection Issues

**Symptoms:** `Connection refused` when connecting snapclient

**Check:**
```bash
# Snapserver running?
ps aux | grep snapserver

# Port open?
lsof -i :1704

# Config correct?
cat config/snapserver.conf
```

**Solution:**
```bash
# Restart snapserver
pkill snapserver
snapserver -c config/snapserver.conf > logs/snapserver.log 2>&1 &
```

### 6. Build Failures

**Symptoms:** `dotnet build` fails

**Solution:**
```bash
# Install .NET SDK
# macOS
brew install dotnet-sdk

# Linux
sudo apt-get install dotnet-sdk-8.0

# Clean and rebuild
rm -rf src/*/bin src/*/obj
./scripts/build.sh
```

## Advanced Debugging

### Enable Debug Logging

```bash
export DEBUG=1
./scripts/run.sh
./scripts/play.sh file.mkv
```

### Monitor Data Flow

```bash
# Terminal 1: Watch CavernPipeClient
tail -f logs/client.log

# Terminal 2: Watch CavernPipeServer
tail -f logs/cavernpipe.log

# Terminal 3: Watch Snapserver
tail -f logs/snapserver.log
```

### Test Individual Components

**1. Test CavernPipeClient handshake:**
```bash
echo "test" | dotnet src/CavernPipeClient/bin/Debug/net8.0/CavernPipeClient.dll \
  2 48000 16 2>&1 | grep "Handshake"
```

**2. Test with generated audio:**
```bash
# Generate 5 seconds of AC-3
ffmpeg -f lavfi -i "sine=frequency=1000:duration=5" -c:a ac3 -f ac3 - | \
  dotnet src/CavernPipeClient/bin/Debug/net8.0/CavernPipeClient.dll 2 48000 16 | \
  dotnet src/PipeToFifo/bin/Debug/net8.0/PipeToFifo.dll /tmp/test-output.fifo
```

**3. Test FFmpeg extraction:**
```bash
ffmpeg -i file.mkv -map 0:a:0 -c:a copy -f data - | hexdump -C | head
# Should see 0B 77 (AC-3) or F8 72 6F BA (TrueHD)
```

## Log Analysis

### Normal Operation

**client.log:**
```
[CavernPipeClient] Connecting to CavernPipe...
[CavernPipeClient] Found pipe at: /var/folders/.../CoreFxPipe_CavernPipe
[CavernPipeClient] Connected to CavernPipe.
[CavernPipeClient] Handshake sent: 10-06-02-00-80-BB-00-00
[CavernPipeClient] First input chunk: 4096 bytes
[CavernPipeClient] First PCM chunk: 8192 bytes
[CavernPipeClient] Processed 1000 input chunks, 990 PCM chunks.
```

**cavernpipe.log:**
```
CavernPipeServer started.
Client connected.
Processing audio...
```

### Error Indicators

**Connection timeout:**
```
[CavernPipeClient] ERROR: Connection timeout
```
→ CavernPipeServer not running

**Invalid PCM length:**
```
[CavernPipeClient] Invalid PCM length: -1
```
→ Protocol mismatch or server error

**Server closed connection:**
```
[CavernPipeClient] Server closed connection (no length prefix)
```
→ CavernPipeServer crashed or rejected handshake

## Getting Help

When reporting issues, include:

1. **System info:**
   ```bash
   uname -a
   dotnet --version
   snapserver --version
   ```

2. **File info:**
   ```bash
   ffprobe -v error -show_streams file.mkv
   ```

3. **Logs:**
   ```bash
   cat logs/client.log logs/cavernpipe.log logs/snapserver.log
   ```

4. **Process status:**
   ```bash
   ps aux | grep -E "(CavernPipe|snapserver)"
   lsof /tmp/snapcast-out
   ```
