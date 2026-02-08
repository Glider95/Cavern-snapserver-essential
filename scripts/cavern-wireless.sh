#!/bin/bash
#
# Cavern Wireless - Main orchestration script
# Plays Dolby Atmos audio through Cavern spatial audio pipeline
#

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="$HOME/.cavern-wireless/cache"
CONFIG_DIR="$PROJECT_ROOT/config"
LOG_DIR="$PROJECT_ROOT/logs"

# Paths to components - using pre-built binaries
BIN_DIR="$PROJECT_ROOT/bin"
CLIENT_DLL="$BIN_DIR/CavernPipeClient.dll"
PIPETOFIFO_DLL="$BIN_DIR/PipeToFifo.dll"
FIFO="/tmp/snapcast-out"

# Default settings
SOURCE_FILE=""
USE_CACHE=true
DRY_RUN=false
LOCAL_PLAYBACK=false
OUTPUT_CHANNELS=${OUTPUT_CHANNELS:-6}
SAMPLE_RATE=${SAMPLE_RATE:-48000}
BIT_DEPTH=${BIT_DEPTH:-16}

# Create required directories
mkdir -p "$CACHE_DIR" "$LOG_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging (output to stderr so stdout can be used for function returns)
log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Show usage
usage() {
    cat << EOF
Cavern Wireless - Dolby Atmos Spatial Audio Pipeline

Usage: $(basename "$0") [OPTIONS] <audio_file>

Options:
    -h, --help          Show this help message
    -n, --no-cache      Skip cache, force re-conversion
    -d, --dry-run       Show what would be done without executing
    -l, --local         Local playback only (ffplay), no snapcast

Arguments:
    audio_file          Audio file to play (TrueHD, E-AC-3, WAV, etc.)

Examples:
    $(basename "$0") movie.mkv              # Play through snapcast
    $(basename "$0") -l movie.mkv           # Local playback only
    $(basename "$0") -n movie.mkv           # Force re-conversion

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -n|--no-cache)
            USE_CACHE=false
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -l|--local)
            LOCAL_PLAYBACK=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            SOURCE_FILE="$1"
            shift
            ;;
    esac
done

# Validate input
if [[ -z "$SOURCE_FILE" ]]; then
    log_error "No audio file specified"
    usage
    exit 1
fi

if [[ ! -f "$SOURCE_FILE" ]]; then
    log_error "File not found: $SOURCE_FILE"
    exit 1
fi

# Get absolute path
SOURCE_FILE="$(cd "$(dirname "$SOURCE_FILE")" && pwd)/$(basename "$SOURCE_FILE")"

# Calculate MD5 hash for caching
get_file_hash() {
    md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1
}

# Detect codec using ffprobe
detect_codec() {
    local file="$1"
    ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || echo "unknown"
}

# Extract TrueHD stream to temp file
extract_truehd() {
    local input="$1"
    local output="$2"
    log_info "Extracting TrueHD stream..."
    ffmpeg -hide_banner -loglevel error -i "$input" -map 0:a:0 -c copy -f truehd "$output"
}

# Convert TrueHD to DAMF using truehdd
convert_to_damf() {
    local input="$1"
    local output="$2"
    log_info "Converting TrueHD to DAMF format..."
    
    local truehdd_path="/tmp/truehdd/target/release/truehdd"
    if [[ ! -x "$truehdd_path" ]]; then
        log_error "truehdd not found at $truehdd_path"
        log_info "Building truehdd from source..."
        
        # Try to build truehdd
        if [[ -d "/tmp/truehdd" ]]; then
            cd /tmp/truehdd && cargo build --release 2>/dev/null
        else
            log_error "truehdd source not found. Please build it first:"
            log_error "  git clone https://github.com/alexdutton/truehdd.git /tmp/truehdd"
            log_error "  cd /tmp/truehdd && cargo build --release"
            exit 1
        fi
    fi
    
    # Get output directory and filename
    local output_dir=$(dirname "$output")
    local output_name=$(basename "$output" .atmos)
    
    # truehdd decode --output-path <PATH_PREFIX> <INPUT>
    # It creates <prefix>.atmos, <prefix>.atmos.audio, <prefix>.atmos.metadata
    # We use <dir>/<hash> as prefix so output is <dir>/<hash>.atmos
    local output_prefix="$output_dir/$output_name"
    "$truehdd_path" decode --output-path "$output_prefix" "$input"
    
    # truehdd creates files: <prefix>.atmos, <prefix>.atmos.audio, <prefix>.atmos.metadata
    # Rename .atmos files to remove the extra extension if needed
    if [[ -f "${output_prefix}.atmos.atmos" ]]; then
        mv "${output_prefix}.atmos.atmos" "$output"
        mv "${output_prefix}.atmos.atmos.audio" "${output_prefix}.atmos.audio"
        mv "${output_prefix}.atmos.atmos.metadata" "${output_prefix}.atmos.metadata"
    fi
}

# Prepare audio file (convert if needed)
prepare_audio() {
    local input="$1"
    local codec=$(detect_codec "$input")
    
    log_info "Detected codec: $codec"
    
    case "$codec" in
        truehd)
            log_info "TrueHD detected - will convert to DAMF"
            
            # Calculate cache key
            local cache_key=$(get_file_hash "$input")
            local cached_damf="$CACHE_DIR/${cache_key}.atmos"
            
            if [[ "$USE_CACHE" == true && -f "$cached_damf" ]]; then
                log_info "Using cached DAMF: $cached_damf"
                echo "$cached_damf"
                return 0
            fi
            
            # Check if already extracted TrueHD is cached
            local cached_truehd="$CACHE_DIR/${cache_key}.truehd"
            if [[ "$USE_CACHE" == true && -f "$cached_truehd" ]]; then
                log_info "Using cached TrueHD: $cached_truehd"
            else
                # Extract TrueHD
                local temp_truehd="$CACHE_DIR/tmp_${cache_key}.truehd"
                extract_truehd "$input" "$temp_truehd"
                mv "$temp_truehd" "$cached_truehd"
            fi
            
            # Convert to DAMF
            convert_to_damf "$cached_truehd" "$cached_damf"
            
            # Clean up TrueHD if conversion succeeded
            if [[ -f "$cached_damf" ]]; then
                rm -f "$cached_truehd"
                log_info "Conversion complete: $cached_damf"
                echo "$cached_damf"
            else
                log_error "Conversion failed"
                exit 1
            fi
            ;;
        
        eac3|aac|mp3|flac|pcm_s16le|pcm_s24le|pcm_f32le)
            # These formats can be streamed directly
            log_info "Using direct streaming for $codec"
            echo "$input"
            ;;
        
        atmos)
            # Already a DAMF file
            log_info "DAMF file detected"
            echo "$input"
            ;;
        
        *)
            log_warn "Unknown codec '$codec', attempting direct playback"
            echo "$input"
            ;;
    esac
}

# Start CavernPipeServer
start_server() {
    log_info "Starting CavernPipeServer..."
    
    local bin_dir="$PROJECT_ROOT/bin"
    
    if [[ ! -f "$bin_dir/CavernPipeServer.dll" ]]; then
        log_error "CavernPipeServer.dll not found in $bin_dir"
        log_error "Please download binaries from: https://github.com/Glider95/Cavern-snapserver-essential/releases"
        exit 1
    fi
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would start: dotnet $bin_dir/CavernPipeServer.dll"
        return 0
    fi
    
    cd "$bin_dir"
    dotnet CavernPipeServer.dll > "$LOG_DIR/server.log" 2>&1 &
    local server_pid=$!
    
    # Wait for server to start
    sleep 2
    
    # Check if server is running
    if ! kill -0 $server_pid 2>/dev/null; then
        log_error "CavernPipeServer failed to start"
        cat "$LOG_DIR/server.log"
        exit 1
    fi
    
    log_info "CavernPipeServer started (PID: $server_pid)"
    echo $server_pid
}

# Start Snapserver
start_snapserver() {
    log_info "Starting Snapserver..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would start: snapserver -c $CONFIG_DIR/snapserver.conf"
        return 0
    fi
    
    # Create FIFO if it doesn't exist
    if [[ ! -p "$FIFO" ]]; then
        rm -f "$FIFO"
        mkfifo "$FIFO"
    fi
    
    snapserver -c "$CONFIG_DIR/snapserver.conf" > "$LOG_DIR/snapserver.log" 2>&1 &
    local snap_pid=$!
    
    # Wait for snapserver to start
    sleep 2
    
    # Check if snapserver is running
    if ! kill -0 $snap_pid 2>/dev/null; then
        log_error "Snapserver failed to start"
        cat "$LOG_DIR/snapserver.log"
        exit 1
    fi
    
    log_info "Snapserver started (PID: $snap_pid)"
    echo $snap_pid
}

# Play audio file
play_audio() {
    local audio_file="$1"
    local ext="${audio_file##*.}"
    
    log_info "Playing: $audio_file"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would play: $audio_file"
        return 0
    fi
    
    # Check binaries exist
    if [[ ! -f "$CLIENT_DLL" ]]; then
        log_error "CavernPipeClient.dll not found in $BIN_DIR"
        log_error "Please download binaries from: https://github.com/Glider95/Cavern-snapserver-essential/releases"
        exit 1
    fi
    
    # Check if it's a DAMF file (file-based mode)
    if [[ "$ext" == "atmos" ]]; then
        log_info "Using file-based mode for DAMF"
        
        if [[ "$LOCAL_PLAYBACK" == true ]]; then
            # Local playback with ffplay
            log_info "Local playback mode"
            dotnet "$CLIENT_DLL" "$audio_file" "$OUTPUT_CHANNELS" "$BIT_DEPTH" 2>&1 | \
                ffmpeg -hide_banner -loglevel error -f s16le -ar 48000 -ac "$OUTPUT_CHANNELS" -i - -f wav - | \
                ffplay -nodisp -autoexit -loglevel error - 2>/dev/null || true
        else
            # Snapcast pipeline
            log_info "Snapcast pipeline mode"
            if [[ ! -p "$FIFO" ]]; then
                log_error "FIFO not found: $FIFO"
                log_error "Snapserver may not be running"
                exit 1
            fi
            
            log_info "Output: ${OUTPUT_CHANNELS}ch @ ${SAMPLE_RATE}Hz, ${BIT_DEPTH}-bit"
            log_info "Waiting for snapclient connections on port 1704..."
            
            # File-based mode: CavernPipeClient reads file directly, outputs PCM
            # Use stdbuf -o0 to disable output buffering - critical for pipe transfer
            stdbuf -o0 dotnet "$CLIENT_DLL" "$audio_file" "$OUTPUT_CHANNELS" "$BIT_DEPTH" | \
                dotnet "$PIPETOFIFO_DLL" "$FIFO"
        fi
    else
        # Streaming mode - extract audio first
        log_info "Using streaming mode"
        
        # Extract audio to temp file for reliable container parsing
        local temp_audio="/tmp/cavern-temp-audio.$$.mka"
        ffmpeg -hide_banner -loglevel error -i "$audio_file" -map 0:a:0 -c:a copy "$temp_audio"
        
        if [[ "$LOCAL_PLAYBACK" == true ]]; then
            cat "$temp_audio" | \
                dotnet "$CLIENT_DLL" "$OUTPUT_CHANNELS" "$SAMPLE_RATE" "$BIT_DEPTH" 2>&1 | \
                ffmpeg -hide_banner -loglevel error -f s16le -ar "$SAMPLE_RATE" -ac "$OUTPUT_CHANNELS" -i - -f wav - | \
                ffplay -nodisp -autoexit -loglevel error - 2>/dev/null || true
        else
            if [[ ! -p "$FIFO" ]]; then
                log_error "FIFO not found: $FIFO"
                exit 1
            fi
            
            cat "$temp_audio" | \
                dotnet "$CLIENT_DLL" "$OUTPUT_CHANNELS" "$SAMPLE_RATE" "$BIT_DEPTH" 2>&1 | \
                dotnet "$PIPETOFIFO_DLL" "$FIFO" 2>&1
        fi
        
        rm -f "$temp_audio"
    fi
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."
    pkill -f "CavernPipeServer" 2>/dev/null || true
    pkill -f "snapserver" 2>/dev/null || true
    pkill -f "CavernPipeClient" 2>/dev/null || true
    pkill -f "PipeToFifo" 2>/dev/null || true
    rm -f /tmp/CoreFxPipe_CavernPipe 2>/dev/null || true
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Main execution
main() {
    log_info "Cavern Wireless - Starting pipeline"
    log_info "Source: $SOURCE_FILE"
    
    # Prepare audio (convert if needed)
    local audio_to_play=$(prepare_audio "$SOURCE_FILE")
    
    # Start servers
    local server_pid=$(start_server)
    local snap_pid=""
    
    # Start snapserver only for non-local playback
    if [[ "$LOCAL_PLAYBACK" == false ]]; then
        snap_pid=$(start_snapserver)
    fi
    
    # Wait for servers to be ready
    sleep 2
    
    # Play audio
    play_audio "$audio_to_play"
    
    log_info "Playback complete"
}

# Run main
main
