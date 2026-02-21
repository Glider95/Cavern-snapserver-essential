#!/usr/bin/env bash
#
# Speaker Layout Configuration Tool
# Manage and select speaker layouts for CavernPipe
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_ROOT/config/speaker-layouts.json"
USER_CONFIG="$HOME/.cavern-wireless/speaker-config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_title() { echo -e "${CYAN}$1${NC}"; }

# Ensure user config directory exists
mkdir -p "$(dirname "$USER_CONFIG")"

# Get current layout from environment or config
get_current_layout() {
    if [[ -n "${SPEAKER_LAYOUT:-}" ]]; then
        echo "$SPEAKER_LAYOUT"
    elif [[ -f "$USER_CONFIG" ]]; then
        jq -r '.current_layout // "surround_51"' "$USER_CONFIG" 2>/dev/null || echo "surround_51"
    else
        echo "surround_51"
    fi
}

# Save current layout
save_layout() {
    local layout="$1"
    local channels="$2"
    
    cat > "$USER_CONFIG" << EOF
{
  "current_layout": "$layout",
  "output_channels": $channels,
  "last_updated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    log_info "Saved layout: $layout ($channels channels)"
}

# List available layouts
list_layouts() {
    log_title "Available Speaker Layouts"
    echo ""
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Layout configuration not found: $CONFIG_FILE"
        return 1
    fi
    
    local current=$(get_current_layout)
    
    # Parse and display layouts
    if command -v jq &>/dev/null; then
        echo "$layouts" | jq -r '
            to_entries | .[] |
            "  \(.key):\n    Name: \(.value.name)\n    Channels: \(.value.channels)\n    Description: \(.value.description)\n"
        '
        
        echo "Layouts:"
        jq -r '.layouts | to_entries | .[] | "  \(.key): \(.value.name) [\(.value.channels)ch]"' "$CONFIG_FILE" | \
        while read -r line; do
            layout_key=$(echo "$line" | cut -d: -f1 | tr -d ' ')
            if [[ "$layout_key" == "$current" ]]; then
                echo -e "${GREEN}●${NC} $line ${GREEN}(current)${NC}"
            else
                echo -e "  $line"
            fi
        done
    else
        log_warn "jq not installed - showing raw configuration"
        cat "$CONFIG_FILE"
    fi
    
    echo ""
    log_info "Current layout: $current"
}

# Show layout details
show_layout_details() {
    local layout_key="$1"
    
    if ! command -v jq &>/dev/null; then
        log_error "jq is required for detailed view"
        return 1
    fi
    
    local layout=$(jq -r ".layouts[\"$layout_key\"]" "$CONFIG_FILE")
    
    if [[ "$layout" == "null" ]]; then
        log_error "Layout not found: $layout_key"
        return 1
    fi
    
    log_title "Layout: $layout_key"
    echo ""
    echo "  Name: $(echo "$layout" | jq -r '.name')"
    echo "  Channels: $(echo "$layout" | jq -r '.channels')"
    echo "  Description: $(echo "$layout" | jq -r '.description')"
    echo ""
    log_title "Speaker Positions:"
    echo "$layout" | jq -r '.speaker_positions | to_entries | .[] | "  \(.value.name): x=\(.value.x), y=\(.value.y), z=\(.value.z)"'
}

# Set active layout
set_layout() {
    local layout_key="$1"
    
    if ! command -v jq &>/dev/null; then
        log_error "jq is required to set layout"
        return 1
    fi
    
    # Validate layout exists
    local channels=$(jq -r ".layouts[\"$layout_key\"].channels // empty" "$CONFIG_FILE")
    if [[ -z "$channels" ]]; then
        log_error "Layout not found: $layout_key"
        log_info "Run '$0 list' to see available layouts"
        return 1
    fi
    
    # Save configuration
    save_layout "$layout_key" "$channels"
    
    # Show environment variable setup
    echo ""
    log_title "To use this layout, set the environment variable:"
    echo ""
    echo "  export SPEAKER_LAYOUT=$layout_key"
    echo "  export OUTPUT_CHANNELS=$channels"
    echo ""
    echo "Or run with the layout:"
    echo "  SPEAKER_LAYOUT=$layout_key OUTPUT_CHANNELS=$channels ./scripts/run.sh"
    echo ""
}

# Visualize layout in ASCII
visualize_layout() {
    local layout_key="${1:-$(get_current_layout)}"
    
    if ! command -v jq &>/dev/null; then
        log_error "jq is required for visualization"
        return 1
    fi
    
    local layout=$(jq -r ".layouts[\"$layout_key\"]" "$CONFIG_FILE")
    
    if [[ "$layout" == "null" ]]; then
        log_error "Layout not found: $layout_key"
        return 1
    fi
    
    local channels=$(echo "$layout" | jq -r '.channels')
    local name=$(echo "$layout" | jq -r '.name')
    
    log_title "Visualization: $name ($channels channels)"
    echo ""
    
    # Create a simple ASCII visualization
    # Top view (x-z plane)
    echo "  Top View (looking down):"
    echo "         Front (TV/Screen)"
    echo "              │"
    echo "     ┌────────┴────────┐"
    
    # Parse speaker positions and map to grid
    declare -A grid
    
    while IFS= read -r speaker; do
        local sx=$(echo "$speaker" | jq -r '.x')
        local sz=$(echo "$speaker" | jq -r '.z')
        local sname=$(echo "$speaker" | jq -r '.name')
        
        # Map coordinates to grid (scale and offset)
        # x: -1 to 1 -> 1 to 17
        # z: -1 to 1 -> 5 to 1
        local gx=$(echo "scale=0; ($sx + 1) * 8 + 1" | bc 2>/dev/null || echo "9")
        local gz=$(echo "scale=0; (1 - $sz) * 2 + 1" | bc 2>/dev/null || echo "3")
        
        # Abbreviate name
        local abbr="${sname:0:2}"
        grid["$gx,$gz"]="$abbr"
    done < <(echo "$layout" | jq -c '.speaker_positions[]')
    
    # Draw grid rows
    for z in 1 2 3 4 5; do
        echo -n "     │"
        for x in $(seq 1 17); do
            local key="$x,$z"
            if [[ -n "${grid[$key]:-}" ]]; then
                echo -n "${grid[$key]}"
            else
                echo -n "  "
            fi
        done
        echo "│"
    done
    
    echo "     └─────────────────┘"
    echo "              │"
    echo "         Back"
    echo ""
    
    # Side view
    echo "  Side View (left side):"
    echo "         Top"
    echo "     ─────┬─────"
    
    declare -A side_grid
    while IFS= read -r speaker; do
        local sy=$(echo "$speaker" | jq -r '.y')
        local sz=$(echo "$speaker" | jq -r '.z')
        local sname=$(echo "$speaker" | jq -r '.name')
        
        # Map: y: -0.5 to 1 -> 1 to 5, z: -1 to 1 -> 5 to 1
        local gy=$(echo "scale=0; (1 - $sy) * 2.5 + 1" | bc 2>/dev/null || echo "3")
        local gz=$(echo "scale=0; (1 - $sz) * 2 + 1" | bc 2>/dev/null || echo "3")
        
        side_grid["1,$gz"]="${sname:0:2}"
    done < <(echo "$layout" | jq -c '.speaker_positions[] | select(.x < 0)')
    
    for z in 1 2 3 4 5; do
        echo -n "        │"
        if [[ -n "${side_grid[1,$z]:-}" ]]; then
            echo -n "${side_grid[1,$z]}"
        else
            echo -n "  "
        fi
        echo "│"
    done
    echo "     ─────┴─────"
    echo "        Floor"
    echo ""
}

# Generate room configuration recommendations
recommend_setup() {
    local room_size="${1:-medium_room}"
    
    if ! command -v jq &>/dev/null; then
        log_error "jq is required for recommendations"
        return 1
    fi
    
    local room=$(jq -r ".room_config[\"$room_size\"]" "$CONFIG_FILE")
    
    if [[ "$room" == "null" ]]; then
        log_error "Room size not found: $room_size"
        log_info "Available: small_room, medium_room, large_room"
        return 1
    fi
    
    log_title "Recommended Setup for $(echo "$room" | jq -r '.name')"
    echo ""
    echo "  Speaker distance: $(echo "$room" | jq -r '.speaker_distance')m"
    echo "  Listener distance: $(echo "$room" | jq -r '.listener_distance')m"
    echo "  Room height: $(echo "$room" | jq -r '.height')m"
    echo ""
    
    # Get current layout
    local current=$(get_current_layout)
    local layout=$(jq -r ".layouts[\"$current\"]" "$CONFIG_FILE")
    local channels=$(echo "$layout" | jq -r '.channels')
    
    log_title "Recommended Layout: $current ($channels channels)"
    echo ""
    
    # Calculate actual positions
    local dist=$(echo "$room" | jq -r '.speaker_distance')
    
    echo "  Calculated speaker positions:"
    while IFS= read -r speaker; do
        local name=$(echo "$speaker" | jq -r '.name')
        local x=$(echo "$speaker" | jq -r '.x')
        local y=$(echo "$speaker" | jq -r '.y')
        local z=$(echo "$speaker" | jq -r '.z')
        
        local px=$(echo "scale=2; $x * $dist" | bc)
        local py=$(echo "scale=2; $y * $dist" | bc)
        local pz=$(echo "scale=2; $z * $dist" | bc)
        
        printf "    %-20s: x=%6.2fm, y=%6.2fm, z=%6.2fm\n" "$name" "$px" "$py" "$pz"
    done < <(echo "$layout" | jq -c '.speaker_positions[]')
}

# Show usage
usage() {
    cat << EOF
Speaker Layout Configuration Tool

Usage: $(basename "$0") <command> [options]

Commands:
    list                    List available speaker layouts
    show <layout>          Show detailed information about a layout
    set <layout>           Set active speaker layout
    visualize [layout]     ASCII visualization of layout (default: current)
    recommend [room_size]  Show setup recommendations (small/medium/large)
    current                Show current layout configuration
    env                    Output environment variables for current layout

Layouts:
    stereo              - 2.0 Stereo
    quad                - 4.0 Quadraphonic
    surround_51         - 5.1 Surround (default)
    surround_51_side    - 5.1 with side surrounds
    surround_61         - 6.1 Surround
    surround_71         - 7.1 Surround
    surround_71_sd      - 7.1 SDDS variant
    surround_712        - 7.1.2 Atmos
    surround_714        - 7.1.4 Atmos
    hexagonal           - 6.0 Hexagonal ring
    octagonal           - 8.0 Octagonal ring

Examples:
    $(basename "$0") list                           # Show all layouts
    $(basename "$0") set surround_71               # Switch to 7.1
    $(basename "$0") visualize surround_714        # Visualize Atmos layout
    $(basename "$0") recommend medium_room         # Room recommendations
    
    # Use a layout for playback:
    eval \$($(basename "$0") env)
    ./scripts/run.sh

EOF
}

# Parse command
case "${1:-}" in
    list|ls)
        list_layouts
        ;;
    show)
        if [[ -z "${2:-}" ]]; then
            log_error "Layout key required"
            exit 1
        fi
        show_layout_details "$2"
        ;;
    set)
        if [[ -z "${2:-}" ]]; then
            log_error "Layout key required"
            exit 1
        fi
        set_layout "$2"
        ;;
    visualize|vis|viz)
        visualize_layout "${2:-}"
        ;;
    recommend|rec)
        recommend_setup "${2:-medium_room}"
        ;;
    current)
        current=$(get_current_layout)
        log_info "Current layout: $current"
        show_layout_details "$current"
        ;;
    env)
        current=$(get_current_layout)
        channels=$(jq -r ".layouts[\"$current\"].channels" "$CONFIG_FILE" 2>/dev/null || echo "6")
        echo "export SPEAKER_LAYOUT=$current"
        echo "export OUTPUT_CHANNELS=$channels"
        ;;
    -h|--help|help)
        usage
        ;;
    "")
        usage
        exit 1
        ;;
    *)
        log_error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
