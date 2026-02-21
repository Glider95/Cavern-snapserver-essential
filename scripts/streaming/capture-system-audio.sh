#!/usr/bin/env bash
#
# System Audio Capture for CavernPipe
# Captures audio from a virtual audio device and streams to CavernPipe
#
# Requirements:
#   macOS: BlackHole (brew install blackhole-2ch or blackhole-16ch)
#   Linux: PulseAudio or PipeWire with loopback module
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Configuration
OUTPUT_CHANNELS=${OUTPUT_CHANNELS:-6}
SAMPLE_RATE=${SAMPLE_RATE:-48000}
BIT_DEPTH=${BIT_DEPTH:-16}
CAPTURE_DURATION=${CAPTURE_DURATION:-0}  # 0 = unlimited

# Virtual audio device names
VIRTUAL_DEVICE_MACOS="BlackHole 16ch"    # or "BlackHole 2ch"
VIRTUAL_DEVICE_LINUX="cavern_capture"     # PulseAudio sink name

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Detect OS
detect_os() {
    case "$(uname -s)" in
        Darwin*) echo "macos" ;;
        Linux*)  echo "linux" ;;
        *)       echo "unknown" ;;
    esac
}

# Check prerequisites
check_prerequisites() {
    local os="$1"
    
    log_info "Checking prerequisites for $os..."
    
    if [[ "$os" == "macos" ]]; then
        # Check for BlackHole
        if ! system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole"; then
            log_error "BlackHole not found. Please install it:"
            log_error "  brew install blackhole-2ch    # For stereo capture"
            log_error "  brew install blackhole-16ch   # For multi-channel capture"
            log_error ""
            log_error "Then set BlackHole as your system output device in System Preferences > Sound"
            exit 1
        fi
        log_info "BlackHole virtual audio device found"
        
    elif [[ "$os" == "linux" ]]; then
        # Check for PulseAudio or PipeWire
        if command -v pactl &>/dev/null; then
            log_info "PulseAudio detected"
        elif command -v pw-cli &>/dev/null; then
            log_info "PipeWire detected"
        else
            log_error "Neither PulseAudio nor PipeWire found"
            exit 1
        fi
    fi
    
    # Check ffmpeg
    if ! command -v ffmpeg &>/dev/null; then
        log_error "ffmpeg not found. Please install it."
        exit 1
    fi
}

# Setup virtual audio device on Linux
setup_linux_capture() {
    log_info "Setting up PulseAudio/PipeWire capture..."
    
    # Create a null sink for capturing
    if pactl list | grep -q "Name: $VIRTUAL_DEVICE_LINUX"; then
        log_info "Virtual sink already exists"
    else
        pactl load-module module-null-sink sink_name=$VIRTUAL_DEVICE_LINUX sink_properties=device.description="CavernCapture"
        log_info "Created virtual sink: $VIRTUAL_DEVICE_LINUX"
    fi
    
    # Create a loopback from monitor to null sink (optional, for monitoring)
    pactl load-module module-loopback source=${VIRTUAL_DEVICE_LINUX}.monitor sink=$VIRTUAL_DEVICE_LINUX 2>/dev/null || true
    
    echo "$VIRTUAL_DEVICE_LINUX"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    # Kill ffmpeg if running
    pkill -P $$ 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Get audio device for ffmpeg
get_ffmpeg_device() {
    local os="$1"
    
    if [[ "$os" == "macos" ]]; then
        # Find BlackHole device index
        ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -i "blackhole" -A1 | head -2
        # Return avfoundation device string
        echo ":BlackHole 16ch"
    elif [[ "$os" == "linux" ]]; then
        local sink_name=$(setup_linux_capture)
        echo "pulse:${sink_name}.monitor"
    fi
}

# Main capture function
capture_audio() {
    local os="$1"
    local output_fifo="$2"
    
    log_info "Starting audio capture..."
    log_info "Output: ${OUTPUT_CHANNELS}ch @ ${SAMPLE_RATE}Hz, ${BIT_DEPTH}-bit"
    log_info "Duration: ${CAPTURE_DURATION}s (0 = unlimited)"
    
    # Build ffmpeg command based on OS
    local ffmpeg_input
    local ffmpeg_opts=""
    
    if [[ "$os" == "macos" ]]; then
        ffmpeg_input="-f avfoundation -i \":BlackHole 16ch\""
    elif [[ "$os" == "linux" ]]; then
        local sink_name=$(setup_linux_capture)
        ffmpeg_input="-f pulse -i ${sink_name}.monitor"
    fi
    
    # Duration limit if specified
    if [[ "$CAPTURE_DURATION" -gt 0 ]]; then
        ffmpeg_opts="-t $CAPTURE_DURATION"
    fi
    
    log_info "Capturing from virtual audio device..."
    log_info "Press Ctrl+C to stop"
    
    # Capture and output raw PCM
    eval ffmpeg -hide_banner -loglevel error \
        $ffmpeg_input \
        -acodec pcm_s${BIT_DEPTH}le \
        -ar $SAMPLE_RATE \
        -ac $OUTPUT_CHANNELS \
        -f s${BIT_DEPTH}le \
        $ffmpeg_opts \
        - \
        > "$output_fifo"
}

# Show usage
usage() {
    cat << EOF
System Audio Capture for CavernPipe

Captures audio from a virtual audio device and streams to the CavernPipe pipeline.
This allows streaming from applications like VLC, Stremio, browsers, etc.

Usage: $(basename "$0") [OPTIONS] <output_fifo>

Options:
    -h, --help          Show this help
    -c, --channels N    Output channels (default: $OUTPUT_CHANNELS)
    -r, --rate HZ       Sample rate (default: $SAMPLE_RATE)
    -b, --bits N        Bit depth: 16, 24, 32 (default: $BIT_DEPTH)
    -t, --time SEC      Capture duration in seconds (default: 0 = unlimited)
    --setup             Show setup instructions for your OS

Arguments:
    output_fifo         Path to FIFO or "-" for stdout

Examples:
    # Capture to stdout (for piping)
    $(basename "$0") - > output.raw

    # Capture to snapcast FIFO
    $(basename "$0") /tmp/snapcast-out

    # Capture for 60 seconds with 8 channels
    $(basename "$0") -c 8 -t 60 /tmp/snapcast-out

Setup Instructions:
    macOS:
      1. Install BlackHole: brew install blackhole-16ch
      2. Open Audio MIDI Setup
      3. Create Multi-Output Device with your speakers + BlackHole
      4. Set Multi-Output as system output
      5. Run this script

    Linux (PulseAudio):
      1. This script will create a virtual sink automatically
      2. Set the virtual sink as default: pactl set-default-sink cavern_capture
      3. Run this script

    Linux (PipeWire):
      1. Virtual sinks work similarly to PulseAudio
      2. Use pw-cli or pavucontrol to route audio

EOF
}

# Show setup instructions
show_setup() {
    local os=$(detect_os)
    
    cat << EOF

=== Setup Instructions for $(uname -s) ===

macOS with BlackHole:
--------------------
1. Install BlackHole:
   brew install blackhole-16ch

2. Open "Audio MIDI Setup" (search in Spotlight)

3. Create a Multi-Output Device:
   - Click the "+" button in the bottom left
   - Select "Create Multi-Output Device"
   - Check both your speakers AND "BlackHole 16ch"
   - Set "BlackHole 16ch" as the master (clock source)

4. Set the Multi-Output Device as your system output:
   - System Preferences > Sound > Output
   - Select your Multi-Output Device

5. Run the capture script:
   ./scripts/streaming/capture-system-audio.sh /tmp/snapcast-out

6. Play audio from any application (VLC, Stremio, browser)
   The audio will be captured and sent to CavernPipe.

Linux with PulseAudio:
---------------------
1. The script will automatically create a virtual sink

2. Set the virtual sink as default:
   pactl set-default-sink cavern_capture

3. Or use pavucontrol to route specific apps to the virtual sink

4. Run the capture script:
   ./scripts/streaming/capture-system-audio.sh /tmp/snapcast-out

Tips:
-----
- You can monitor the captured audio by connecting to the virtual device
- Use pavucontrol (Linux) or Audio MIDI Setup (macOS) to control routing
- Combine with run.sh for a complete streaming pipeline

EOF
}

# Parse arguments
OUTPUT_FIFO=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --setup)
            show_setup
            exit 0
            ;;
        -c|--channels)
            OUTPUT_CHANNELS="$2"
            shift 2
            ;;
        -r|--rate)
            SAMPLE_RATE="$2"
            shift 2
            ;;
        -b|--bits)
            BIT_DEPTH="$2"
            shift 2
            ;;
        -t|--time)
            CAPTURE_DURATION="$2"
            shift 2
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            OUTPUT_FIFO="$1"
            shift
            ;;
    esac
done

# Validate
if [[ -z "$OUTPUT_FIFO" ]]; then
    log_error "No output FIFO specified"
    usage
    exit 1
fi

if [[ "$OUTPUT_FIFO" != "-" && ! -p "$OUTPUT_FIFO" ]]; then
    log_warn "FIFO does not exist: $OUTPUT_FIFO"
    log_info "Creating FIFO..."
    mkfifo "$OUTPUT_FIFO" 2>/dev/null || true
fi

# Detect OS and run
OS=$(detect_os)

if [[ "$OS" == "unknown" ]]; then
    log_error "Unsupported operating system: $(uname -s)"
    exit 1
fi

check_prerequisites "$OS"

# Start capture
capture_audio "$OS" "$OUTPUT_FIFO"
