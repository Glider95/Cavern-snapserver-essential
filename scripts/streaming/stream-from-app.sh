#!/usr/bin/env bash
#
# Stream Audio from Application to CavernPipe
# Generic wrapper for streaming from VLC, Stremio, browsers, etc.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Configuration
OUTPUT_CHANNELS=${OUTPUT_CHANNELS:-6}
SAMPLE_RATE=${SAMPLE_RATE:-48000}
BIT_DEPTH=${BIT_DEPTH:-16}
FIFO="/tmp/snapcast-out"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1" >&2; }

# Check if pipeline is running
check_pipeline() {
    if [[ ! -p "$FIFO" ]]; then
        log_error "Pipeline not running. Start it first:"
        log_error "  ./scripts/run.sh"
        exit 1
    fi
    
    # Check CavernPipeServer
    if ! pgrep -f "CavernPipeServer" > /dev/null; then
        log_error "CavernPipeServer not running"
        exit 1
    fi
    
    log_info "Pipeline is ready"
}

# Detect URL/stream from clipboard or argument
detect_source() {
    local input="$1"
    
    # Check if it's a URL
    if [[ "$input" =~ ^(http|https|rtp|rtsp|udp):// ]]; then
        echo "url:$input"
    # Check if it's a file
    elif [[ -f "$input" ]]; then
        echo "file:$(cd "$(dirname "$input")" && pwd)/$(basename "$input")"
    else
        echo "unknown"
    fi
}

# Stream from URL (HTTP, RTP, RTSP, etc.)
stream_from_url() {
    local url="$1"
    
    log_info "Streaming from URL: $url"
    log_info "Output: ${OUTPUT_CHANNELS}ch @ ${SAMPLE_RATE}Hz"
    
    # Use ffmpeg to stream from URL
    ffmpeg -hide_banner -loglevel error \
        -re \
        -i "$url" \
        -acodec pcm_s${BIT_DEPTH}le \
        -ar $SAMPLE_RATE \
        -ac $OUTPUT_CHANNELS \
        -f s${BIT_DEPTH}le \
        -threads 4 \
        - \
    | "$PROJECT_ROOT/bin/streaming-adapter" "$OUTPUT_CHANNELS" "$SAMPLE_RATE" "$BIT_DEPTH" \
    | "$PROJECT_ROOT/bin/PipeToFifo" "$FIFO"
}

# Stream from file
stream_from_file() {
    local file="$1"
    
    log_info "Streaming from file: $file"
    
    # Use the main play.sh script
    "$PROJECT_ROOT/scripts/play.sh" "$file"
}

# Show VLC-specific instructions
vlc_instructions() {
    cat << 'EOF'

=== VLC Setup for Streaming ===

Method 1: System Audio Capture (Recommended)
--------------------------------------------
1. Install BlackHole (macOS) or setup PulseAudio (Linux)
   See: ./scripts/streaming/capture-system-audio.sh --setup

2. Set BlackHole as VLC's audio output:
   VLC > Preferences > Audio > Output module: CoreAudio
   Select "BlackHole 16ch" as the device

3. Run the system capture script:
   ./scripts/streaming/capture-system-audio.sh /tmp/snapcast-out

4. Play anything in VLC - audio goes to CavernPipe!

Method 2: VLC HTTP Stream
-------------------------
1. In VLC: View > Playlist
2. Right-click your media > Stream
3. Select "HTTP" as the protocol
4. Set port (e.g., 8080)
5. Play the stream

6. Capture with:
   ./scripts/streaming/stream-from-app.sh http://localhost:8080

EOF
}

# Show Stremio-specific instructions
stremio_instructions() {
    cat << 'EOF'

=== Stremio Setup for Streaming ===

Stremio uses the system audio output, so you need system audio capture:

1. Install BlackHole (macOS) or setup PulseAudio (Linux)
   See: ./scripts/streaming/capture-system-audio.sh --setup

2. Create a Multi-Output Device in Audio MIDI Setup (macOS)
   - Include both your speakers and BlackHole
   - Set as system output

3. Run the capture script:
   ./scripts/streaming/capture-system-audio.sh /tmp/snapcast-out

4. Start CavernPipe pipeline:
   ./scripts/run.sh

5. Play anything in Stremio - audio is captured automatically!

For Linux users:
- Use pavucontrol to route Stremio audio to the virtual sink
- Or set the virtual sink as default: pactl set-default-sink cavern_capture

EOF
}

# Show browser-specific instructions
browser_instructions() {
    cat << 'EOF'

=== Browser Audio Capture ===

macOS with BlackHole:
--------------------
1. Install BlackHole: brew install blackhole-16ch

2. Create Multi-Output Device in Audio MIDI Setup:
   - Speakers + BlackHole 16ch
   - Set BlackHole as clock source

3. Set Multi-Output as system default

4. Run capture:
   ./scripts/streaming/capture-system-audio.sh /tmp/snapcast-out

5. Play anything in browser - Netflix, YouTube, Spotify Web, etc.

Linux with PulseAudio:
---------------------
1. Create virtual sink:
   pactl load-module module-null-sink sink_name=cavern_capture

2. Use pavucontrol to route browser to cavern_capture

3. Run capture:
   ./scripts/streaming/capture-system-audio.sh /tmp/snapcast-out

Tip: For browser tab audio, use Firefox with its per-tab audio routing
or Chrome with a similar extension.

EOF
}

# Show usage
usage() {
    cat << EOF
Stream Audio from Applications to CavernPipe

Usage: $(basename "$0") [OPTIONS] <source>
       $(basename "$0") --vlc
       $(basename "$0") --stremio
       $(basename "$0") --browser

Source Types:
    file.mp4           Media file (any format ffmpeg supports)
    http://...         HTTP stream URL
    rtp://...          RTP multicast stream
    udp://...          UDP stream

Options:
    -h, --help          Show this help
    --vlc               Show VLC setup instructions
    --stremio           Show Stremio setup instructions
    --browser           Show browser capture instructions
    -c, --channels N    Output channels (default: $OUTPUT_CHANNELS)
    -r, --rate HZ       Sample rate (default: $SAMPLE_RATE)
    -b, --bits N        Bit depth (default: $BIT_DEPTH)
    --system-capture    Use system audio capture mode

Examples:
    # Stream from HTTP URL
    $(basename "$0") http://example.com/stream.mp3

    # Stream from RTP multicast
    $(basename "$0") rtp://239.255.0.1:5004

    # Stream with custom channels
    $(basename "$0") -c 8 movie.mkv

    # System audio capture (from any app)
    $(basename "$0") --system-capture

Quick Start - System Audio Capture:
-----------------------------------
1. Setup virtual audio (run once):
   ./scripts/streaming/capture-system-audio.sh --setup

2. Start pipeline:
   ./scripts/run.sh

3. Capture system audio:
   ./scripts/streaming/capture-system-audio.sh /tmp/snapcast-out

4. Play anything in any app!

EOF
}

# Parse arguments
SOURCE=""
USE_SYSTEM_CAPTURE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        --vlc)
            vlc_instructions
            exit 0
            ;;
        --stremio)
            stremio_instructions
            exit 0
            ;;
        --browser)
            browser_instructions
            exit 0
            ;;
        --system-capture)
            USE_SYSTEM_CAPTURE=true
            shift
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
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            SOURCE="$1"
            shift
            ;;
    esac
done

# Handle system capture mode
if [[ "$USE_SYSTEM_CAPTURE" == true ]]; then
    exec "$SCRIPT_DIR/capture-system-audio.sh" "$FIFO"
fi

# Validate source
if [[ -z "$SOURCE" ]]; then
    log_error "No source specified"
    usage
    exit 1
fi

# Check pipeline
check_pipeline

# Detect and handle source type
SOURCE_TYPE=$(detect_source "$SOURCE")

case "$SOURCE_TYPE" in
    url:*)
        URL="${SOURCE_TYPE#url:}"
        stream_from_url "$URL"
        ;;
    file:*)
        FILE="${SOURCE_TYPE#file:}"
        stream_from_file "$FILE"
        ;;
    *)
        log_error "Unknown source type: $SOURCE"
        exit 1
        ;;
esac
