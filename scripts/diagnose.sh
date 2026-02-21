#!/usr/bin/env bash
#
# Audio Pipeline Diagnostic Tool
# Helps troubleshoot no-sound issues
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

FIFO="/tmp/snapcast-out"
CONFIG="$PROJECT_ROOT/config/snapserver.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_section() { echo -e "\n${BLUE}▶ $1${NC}"; }

# Check if process is running
check_process() {
    local name="$1"
    local pattern="$2"
    
    if pgrep -f "$pattern" > /dev/null; then
        local pid=$(pgrep -f "$pattern" | head -1)
        log_info "$name is running (PID: $pid)"
        return 0
    else
        log_error "$name is NOT running"
        return 1
    fi
}

# Check port
check_port() {
    local port="$1"
    local name="$2"
    
    if lsof -i :$port > /dev/null 2>&1; then
        log_info "$name is listening on port $port"
        return 0
    else
        log_error "$name is NOT listening on port $port"
        return 1
    fi
}

log_section "Pipeline Process Check"

check_process "CavernPipeServer" "CavernPipeServer"
cavern_running=$?

check_process "Snapserver" "snapserver"
snap_running=$?

log_section "Network Ports"

check_port 1704 "Snapcast Stream"
check_port 1705 "Snapcast Control"
check_port 1780 "Snapcast HTTP"

log_section "FIFO Check"

if [[ -p "$FIFO" ]]; then
    log_info "FIFO exists: $FIFO"
    
    # Check if anything is writing to FIFO
    if lsof "$FIFO" 2>/dev/null | grep -q "write"; then
        log_info "Something is writing to FIFO"
    else
        log_warn "Nothing is currently writing to FIFO"
    fi
    
    # Check if snapserver is reading from FIFO
    if lsof "$FIFO" 2>/dev/null | grep -q "snapserver"; then
        log_info "Snapserver is reading from FIFO"
    else
        log_error "Snapserver is NOT reading from FIFO!"
        echo "    This usually means the source in snapserver.conf doesn't match"
    fi
else
    log_error "FIFO does not exist: $FIFO"
    echo "    Run: mkfifo $FIFO"
fi

log_section "Snapserver Configuration"

if [[ -f "$CONFIG" ]]; then
    log_info "Config file exists: $CONFIG"
    echo ""
    echo "Current source line:"
    grep "^source = " "$CONFIG" | head -1 || echo "    (not found)"
    echo ""
    echo "Expected format: pipe:///tmp/snapcast-out?name=Cavern&sampleformat=48000:16:6"
else
    log_error "Config file not found: $CONFIG"
fi

log_section "Audio Format Check"

# Check environment variables
echo "Environment variables:"
echo "  OUTPUT_CHANNELS=${OUTPUT_CHANNELS:-6} (default: 6)"
echo "  SAMPLE_RATE=${SAMPLE_RATE:-48000} (default: 48000)"
echo "  BIT_DEPTH=${BIT_DEPTH:-16} (default: 16)"
echo ""

# Compare with snapserver config
if [[ -f "$CONFIG" ]]; then
    source_line=$(grep "^source = " "$CONFIG" | head -1 || echo "")
    if [[ "$source_line" =~ sampleformat=([0-9]+):([0-9]+):([0-9]+) ]]; then
        config_rate="${BASH_REMATCH[1]}"
        config_bits="${BASH_REMATCH[2]}"
        config_ch="${BASH_REMATCH[3]}"
        
        env_rate="${SAMPLE_RATE:-48000}"
        env_bits="${BIT_DEPTH:-16}"
        env_ch="${OUTPUT_CHANNELS:-6}"
        
        if [[ "$config_rate" != "$env_rate" || "$config_bits" != "$env_bits" || "$config_ch" != "$env_ch" ]]; then
            log_warn "FORMAT MISMATCH!"
            echo "  Snapserver expects: ${config_rate}Hz, ${config_bits}-bit, ${config_ch}ch"
            echo "  Environment sets:   ${env_rate}Hz, ${env_bits}-bit, ${env_ch}ch"
            echo ""
            echo "  Fix: Update snapserver.conf or set matching environment variables"
        else
            log_info "Audio format matches between config and environment"
        fi
    fi
fi

log_section "Log File Check"

LOG_DIR="$PROJECT_ROOT/logs"

for log in cavernpipe.log snapserver.log client.log; do
    if [[ -f "$LOG_DIR/$log" ]]; then
        lines=$(wc -l < "$LOG_DIR/$log")
        log_info "$log exists ($lines lines)"
        
        # Check for errors
        if grep -i "error\|exception\|fail" "$LOG_DIR/$log" > /dev/null 2>&1; then
            log_warn "Errors found in $log:"
            grep -i "error\|exception\|fail" "$LOG_DIR/$log" | tail -3 | sed 's/^/    /'
        fi
    else
        log_warn "$log not found"
    fi
done

log_section "Snapclient Check"

# Check for connected snapclients
if command -v snapclient &>/dev/null || pgrep -f "snapclient" > /dev/null; then
    if pgrep -f "snapclient" > /dev/null; then
        client_count=$(pgrep -f "snapclient" | wc -l)
        log_info "Found $client_count snapclient process(es)"
    else
        log_warn "No snapclient processes found locally"
        echo "    If running on other devices, check their connection to port 1704"
    fi
else
    log_warn "snapclient not installed or not running"
fi

# Check snapserver for connected clients
if snap_running -eq 0 2>/dev/null; then
    echo ""
    echo "Checking snapserver status..."
    if curl -s http://localhost:1780/jsonrpc > /dev/null 2>&1; then
        curl -s http://localhost:1780/jsonrpc 2>/dev/null | head -20 || true
    fi
fi

log_section "Quick Audio Test"

echo "Generating test tone..."
echo "This will play a 1kHz sine wave for 3 seconds"
echo ""

# Create test in background
(
    ffmpeg -f lavfi -i "sine=frequency=1000:duration=3" \
        -acodec pcm_s16le -ar 48000 -ac 6 \
        -f s16le "$FIFO" 2>/dev/null
) &

FFMPEG_PID=$!

# Wait for it to start
sleep 1

# Check if ffmpeg is still running
if kill -0 $FFMPEG_PID 2>/dev/null; then
    log_info "Test tone is playing (PID: $FFMPEG_PID)"
    echo "    You should hear a 1kHz tone on all snapclients"
    echo "    Waiting 3 seconds..."
    wait $FFMPEG_PID 2>/dev/null || true
    log_info "Test complete"
else
    log_error "Test tone failed to play"
    echo "    Check if the FIFO is blocked or snapserver is not reading"
fi

log_section "Diagnostic Summary"

echo "Common issues:"
echo ""
echo "1. FORMAT MISMATCH:"
echo "   - Ensure snapserver.conf sampleformat matches your OUTPUT_CHANNELS"
echo "   - Example: If OUTPUT_CHANNELS=8, config should have ...:48000:16:8"
echo ""
echo "2. FIFO NOT BEING READ:"
echo "   - Restart snapserver: pkill snapserver && sleep 1 && ./scripts/run.sh"
echo ""
echo "3. NO CLIENTS CONNECTED:"
echo "   - Run snapclient on target device: snapclient -h <server_ip>"
echo ""
echo "4. CAVERNPIPESERVER NOT RUNNING:"
echo "   - Start pipeline: ./scripts/run.sh"
echo ""
echo "To view live logs:"
echo "   tail -f $PROJECT_ROOT/logs/*.log"
