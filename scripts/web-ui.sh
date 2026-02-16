#!/usr/bin/env bash
#
# CavernPipe Web UI Launcher
# Starts the web control panel
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
WEB_UI_DIR="$PROJECT_ROOT/web-ui"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_title() { echo -e "${BLUE}$1${NC}"; }

VENV_DIR="$PROJECT_ROOT/.venv"
VENV_PYTHON="$VENV_DIR/bin/python"

# Check Python and dependencies
check_dependencies() {
    if ! command -v python3 &>/dev/null; then
        log_error "Python 3 is required but not installed"
        exit 1
    fi
    
    # Check for virtual environment
    if [[ ! -f "$VENV_PYTHON" ]]; then
        log_warn "Virtual environment not found at $VENV_DIR"
        log_info "Creating virtual environment..."
        python3 -m venv "$VENV_DIR"
        log_info "Installing dependencies..."
        "$VENV_DIR/bin/pip" install -q -r "$WEB_UI_DIR/requirements.txt"
    fi
    
    # Check for required packages in venv
    if ! "$VENV_PYTHON" -c "import flask" 2>/dev/null; then
        log_warn "Installing dependencies in virtual environment..."
        "$VENV_DIR/bin/pip" install -q -r "$WEB_UI_DIR/requirements.txt"
    fi
}

# Show usage
usage() {
    cat << EOF
CavernPipe Web UI Launcher

Usage: $(basename "$0") [OPTIONS]

Options:
    -h, --help          Show this help
    -p, --port PORT     Server port (default: 8080)
    --no-browser        Don't open browser automatically
    --stop              Stop running web UI server

The Web UI provides:
  - Pipeline status monitoring
  - Audio level meters (VU)
  - Speaker layout visualization
  - Playback controls
  - System logs viewer

EOF
}

# Parse arguments
PORT=8080
OPEN_BROWSER=true

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        --no-browser)
            OPEN_BROWSER=false
            shift
            ;;
        --stop)
            log_info "Stopping Web UI server..."
            pkill -f "CavernPipe Web UI" 2>/dev/null || true
            pkill -f "web-ui/server.py" 2>/dev/null || true
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main
check_dependencies

# Check if already running
if lsof -i :$PORT &>/dev/null; then
    log_warn "Port $PORT is already in use"
    log_info "Opening existing instance..."
    OPEN_BROWSER=true
else
    # Start server
    log_info "Starting Web UI server on port $PORT..."
    
    cd "$WEB_UI_DIR"
    "$VENV_PYTHON" server.py &
    SERVER_PID=$!
    
    # Wait for server to start
    for i in {1..10}; do
        if curl -s http://localhost:$PORT/api/status &>/dev/null; then
            break
        fi
        sleep 0.5
    done
    
    log_info "Server started (PID: $SERVER_PID)"
fi

# Open browser
if [[ "$OPEN_BROWSER" == true ]]; then
    log_info "Opening browser..."
    sleep 1
    
    if command -v open &>/dev/null; then
        open "http://localhost:$PORT"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "http://localhost:$PORT"
    else
        log_info "Please open: http://localhost:$PORT"
    fi
fi

log_title ""
log_title "╔═══════════════════════════════════════════════════════╗"
log_title "║           CavernPipe Web UI Running                  ║"
log_title "╠═══════════════════════════════════════════════════════╣"
log_title "║  URL: http://localhost:$PORT"
log_title "║  API: http://localhost:$PORT/api"
log_title "╚═══════════════════════════════════════════════════════╝"
log_title ""
log_info "Press Ctrl+C to stop"

# Keep script running
wait
