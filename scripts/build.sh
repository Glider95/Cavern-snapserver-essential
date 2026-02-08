#!/usr/bin/env bash
# Build CavernPipe Snapcast Bridge

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

mkdir -p "$PROJECT_ROOT/bin"

cd "$PROJECT_ROOT"

# Check for Cavern NuGet packages
log_info "Checking Cavern dependencies..."
if ! dotnet list package 2>/dev/null | grep -q "Cavern"; then
    log_warn "Cavern packages not found. Installing..."
    
    # Add Cavern package references to the client
    cd src/CavernPipeClient
    dotnet add package Cavern --version 2.1.0 2>/dev/null || true
    dotnet add package Cavern.Format --version 2.1.0 2>/dev/null || true
    cd ../..
fi

# Build CavernPipeClient
log_info "Building CavernPipeClient..."
cd src/CavernPipeClient
dotnet build -c Release
cd ../..
cp src/CavernPipeClient/bin/Release/net8.0/*.dll bin/ 2>/dev/null || true
cp src/CavernPipeClient/bin/Release/net8.0/CavernPipeClient bin/ 2>/dev/null || true

# Build PipeToFifo
log_info "Building PipeToFifo..."
cd src/PipeToFifo
dotnet build -c Release
cd ../..
cp src/PipeToFifo/bin/Release/net8.0/*.dll bin/ 2>/dev/null || true
cp src/PipeToFifo/bin/Release/net8.0/PipeToFifo bin/ 2>/dev/null || true

# Check for CavernPipeServer
if [ ! -f "$PROJECT_ROOT/bin/CavernPipeServer.dll" ]; then
    log_warn "CavernPipeServer not found in bin/"
    log_info "You need to build CavernPipeServer with the patches applied:"
    echo ""
    echo "1. Clone upstream Cavern:"
    echo "   git clone https://github.com/VoidXH/Cavern.git /tmp/cavern-upstream"
    echo ""
    echo "2. Apply patches:"
    echo "   cp patches/CavernPipeServer.Logic/*.cs /tmp/cavern-upstream/CavernSamples/Reusable/CavernPipeServer.Logic/"
    echo ""
    echo "3. Build:"
    echo "   cd /tmp/cavern-upstream"
    echo "   dotnet build CavernSamples/CavernPipeServer.Multiplatform/CavernPipeServer.Multiplatform.csproj -c Release"
    echo ""
    echo "4. Copy to bin/:"
    echo "   cp /tmp/cavern-upstream/CavernSamples/CavernPipeServer.Multiplatform/bin/Release/net8.0/* bin/"
fi

log_info "Build complete. Binaries in bin/"
