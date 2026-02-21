# 🎧 Cavern-VLC Integration

**One-click Dolby Atmos streaming from VLC to wireless speakers**

This integration provides a seamless way to play Dolby Atmos content in VLC and stream decoded spatial audio wirelessly to ESP32-based speakers via Snapcast.

## 🎯 Goal: "Click → Play → Atmos on Speakers"

```
VLC/Media Player
    ↓ (Audio Output)
VlcAudioBridge / VLC Extension
    ↓ (Raw Audio)
Cavern (Atmos Decoder)
    ↓ (Multi-channel Spatial Audio)
Snapserver
    ↓ (Network Stream)
ESP32-C5 Snapclients
    ↓ (I2S)
Wireless Speakers 🎵
```

## 📦 Components

### 1. **VlcAudioBridge** (Windows Service)
Captures system audio using WASAPI loopback and routes to Cavern pipeline.

```powershell
# Start the bridge
VlcAudioBridge.exe

# Custom pipe and config
VlcAudioBridge.exe -p MyPipe -c config.json
```

### 2. **VLC Extension** (`cavern_atmos.lua`)
Native VLC plugin for spatial audio control.

**Features:**
- ✅ Enable/disable spatial audio from VLC menu
- 🔊 Speaker configuration UI
- 📊 Real-time pipeline status
- 🎧 Automatic Atmos detection
- 📡 Speaker discovery

**Installation:**
```powershell
# Copy to VLC extensions folder
Copy-Item vlc-extension\cavern_atmos.lua "$env:APPDATA\vlc\lua\extensions\"
```

**Access:** View → Cavern Spatial Audio

### 3. **Speaker UI** (Web Interface)
Beautiful web-based speaker management.

**Features:**
- 🎯 Visual room layout with drag-and-drop speaker positioning
- 🔊 Individual speaker volume control
- 📡 Auto-discovery of ESP32 speakers
- ⚡ Calibration tools
- 💾 Save/load presets

**Usage:**
```powershell
# Start a local server
cd speaker-ui
python -m http.server 8080

# Or open directly
start speaker-ui\index.html
```

## 🚀 Quick Start

### Prerequisites
- Windows 10/11
- VLC Media Player
- .NET 8.0 Runtime
- ESP32-C5 speakers with Snapclient firmware

### Installation

1. **Build the components:**
```powershell
cd VlcAudioBridge
dotnet build -c Release
```

2. **Install VLC Extension:**
```powershell
Copy-Item vlc-extension\cavern_atmos.lua "$env:APPDATA\vlc\lua\extensions\"
```

3. **Start the pipeline:**
```powershell
# Terminal 1: Start CavernPipeServer
.\CavernPipeServer.exe

# Terminal 2: Start Audio Bridge
.\VlcAudioBridge.exe

# Terminal 3: Start Snapserver
.\snapserver.exe -c snapserver.conf
```

4. **Play Atmos content in VLC**
   - Open VLC
   - Go to View → Cavern Spatial Audio
   - Click "Enable Spatial Audio"
   - Play any Dolby Atmos file
   - Enjoy wireless spatial audio! 🎉

## 🎛️ Speaker Configuration

### Via Web UI

1. Open `speaker-ui/index.html` in browser
2. Click "Add Speaker"
3. Enter:
   - Name (e.g., "Living Room Left")
   - IP Address of ESP32
   - Position (x, y, z in meters)
4. Drag speaker to position in room view
5. Save configuration

### JSON Config Format

```json
{
  "speakers": [
    {
      "name": "Front Left",
      "ip": "192.168.1.101",
      "pos": "-2, 2, 0",
      "volume": 100,
      "enabled": true
    },
    {
      "name": "Front Right", 
      "ip": "192.168.1.102",
      "pos": "2, 2, 0",
      "volume": 100,
      "enabled": true
    }
  ],
  "room": {
    "width": 6,
    "depth": 6,
    "height": 3
  }
}
```

## 🔧 ESP32-C5 Speaker Setup

Based on your existing work at [Glider95/snapclient](https://github.com/Glider95/snapclient):

### Flashing

```bash
git clone https://github.com/Glider95/snapclient.git
cd snapclient
# Modify for ESP32-C5 if needed
idf.py set-target esp32c5
idf.py build
idf.py flash
```

### WiFi Configuration

The ESP32 will create an AP for initial setup:
1. Connect to `CavernSpeaker-XXXX` WiFi
2. Open http://192.168.4.1
3. Enter your WiFi credentials
4. Speaker will appear in the web UI

## 📐 Speaker Positioning Guide

For best Atmos effect, position speakers in a 3D array:

```
Top View:
    [FL]        [FR]
              👤 (Listening position)
    [SL]        [SR]
    
    [RL]        [RR]

Side View:
    [TF]        [TF]  (Top Front)
              👤
    [FL]        [FR]  (Front)
    
Height speakers (TF, TR) should be 45° above ear level
```

## 🔊 Supported Audio Formats

- ✅ Dolby Atmos (E-AC-3)
- ✅ Dolby TrueHD
- ✅ Dolby Digital Plus
- ✅ 5.1/7.1 Channel audio
- ✅ Stereo (upmixed to spatial)

## ⚡ Performance & Latency

| Component | Latency |
|-----------|---------|
| WASAPI Capture | ~10ms |
| Cavern Decode | ~20ms |
| Snapcast Buffer | ~50ms |
| Network (WiFi) | ~10-30ms |
| **Total** | **~90-110ms** |

For lip-sync, most media players can delay video by ~100ms.

## 🛠️ Troubleshooting

### No audio from speakers

1. Check ESP32 is connected to WiFi
2. Verify snapserver is running: `telnet localhost 1705`
3. Check audio bridge is capturing: enable `VAB_DEBUG=1`
4. Test with test tone in web UI

### Audio stuttering

1. Increase snapserver buffer: `buffer = 1000` in config
2. Check WiFi signal strength on ESP32
3. Reduce audio quality: use FLAC instead of PCM
4. Enable QoS on router for snapcast traffic

### Atmos not detected

1. Verify source file has Atmos metadata
2. Check VLC is outputting raw audio (not resampling)
3. Manually enable spatial audio in VLC extension

## 🎮 Advanced Usage

### Multiple Rooms

Create separate snapserver instances per room:

```powershell
# Room 1: Living Room
snapserver.exe -p 1705 -c living-room.conf

# Room 2: Bedroom  
snapserver.exe -p 1706 -c bedroom.conf
```

### Integration with Home Assistant

```yaml
# configuration.yaml
media_player:
  - platform: snapcast
    host: localhost
    port: 1705
```

### Custom Audio Processing

Modify `CavernPipeClient` to add custom DSP:

```csharp
// Apply EQ, compression, etc.
audioData = ApplyEqualizer(audioData);
audioData = ApplyCompressor(audioData);
```

## 📚 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Windows PC                            │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐ │
│  │   VLC    │──▶│  WASAPI  │──▶│  Cavern  │──▶│ Snapcast │ │
│  │  Player  │   │ Capture  │   │  Decoder │   │  Server  │ │
│  └──────────┘   └──────────┘   └──────────┘   └────┬─────┘ │
│                                                    │       │
└────────────────────────────────────────────────────┼───────┘
                                                     │
                          WiFi/Multicast             ▼
                                             ┌──────────────┐
                                             │ ESP32-C5     │
                                             │ Snapclient   │
                                             │ (x N speakers)│
                                             └──────┬───────┘
                                                    │
                                                    ▼
                                             ┌──────────────┐
                                             │   I2S DAC    │
                                             │  Amplifier   │
                                             │   Speaker    │
                                             └──────────────┘
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## 📄 License

MIT License - See LICENSE file

## 🙏 Acknowledgments

- [Cavern](https://github.com/VoidXH/Cavern) - Dolby Atmos decoder
- [Snapcast](https://github.com/badaix/snapcast) - Multiroom audio
- [ESP32-C5](https://www.espressif.com/) - Wireless SoC

---

**Made with ❤️ for wireless spatial audio**
