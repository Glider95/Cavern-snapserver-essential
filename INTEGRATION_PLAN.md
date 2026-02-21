# Cavern-Snapcast Integration Architecture

## Goal
Drop-in solution: User plays Atmos file in VLC → Cavern decodes → Snapcast streams → Wireless speakers play spatial audio

## Components to Build

### 1. VLC Plugin/Bridge (Windows)
**Option A: VLC Lua Extension** (Preferred - Native integration)
- Lua script that hooks into VLC's audio output
- Captures audio stream, sends to CavernPipe
- UI panel in VLC for speaker config

**Option B: Virtual Audio Driver + Bridge**
- Install VB-Cable or similar virtual audio device
- Background service captures audio from virtual output
- Routes to Cavern pipeline

### 2. Audio Pipeline Flow
```
VLC/Media Player 
    ↓ (Audio Output)
Virtual Audio Capture / VLC Plugin
    ↓ (Raw Audio Stream)
CavernPipeClient (Atmos Decoder)
    ↓ (Decoded Spatial Audio - Multi-channel)
Snapserver (via named pipe/FIFO)
    ↓ (FLAC/PCM Stream)
Snapclients (ESP32-C5 receivers)
    ↓ (I2S to DAC/Amplifier)
Wireless Speakers
```

### 3. Speaker Management UI
- Web-based configuration interface
- Or Windows tray application
- Features:
  - Add/remove speakers
  - Set speaker positions (3D coordinates)
  - Configure channel assignments
  - Volume per speaker
  - Test tone generator
  - Calibration wizard

### 4. ESP32-C5 Snapclient
Reference: https://github.com/Glider95/snapclient
- Custom firmware for ESP32-C5
- I2S output to DAC
- WiFi configuration
- Multi-channel support

## Phase 2 Implementation Plan

### Step 1: VLC Integration Prototype
- Create VLC Lua extension
- Test audio capture from VLC
- Send to CavernPipe

### Step 2: Windows Audio Capture Service
- WASAPI loopback capture
- Route to Cavern
- System-wide solution (works with any player)

### Step 3: Speaker Configuration UI
- Web interface (React/Vue)
- Or WPF Windows app
- Real-time speaker position editor
- JSON config file

### Step 4: End-to-End Testing
- Full pipeline test
- Latency optimization
- Multi-speaker sync

## Technical Decisions Needed

1. **VLC Integration Method?**
   - Lua extension (cleaner, VLC-native)
   - Virtual audio driver (works with any player)
   - Both options?

2. **Speaker Config UI?**
   - Web-based (accessible from phone/tablet)
   - Windows desktop app
   - Both?

3. **Audio Format?**
   - Keep PCM (highest quality, higher bandwidth)
   - Use FLAC compression (lower bandwidth)
   - Make it configurable

4. **Speaker Discovery?**
   - Manual IP entry
   - mDNS auto-discovery
   - Both?

Let me know your preferences and I'll start building!
