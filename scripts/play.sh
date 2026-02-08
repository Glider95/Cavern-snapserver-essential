#!/usr/bin/env bash
# Play media file through Cavern-Snapserver pipeline

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT_DIR/logs"

CLIENT_DLL="$ROOT_DIR/src/CavernPipeClient/bin/Release/net8.0/CavernPipeClient.dll"
PIPETOFIFO_DLL="$ROOT_DIR/src/PipeToFifo/bin/Release/net8.0/PipeToFifo.dll"
FIFO="/tmp/snapcast-out"

OUTPUT_CHANNELS=${OUTPUT_CHANNELS:-6}
SAMPLE_RATE=${SAMPLE_RATE:-48000}
BIT_DEPTH=${BIT_DEPTH:-16}

# Usage
if [ $# -lt 1 ]; then
  echo "Usage: $0 <media_file> [ffmpeg_options...]"
  echo ""
  echo "Examples:"
  echo "  $0 movie.mkv"
  echo "  $0 movie.mkv -ss 00:10:00    # Start at 10 minutes"
  echo ""
  echo "Environment:"
  echo "  OUTPUT_CHANNELS=$OUTPUT_CHANNELS"
  echo "  SAMPLE_RATE=$SAMPLE_RATE"
  echo "  BIT_DEPTH=$BIT_DEPTH"
  exit 1
fi

FILE="$1"
shift || true

# Validate
if [ ! -f "$FILE" ]; then
  echo "ERROR: File not found: $FILE"
  exit 1
fi

if [ ! -f "$CLIENT_DLL" ]; then
  echo "ERROR: CavernPipeClient not built. Run: ./scripts/build.sh"
  exit 1
fi

if [ ! -f "$PIPETOFIFO_DLL" ]; then
  echo "ERROR: PipeToFifo not built. Run: ./scripts/build.sh"
  exit 1
fi

if [ ! -p "$FIFO" ]; then
  echo "ERROR: Pipeline not running. Start with: ./scripts/run.sh"
  exit 1
fi

# Cleanup
cleanup() {
  echo ""
  echo "[play] Stopped"
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$LOG_DIR"

# Check if file is a DAMF file (for file-based mode)
FILE_EXT="${FILE##*.}"
if [ "$FILE_EXT" = "atmos" ]; then
  echo "[play] DAMF file detected - using file-based mode"
  
  # Build client if needed
  if [ ! -f "$CLIENT_DLL" ]; then
    echo "[play] Building CavernPipeClient..."
    cd "$ROOT_DIR/src/CavernPipeClient" && dotnet build --configuration Release
  fi
  if [ ! -f "$PIPETOFIFO_DLL" ]; then
    echo "[play] Building PipeToFifo..."
    cd "$ROOT_DIR/src/PipeToFifo" && dotnet build --configuration Release
  fi
  
  echo "[play] Output: ${OUTPUT_CHANNELS}ch @ ${SAMPLE_RATE}Hz, ${BIT_DEPTH}-bit"
  echo "[play] Starting playback..."
  
  # File-based mode: CavernPipeClient reads file directly, outputs PCM
  # Use stdbuf -o0 to disable output buffering - critical for pipe transfer
  stdbuf -o0 dotnet "$CLIENT_DLL" "$FILE" "$OUTPUT_CHANNELS" "$BIT_DEPTH" \
    2>"$LOG_DIR/client.log" \
  | dotnet "$PIPETOFIFO_DLL" "$FIFO" \
    2>"$LOG_DIR/fifo.log"
  
  echo ""
  echo "[play] Playback finished"
  exit 0
fi

# Detect audio stream for non-DAMF files
echo "[play] Analyzing: $FILE"
AUDIO_INFO=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,channels,sample_rate -of csv=p=0 "$FILE" 2>/dev/null || echo "")

if [ -z "$AUDIO_INFO" ]; then
  echo "WARNING: No audio stream detected, trying anyway..."
  AUDIO_STREAM="0:a:0"
  CODEC="unknown"
else
  CODEC=$(echo "$AUDIO_INFO" | cut -d',' -f1)
  echo "[play] Audio codec: $CODEC"
  AUDIO_STREAM="0:a:0"
fi

# For TrueHD, use the cached DAMF file if available
if [ "$CODEC" = "truehd" ]; then
  CACHE_DIR="$HOME/.cavern-wireless/cache"
  # Calculate MD5 hash of the file
  if command -v md5 >/dev/null 2>&1; then
    FILE_HASH=$(md5 -q "$FILE")
  else
    FILE_HASH=$(md5sum "$FILE" | cut -d' ' -f1)
  fi
  CACHED_DAMF="$CACHE_DIR/${FILE_HASH}.atmos"
  
  if [ -f "$CACHED_DAMF" ]; then
    echo "[play] Found cached DAMF: $CACHED_DAMF"
    echo "[play] Using file-based mode for TrueHD"
    
    # Use file-based mode with the cached DAMF
    stdbuf -o0 dotnet "$CLIENT_DLL" "$CACHED_DAMF" "$OUTPUT_CHANNELS" "$BIT_DEPTH" \
      2>"$LOG_DIR/client.log" \
    | dotnet "$PIPETOFIFO_DLL" "$FIFO" \
      2>"$LOG_DIR/fifo.log"
    
    echo ""
    echo "[play] Playback finished"
    exit 0
  else
    echo "[play] WARNING: TrueHD file not in cache. Run cavern-wireless.sh first to convert."
    echo "[play] Attempting streaming mode (may not work)..."
  fi
fi

# Pipeline
echo "[play] Starting playback..."
echo "[play] Output: ${OUTPUT_CHANNELS}ch @ ${SAMPLE_RATE}Hz, ${BIT_DEPTH}-bit"
echo ""

# Build client if needed
if [ ! -f "$CLIENT_DLL" ]; then
  echo "[play] Building CavernPipeClient..."
  cd "$ROOT_DIR/src/CavernPipeClient" && dotnet build --configuration Release
fi
if [ ! -f "$PIPETOFIFO_DLL" ]; then
  echo "[play] Building PipeToFifo..."
  cd "$ROOT_DIR/src/PipeToFifo" && dotnet build --configuration Release
fi

# CavernPipeServer uses AudioReader.Open() which expects containerized files
# Always use Matroska audio (.mka) as it supports all Dolby/DTS codecs
TEMP_AUDIO="/tmp/cavern-temp-audio.$$.mka"

cleanup_temp() {
  rm -f "$TEMP_AUDIO"
}
trap cleanup_temp EXIT

echo "[play] Extracting audio to Matroska container..."
ffmpeg \
  -i "$FILE" \
  -map "$AUDIO_STREAM" \
  -c:a copy \
  "$TEMP_AUDIO" \
  2>"$LOG_DIR/ffmpeg.log"

if [ ! -f "$TEMP_AUDIO" ]; then
  echo "ERROR: Failed to extract audio track"
  exit 1
fi

echo "[play] Streaming through pipeline..."
cat "$TEMP_AUDIO" \
| dotnet "$CLIENT_DLL" "$OUTPUT_CHANNELS" "$SAMPLE_RATE" "$BIT_DEPTH" \
  2>"$LOG_DIR/client.log" \
| dotnet "$PIPETOFIFO_DLL" "$FIFO" \
  2>"$LOG_DIR/fifo.log"

echo ""
echo "[play] Playback finished"
