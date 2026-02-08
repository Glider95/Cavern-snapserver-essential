#!/usr/bin/env bash
# Cavern-Snapserver Pipeline Runner
# Starts CavernPipeServer and Snapserver in background

set -euo pipefail

# Configuration
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"
BIN_DIR="$ROOT_DIR/bin"
FIFO="/tmp/snapcast-out"

OUTPUT_CHANNELS=${OUTPUT_CHANNELS:-6}
SAMPLE_RATE=${SAMPLE_RATE:-48000}
BIT_DEPTH=${BIT_DEPTH:-16}

# Debug mode
[[ "${DEBUG:-0}" == "1" ]] && set -x

# Cleanup function
cleanup() {
  echo ""
  echo "[run] Stopping pipeline..."
  pkill -P $$ 2>/dev/null || true
  rm -f "$FIFO"
}
trap cleanup EXIT INT TERM

# Create directories
mkdir -p "$LOG_DIR"

# Kill existing instances
echo "[run] Cleaning up existing processes..."
pkill -f "CavernPipeServer" 2>/dev/null || true
pkill -f "snapserver" 2>/dev/null || true
sleep 1

# Create FIFO
echo "[run] Creating FIFO: $FIFO"
rm -f "$FIFO"
mkfifo "$FIFO"

# Start CavernPipeServer
echo "[run] Starting CavernPipeServer..."
"$BIN_DIR/CavernPipeServer" > "$LOG_DIR/cavernpipe.log" 2>&1 &
CAVERN_PID=$!

# Wait for socket
echo "[run] Waiting for CavernPipe socket..."
PIPE_PATH=""
for i in {1..60}; do
  PIPE_PATH=$(find /var/folders -name "CoreFxPipe_CavernPipe" 2>/dev/null | head -1 || echo "")
  if [ -n "$PIPE_PATH" ] && [ -S "$PIPE_PATH" ]; then
    echo "[run] CavernPipe ready: $PIPE_PATH"
    break
  fi
  if [ $i -eq 60 ]; then
    echo "[run] WARNING: Socket not found after 30 seconds"
  fi
  sleep 0.5
done

if ! ps -p $CAVERN_PID > /dev/null; then
  echo "[run] ERROR: CavernPipeServer failed to start"
  cat "$LOG_DIR/cavernpipe.log"
  exit 1
fi

# Start Snapserver
echo "[run] Starting Snapserver..."
snapserver -c "$ROOT_DIR/config/snapserver.conf" > "$LOG_DIR/snapserver.log" 2>&1 &
SNAP_PID=$!

# Wait for Snapserver
echo "[run] Waiting for Snapserver..."
for i in {1..10}; do
  if lsof -i :1704 > /dev/null 2>&1; then
    echo "[run] Snapserver ready on port 1704"
    break
  fi
  sleep 0.5
done

if ! ps -p $SNAP_PID > /dev/null; then
  echo "[run] ERROR: Snapserver failed to start"
  cat "$LOG_DIR/snapserver.log"
  exit 1
fi

# Summary
echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║           Cavern-Snapserver Pipeline RUNNING             ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║ CavernPipeServer  : PID $CAVERN_PID"
echo "║ Snapserver        : PID $SNAP_PID (port 1704)"
echo "║ FIFO              : $FIFO"
echo "║ Logs              : $LOG_DIR/"
echo "║                                                           ║"
echo "║ Configuration:                                            ║"
echo "║   Channels      : $OUTPUT_CHANNELS"
echo "║   Sample Rate   : $SAMPLE_RATE Hz"
echo "║   Bit Depth     : $BIT_DEPTH-bit"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║ Next Steps:                                               ║"
echo "║   1. Play file    : ./scripts/play.sh <file.mkv>        ║"
echo "║   2. Connect client: snapclient -h 127.0.0.1             ║"
echo "║   3. View logs    : tail -f logs/*.log                   ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# Keep running
echo "[run] Press Ctrl+C to stop..."
wait
