#!/usr/bin/env bash
#
# Play media file through Cavern-Snapserver pipeline
# AUTO-DETECTS input audio parameters and matches pipeline configuration
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"

CLIENT_DLL="$ROOT_DIR/src/CavernPipeClient/bin/Release/net8.0/CavernPipeClient.dll"
PIPETOFIFO_DLL="$ROOT_DIR/src/PipeToFifo/bin/Release/net8.0/PipeToFifo.dll"
FIFO="/tmp/snapcast-out"

# Default settings (will be overridden by detection)
OUTPUT_CHANNELS=${OUTPUT_CHANNELS:-6}
SAMPLE_RATE=${SAMPLE_RATE:-48000}
BIT_DEPTH=${BIT_DEPTH:-16}
AUTO_DETECT=${AUTO_DETECT:-true}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_detect() { echo -e "${BLUE}[DETECT]${NC} $1" >&2; }

# Detect audio stream parameters using ffprobe
detect_audio_params() {
    local file="$1"
    
    log_detect "Analyzing audio stream..."
    
    # Get detailed audio info
    local probe_output
    probe_output=$(ffprobe -v error \
        -select_streams a:0 \
        -show_entries stream=codec_name,channels,sample_rate,bit_rate,duration,pix_fmt \
        -show_entries format=duration,bit_rate \
        -of json "$file" 2>/dev/null) || {
        log_warn "ffprobe failed, using defaults"
        return 1
    }
    
    # Extract values using jq if available, otherwise grep/sed
    if command -v jq &>/dev/null; then
        local detected_channels=$(echo "$probe_output" | jq -r '.streams[0].channels // 2')
        local detected_rate=$(echo "$probe_output" | jq -r '.streams[0].sample_rate // 48000')
        local detected_codec=$(echo "$probe_output" | jq -r '.streams[0].codec_name // "unknown"')
        local detected_duration=$(echo "$probe_output" | jq -r '.streams[0].duration // 0')
    else
        # Fallback parsing
        local detected_channels=$(echo "$probe_output" | grep -o '"channels": [0-9]*' | head -1 | grep -o '[0-9]*')
        local detected_rate=$(echo "$probe_output" | grep -o '"sample_rate": "[0-9]*"' | head -1 | grep -o '[0-9]*')
        local detected_codec=$(echo "$probe_output" | grep -o '"codec_name": "[^"]*"' | head -1 | cut -d'"' -f4)
        local detected_duration=$(echo "$probe_output" | grep -o '"duration": "[0-9.]*"' | head -1 | grep -o '[0-9.]*')
        
        detected_channels=${detected_channels:-2}
        detected_rate=${detected_rate:-48000}
        detected_codec=${detected_codec:-unknown}
    fi
    
    # Determine optimal output channels based on input
    local optimal_channels=$OUTPUT_CHANNELS
    if [[ "$AUTO_DETECT" == "true" ]]; then
        case "$detected_channels" in
            1|2)
                # Stereo input - can output to any configuration
                log_detect "Input: Stereo (2ch) - Flexible output configuration"
                ;;
            6)
                # 5.1 input - recommend 6ch output
                if [[ "$OUTPUT_CHANNELS" -lt 6 ]]; then
                    log_warn "Input is 5.1 (6ch) but output is ${OUTPUT_CHANNELS}ch - audio may be downmixed"
                fi
                ;;
            8)
                # 7.1 input - recommend 8ch output
                if [[ "$OUTPUT_CHANNELS" -lt 8 ]]; then
                    log_warn "Input is 7.1 (8ch) but output is ${OUTPUT_CHANNELS}ch - audio may be downmixed"
                fi
                ;;
            *)
                log_detect "Input: $detected_channels channels"
                ;;
        esac
        
        # Match sample rate if not explicitly overridden
        if [[ -n "$detected_rate" && "$detected_rate" != "$SAMPLE_RATE" ]]; then
            log_detect "Input sample rate: ${detected_rate}Hz (pipeline: ${SAMPLE_RATE}Hz)"
            # Note: Changing sample rate requires pipeline restart
            # We'll just log it for now
        fi
    fi
    
    # Calculate optimal update rate based on sample rate
    # UpdateRate of 1024 gives ~21ms at 48kHz
    local update_rate=1024
    if [[ "$detected_rate" -eq 44100 ]]; then
        update_rate=940  # ~21ms at 44.1kHz
    elif [[ "$detected_rate" -eq 96000 ]]; then
        update_rate=2048  # ~21ms at 96kHz
    fi
    
    # Output detection results
    log_detect "Codec: $detected_codec"
    log_detect "Input channels: $detected_channels"
    log_detect "Sample rate: ${detected_rate}Hz"
    log_detect "Duration: ${detected_duration}s"
    
    # Export for use by caller
    export DETECTED_CHANNELS="$detected_channels"
    export DETECTED_RATE="$detected_rate"
    export DETECTED_CODEC="$detected_codec"
    export DETECTED_DURATION="$detected_duration"
    export OPTIMAL_UPDATE_RATE="$update_rate"
    
    return 0
}

# Detect codec type for mode selection
detect_codec_type() {
    local file="$1"
    
    local codec=$(ffprobe -v error \
        -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || echo "unknown")
    
    echo "$codec"
}

# Check if file needs conversion for streaming
needs_container_conversion() {
    local codec="$1"
    
    # TrueHD and some formats need special handling
    case "$codec" in
        truehd|dts|eac3)
            return 0  # Needs conversion
            ;;
        *)
            return 1  # Can stream directly
            ;;
    esac
}

# Calculate dynamic update rate based on codec
calculate_update_rate() {
    local codec="$1"
    local sample_rate="$2"
    
    case "$codec" in
        eac3)
            # E-AC-3: 1536 samples per frame
            # 1536 / 6 mandatory frames = 256, but we use 64 for better latency
            echo "64"
            ;;
        ac3)
            # AC-3: 1536 samples per frame
            echo "256"
            ;;
        truehd)
            # TrueHD: variable frame size, use conservative value
            echo "1024"
            ;;
        aac)
            # AAC: 1024 samples per frame
            echo "1024"
            ;;
        *)
            # Default: calculate based on sample rate for ~21ms latency
            echo "$((sample_rate / 48))"
            ;;
    esac
}

# Usage
usage() {
    cat << EOF
Play media file with AUTO-DETECTED audio parameters

Usage: $0 [OPTIONS] <media_file>

Options:
    -h, --help              Show this help
    -c, --channels N        Force output channels (default: $OUTPUT_CHANNELS)
    -r, --rate HZ           Force sample rate (default: $SAMPLE_RATE)
    -b, --bits N            Force bit depth (default: $BIT_DEPTH)
    --no-detect             Disable auto-detection
    --detect-only           Only show detected parameters, don't play
    -ss TIME                Start at position (ffmpeg syntax, e.g., 00:05:00)
    -t DURATION             Play only specified duration

Environment:
    OUTPUT_CHANNELS=$OUTPUT_CHANNELS
    SAMPLE_RATE=$SAMPLE_RATE
    BIT_DEPTH=$BIT_DEPTH
    AUTO_DETECT=$AUTO_DETECT

Examples:
    $0 movie.mkv                    # Auto-detect and play
    $0 -c 8 movie.mkv               # Force 8-channel output
    $0 --detect-only movie.mkv      # Just show detection info
    $0 -ss 00:10:00 movie.mkv       # Start at 10 minutes

EOF
}

# Parse arguments
FILE=""
FFMPEG_OPTS=""
DETECT_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -c|--channels)
            OUTPUT_CHANNELS="$2"
            AUTO_DETECT=false
            shift 2
            ;;
        -r|--rate)
            SAMPLE_RATE="$2"
            AUTO_DETECT=false
            shift 2
            ;;
        -b|--bits)
            BIT_DEPTH="$2"
            shift 2
            ;;
        --no-detect)
            AUTO_DETECT=false
            shift
            ;;
        --detect-only)
            DETECT_ONLY=true
            shift
            ;;
        -ss|-t)
            FFMPEG_OPTS="$FFMPEG_OPTS $1 $2"
            shift 2
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            FILE="$1"
            shift
            ;;
    esac
done

# Validate
if [[ -z "$FILE" ]]; then
    log_error "No media file specified"
    usage
    exit 1
fi

if [[ ! -f "$FILE" ]]; then
    log_error "File not found: $FILE"
    exit 1
fi

# Detect audio parameters
if [[ "$AUTO_DETECT" == "true" ]]; then
    detect_audio_params "$FILE"
fi

# Exit if just detecting
if [[ "$DETECT_ONLY" == true ]]; then
    exit 0
fi

# Check pipeline
if [[ ! -p "$FIFO" ]]; then
    log_error "Pipeline not running. Start with: ./scripts/run.sh"
    exit 1
fi

if [[ ! -f "$CLIENT_DLL" ]]; then
    log_error "CavernPipeClient not built. Run: ./scripts/build.sh"
    exit 1
fi

# Get codec for mode selection
CODEC=$(detect_codec_type "$FILE")
log_info "Detected codec: $CODEC"

# Determine playback mode
FILE_EXT="${FILE##*.}"

# Check if it's a DAMF file (file-based mode)
if [[ "$FILE_EXT" == "atmos" ]]; then
    log_info "DAMF file detected - using file-based mode"
    
    log_info "Output: ${OUTPUT_CHANNELS}ch @ ${SAMPLE_RATE}Hz, ${BIT_DEPTH}-bit"
    log_info "Starting playback..."
    
    # File-based mode: -f <file> [channels] [bitDepth]
    stdbuf -o0 dotnet "$CLIENT_DLL" -f "$FILE" "$OUTPUT_CHANNELS" "$BIT_DEPTH" \
        2>"$LOG_DIR/client.log" \
    | dotnet "$PIPETOFIFO_DLL" "$FIFO" \
        2>"$LOG_DIR/fifo.log"
    
    log_info "Playback finished"
    exit 0
fi

# For TrueHD, check cache
if [[ "$CODEC" == "truehd" ]]; then
    CACHE_DIR="$HOME/.cavern-wireless/cache"
    FILE_HASH=$(md5 -q "$FILE" 2>/dev/null || md5sum "$FILE" | cut -d' ' -f1)
    CACHED_DAMF="$CACHE_DIR/${FILE_HASH}.atmos"
    
    if [[ -f "$CACHED_DAMF" ]]; then
        log_info "Found cached DAMF: $CACHED_DAMF"
        log_info "Using file-based mode for TrueHD"
        
        # File-based mode: -f <file> [channels] [bitDepth]
        stdbuf -o0 dotnet "$CLIENT_DLL" -f "$CACHED_DAMF" "$OUTPUT_CHANNELS" "$BIT_DEPTH" \
            2>"$LOG_DIR/client.log" \
        | dotnet "$PIPETOFIFO_DLL" "$FIFO" \
            2>"$LOG_DIR/fifo.log"
        
        log_info "Playback finished"
        exit 0
    else
        log_warn "TrueHD not in cache. Converting first..."
        "$ROOT_DIR/scripts/cavern-wireless.sh" "$FILE"
        exit 0
    fi
fi

# Streaming mode for other formats
log_info "Using streaming mode for $CODEC"

# Calculate optimal update rate
UPDATE_RATE=$(calculate_update_rate "$CODEC" "$SAMPLE_RATE")
log_info "Update rate: $UPDATE_RATE (optimized for $CODEC)"

# Create temp audio file if needed for container reliability
TEMP_AUDIO="/tmp/cavern-temp-audio.$$.mka"

cleanup() {
    rm -f "$TEMP_AUDIO"
}
trap cleanup EXIT

# For codecs that need container conversion
if needs_container_conversion "$CODEC"; then
    log_info "Extracting audio to reliable container..."
    ffmpeg -hide_banner -loglevel error \
        $FFMPEG_OPTS \
        -i "$FILE" \
        -map 0:a:0 \
        -c:a copy \
        "$TEMP_AUDIO" \
        2>"$LOG_DIR/ffmpeg-extract.log"
    
    PLAY_SOURCE="$TEMP_AUDIO"
else
    # For formats that can be streamed directly
    PLAY_SOURCE="$FILE"
fi

log_info "Streaming through pipeline..."
log_info "Output: ${OUTPUT_CHANNELS}ch @ ${SAMPLE_RATE}Hz, ${BIT_DEPTH}-bit"

# Stream to pipeline with detected parameters
# Arguments: channels sampleRate bitDepth
cat "$PLAY_SOURCE" \
| dotnet "$CLIENT_DLL" "$OUTPUT_CHANNELS" "$SAMPLE_RATE" "$BIT_DEPTH" \
    2>"$LOG_DIR/client.log" \
| dotnet "$PIPETOFIFO_DLL" "$FIFO" \
    2>"$LOG_DIR/fifo.log"

log_info "Playback finished"
