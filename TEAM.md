# Cavern Snapcast Bridge - Team Coordination

## Project Overview
Building a wireless Dolby Atmos spatial audio pipeline using:
- **Cavern** - Spatial audio rendering engine
- **Snapcast** - Multi-room synchronized audio distribution
- **ESP32-C5 + TAS5825M** - Wireless speaker endpoints

## Architecture
```
Media File (TrueHD/E-AC-3/DTS)
    ↓
FFmpeg → truehdd → DAMF (cached)
    ↓
CavernPipeClient (file-based mode)
    ↓ [Named Pipe/Unix Socket]
CavernPipeServer (spatial rendering)
    ↓ [PCM 6ch/16-bit/48kHz]
Snapserver → Network (TCP/1704)
    ↓
Snapclients (ESP32/Speakers)
```

## Source Location
`C:\Users\nicol\Downloads\Cavern-snapserver-essential-main\Cavern-snapserver-essential-main\`

## Team Roles

### Agent 1: Build Engineer
- Build all .NET components (CavernPipeClient, PipeToFifo, StreamingAdapter)
- Set up CavernPipeServer with patches
- Create build automation scripts
- Verify all binaries are functional

### Agent 2: Windows Integration Specialist  
- Test Windows-specific features (Named Pipes, TCP streaming)
- Verify PowerShell scripts work correctly
- Test Snapserver emulator mode
- Validate FFmpeg integration

### Agent 3: Audio Pipeline Tester
- Test TrueHD/Dolby Atmos file playback
- Verify DAMF caching works
- Test spatial audio rendering output
- Validate PCM output format

### Agent 4: Documentation & GitHub Sync
- Document findings and fixes
- Set up GitHub repository sync
- Create comprehensive README updates
- Track issues and resolutions

## Progress Tracking
- [ ] All .NET components build successfully
- [ ] PowerShell scripts execute without errors
- [ ] Audio pipeline processes test files
- [ ] Snapserver emulator accepts connections
- [ ] End-to-end playback works
- [ ] Documentation updated
- [ ] GitHub sync configured

## Discord Channel
Progress reports will be sent to Discord channel for visibility.

## Notes
- Windows host with .NET 8.0 SDK installed
- FFmpeg included in project
- Cavern library needs to be obtained/built
- truehdd not available on Windows (FFmpeg fallback)
