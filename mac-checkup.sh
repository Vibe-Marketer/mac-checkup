#!/bin/bash
# ============================================================================
# Mac Health Checkup - Complete Mac Diagnostic & Cleanup Tool
# Works on both Intel and Apple Silicon Macs
# No AI, no API keys, no internet required. 100% local.
# ============================================================================

set -o pipefail

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS="✓"
WARN="⚠️"
FAIL="✗"

# Track totals across all sections
TOTAL_PROBLEMS=0
TOTAL_WARNINGS=0
TOTAL_RECLAIMABLE_BYTES=0
ALL_RECOMMENDATIONS=()

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print_header() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_section() {
    echo ""
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${DIM}  ────────────────────────────────────────────────────────${NC}"
}

print_good()    { echo -e "  ${GREEN}${PASS}${NC}  $1"; }
print_warning() { echo -e "  ${YELLOW}${WARN}${NC}  $1"; }
print_bad()     { echo -e "  ${RED}${FAIL}${NC}  $1"; }
print_info()    { echo -e "  ${DIM}→${NC}  $1"; }

# Convert bytes to human-readable size
# Portable timeout — macOS doesn't ship GNU timeout, so define one using perl
if ! command -v timeout &>/dev/null; then
    timeout() { local secs=$1; shift; perl -e "alarm $secs; exec @ARGV" -- "$@"; }
fi

human_size() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" -eq 0 ] 2>/dev/null; then
        echo "0 B"
        return
    fi
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc) GB"
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc) MB"
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        echo "$(echo "scale=0; $bytes / 1024" | bc) KB"
    else
        echo "$bytes B"
    fi
}

# Get directory size in bytes (safe, returns 0 if doesn't exist)
dir_size_bytes() {
    local path="$1"
    if [ -d "$path" ]; then
        du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}'
    else
        echo "0"
    fi
}

# Get file count in directory
file_count() {
    local path="$1"
    if [ -d "$path" ]; then
        find "$path" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' '
    else
        echo "0"
    fi
}

pause_for_user() {
    echo ""
    read -p "  Press Enter to continue..." _
}

# ============================================================================
# 1. SYSTEM INFO
# ============================================================================

show_system_info() {
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        CHIP_TYPE="Apple Silicon"
    else
        CHIP_TYPE="Intel"
    fi

    local hw_data
    hw_data=$(system_profiler SPHardwareDataType 2>/dev/null)
    MAC_MODEL=$(echo "$hw_data" | grep "Model Name" | awk -F': ' '{print $2}')
    MAC_CHIP=$(echo "$hw_data" | grep "Chip\|Processor Name" | head -1 | awk -F': ' '{print $2}')
    MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null)
    TOTAL_RAM=$(sysctl -n hw.memsize 2>/dev/null)
    TOTAL_RAM_GB=$(echo "scale=0; $TOTAL_RAM / 1073741824" | bc 2>/dev/null)

    print_header "MAC HEALTH CHECKUP"
    echo ""
    echo -e "  ${DIM}Machine:${NC}  $MAC_MODEL ($CHIP_TYPE — $MAC_CHIP)"
    echo -e "  ${DIM}macOS:${NC}    $MACOS_VERSION"
    echo -e "  ${DIM}Memory:${NC}   ${TOTAL_RAM_GB} GB"
    echo -e "  ${DIM}Date:${NC}     $(date '+%B %d, %Y at %I:%M %p')"
}

# ============================================================================
# 2. BATTERY HEALTH (existing logic, proven working)
# ============================================================================

check_battery() {
    print_header "BATTERY HEALTH"

    # Check if this is a laptop (has a battery)
    local has_battery
    has_battery=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -c "AppleSmartBattery")
    if [ "$has_battery" -eq 0 ]; then
        print_info "No battery detected — this appears to be a desktop Mac"
        print_info "Skipping battery diagnostics"
        return
    fi

    # ── Gather battery data ──
    local SP_DATA
    SP_DATA=$(system_profiler SPPowerDataType 2>/dev/null)
    local BATTERY_CONDITION=$(echo "$SP_DATA" | grep "Condition" | awk -F': ' '{print $2}' | xargs)
    local CHARGER_WATTS=$(echo "$SP_DATA" | grep "Wattage" | awk -F': ' '{print $2}' | xargs)
    local CHARGER_NAME=$(echo "$SP_DATA" | grep "Name" | tail -1 | awk -F': ' '{print $2}' | xargs)
    local CYCLE_COUNT=$(echo "$SP_DATA" | grep "Cycle Count" | awk -F': ' '{print $2}' | xargs)

    # ioreg helper (top-level properties only: " = " with spaces)
    ioreg_val() {
        ioreg -rn AppleSmartBattery 2>/dev/null | grep -E "^\s+\"$1\" = " | head -1 | sed 's/.*= //'
    }

    local MAX_CAPACITY=$(ioreg_val "AppleRawMaxCapacity")
    local DESIGN_CAPACITY=$(ioreg_val "DesignCapacity")
    local DESIGN_CYCLES=$(ioreg_val "DesignCycleCount9C")
    local IS_CHARGING=$(ioreg_val "IsCharging")
    local EXTERNAL_CONNECTED=$(ioreg_val "ExternalConnected")
    local FULLY_CHARGED=$(ioreg_val "FullyCharged")
    local TEMPERATURE_RAW=$(ioreg_val "Temperature")
    local VOLTAGE=$(ioreg_val "Voltage")
    local AMPERAGE_RAW=$(ioreg_val "InstantAmperage")

    # Cell voltages from BatteryData blob
    local CELL_VOLTAGES
    CELL_VOLTAGES=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -E '^\s+"CellVoltage" = ' | head -1 | sed 's/.*= (//' | sed 's/)//' | tr ',' '\n')
    if [ -z "$CELL_VOLTAGES" ]; then
        CELL_VOLTAGES=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep "BatteryData" | grep -o '"CellVoltage"=([0-9,]*)' | sed 's/.*=(//' | sed 's/)//' | tr ',' '\n')
    fi

    # pmset
    local PMSET_DATA=$(pmset -g batt 2>/dev/null)
    local BATTERY_PCT=$(echo "$PMSET_DATA" | grep -o '[0-9]*%' | tr -d '%')
    local TIME_REMAINING=$(echo "$PMSET_DATA" | grep -o '[0-9]*:[0-9]*' | head -1)

    # ── Calculations ──
    local HEALTH_PCT=""
    if [ -n "$MAX_CAPACITY" ] && [ -n "$DESIGN_CAPACITY" ] && [ "$DESIGN_CAPACITY" -gt 0 ] 2>/dev/null; then
        HEALTH_PCT=$(( (MAX_CAPACITY * 100) / DESIGN_CAPACITY ))
    fi

    local TEMP_C="" TEMP_F=""
    if [ -n "$TEMPERATURE_RAW" ] && [ "$TEMPERATURE_RAW" -gt 0 ] 2>/dev/null; then
        TEMP_C=$(echo "scale=1; $TEMPERATURE_RAW / 100" | bc 2>/dev/null)
        TEMP_F=$(echo "scale=1; ($TEMPERATURE_RAW / 100) * 9 / 5 + 32" | bc 2>/dev/null)
    fi

    local CYCLE_PCT=""
    if [ -n "$CYCLE_COUNT" ] && [ -n "$DESIGN_CYCLES" ] && [ "$DESIGN_CYCLES" -gt 0 ] 2>/dev/null; then
        CYCLE_PCT=$(( (CYCLE_COUNT * 100) / DESIGN_CYCLES ))
    fi

    local VOLTAGE_V=""
    if [ -n "$VOLTAGE" ] && [ "$VOLTAGE" -gt 0 ] 2>/dev/null; then
        VOLTAGE_V=$(echo "scale=2; $VOLTAGE / 1000" | bc 2>/dev/null)
    fi

    # ── Display: Health ──
    print_section "HEALTH & CAPACITY"

    if [ -n "$HEALTH_PCT" ]; then
        if [ "$HEALTH_PCT" -ge 90 ]; then
            print_good "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Excellent"
        elif [ "$HEALTH_PCT" -ge 80 ]; then
            print_good "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Good"
        elif [ "$HEALTH_PCT" -ge 70 ]; then
            print_warning "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Worn"
            print_info "Holds about ${HEALTH_PCT}% of its original charge"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
            ALL_RECOMMENDATIONS+=("Battery health is below 80%. Consider replacement when battery life becomes a daily annoyance.")
        elif [ "$HEALTH_PCT" -ge 50 ]; then
            print_bad "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Degraded"
            print_info "Only holds about half its original charge"
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
            ALL_RECOMMENDATIONS+=("Battery is significantly degraded at ${HEALTH_PCT}%. Replacement recommended.")
        else
            print_bad "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Critical"
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
            ALL_RECOMMENDATIONS+=("Battery health is critical. Replace immediately to avoid unexpected shutdowns.")
        fi
        if [ -n "$MAX_CAPACITY" ] && [ -n "$DESIGN_CAPACITY" ]; then
            print_info "Capacity: ${MAX_CAPACITY} mAh of ${DESIGN_CAPACITY} mAh original"
        fi
    fi

    if [ -n "$BATTERY_CONDITION" ]; then
        if [ "$BATTERY_CONDITION" = "Normal" ]; then
            print_good "Apple says: ${BOLD}Normal${NC}"
        elif echo "$BATTERY_CONDITION" | grep -qi "service"; then
            print_warning "Apple says: ${BOLD}${BATTERY_CONDITION}${NC}"
        elif echo "$BATTERY_CONDITION" | grep -qi "replace"; then
            print_bad "Apple says: ${BOLD}${BATTERY_CONDITION}${NC}"
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
        fi
    fi

    # ── Display: Cycles ──
    if [ -n "$CYCLE_COUNT" ]; then
        local cycle_display="${CYCLE_COUNT}"
        [ -n "$DESIGN_CYCLES" ] && [ "$DESIGN_CYCLES" -gt 0 ] && cycle_display="${CYCLE_COUNT} of ${DESIGN_CYCLES}"

        if [ -n "$CYCLE_PCT" ] && [ "$CYCLE_PCT" -gt 80 ]; then
            print_warning "Cycles: ${BOLD}${cycle_display}${NC} (${CYCLE_PCT}% of lifespan)"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        else
            print_good "Cycles: ${BOLD}${cycle_display}${NC}${CYCLE_PCT:+ (${CYCLE_PCT}% of lifespan)}"
        fi
    fi

    # ── Display: Power & Charging ──
    print_section "POWER & CHARGING"

    if [ "$EXTERNAL_CONNECTED" = "Yes" ]; then
        print_good "Power adapter: ${BOLD}Connected${NC}"
        [ -n "$CHARGER_WATTS" ] && print_info "Charger: ${CHARGER_WATTS}W"

        if [ "$IS_CHARGING" = "Yes" ]; then
            print_good "Charging: ${BOLD}Yes${NC}"
        elif [ "$FULLY_CHARGED" = "Yes" ]; then
            print_good "Status: ${BOLD}Fully charged${NC}"
        else
            print_warning "Plugged in but ${BOLD}NOT charging${NC}"
            print_info "Could be Optimized Charging, a charge limiter, or a problem"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        fi
    else
        print_info "Power adapter: ${BOLD}Not connected${NC} — On battery"
        [ -n "$TIME_REMAINING" ] && [ "$TIME_REMAINING" != "0:00" ] && print_info "Time remaining: ~${TIME_REMAINING}"
    fi
    print_info "Charge level: ${BOLD}${BATTERY_PCT:-?}%${NC}"

    # ── Display: Temperature ──
    if [ -n "$TEMP_C" ] && [ -n "$TEMP_F" ]; then
        local TEMP_C_INT=$(echo "$TEMP_C" | awk -F'.' '{print $1}')
        if [ "$TEMP_C_INT" -le 35 ] && [ "$TEMP_C_INT" -ge 10 ]; then
            print_good "Temperature: ${BOLD}${TEMP_F}°F / ${TEMP_C}°C${NC} — Normal"
        elif [ "$TEMP_C_INT" -le 45 ]; then
            print_warning "Temperature: ${BOLD}${TEMP_F}°F / ${TEMP_C}°C${NC} — Warm"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        else
            print_bad "Temperature: ${BOLD}${TEMP_F}°F / ${TEMP_C}°C${NC} — Hot!"
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
            ALL_RECOMMENDATIONS+=("Battery temperature is dangerously high. Let the Mac cool down and check for runaway apps.")
        fi
    fi

    # ── Display: Cell voltages ──
    if [ -n "$CELL_VOLTAGES" ]; then
        local min_cell=99999 max_cell=0
        while IFS= read -r cv; do
            [ -n "$cv" ] && [ "$cv" -gt 0 ] 2>/dev/null && {
                [ "$cv" -lt "$min_cell" ] && min_cell=$cv
                [ "$cv" -gt "$max_cell" ] && max_cell=$cv
            }
        done <<< "$CELL_VOLTAGES"

        if [ "$min_cell" -lt 99999 ] && [ "$max_cell" -gt 0 ]; then
            local cell_diff=$((max_cell - min_cell))
            if [ "$cell_diff" -le 30 ]; then
                print_good "Cell balance: ${BOLD}${cell_diff} mV spread${NC} — Excellent"
            elif [ "$cell_diff" -le 50 ]; then
                print_good "Cell balance: ${BOLD}${cell_diff} mV spread${NC} — Good"
            elif [ "$cell_diff" -le 100 ]; then
                print_warning "Cell balance: ${BOLD}${cell_diff} mV spread${NC} — Uneven"
                TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
            else
                print_bad "Cell balance: ${BOLD}${cell_diff} mV spread${NC} — Failing cell likely"
                TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
                ALL_RECOMMENDATIONS+=("Significant cell voltage imbalance detected. A battery cell may be failing.")
            fi
        fi
    fi
}

# ============================================================================
# 3. RESOURCE HOGS — What's eating your CPU and RAM right now?
# ============================================================================

check_resource_hogs() {
    print_header "RESOURCE HOGS"
    print_info "What's eating your Mac's CPU and memory right now..."
    echo ""

    # ── CPU hogs ──
    print_section "TOP CPU CONSUMERS"

    # Get top 8 CPU processes (exclude kernel/idle)
    ps aux -r 2>/dev/null | awk 'NR>1 && $3>1.0 {printf "%-6s %-30s %s%%\n", $2, substr($11,1,30), $3}' | head -8 | while read -r pid pname cpu; do
        # Clean up process name (just the app name)
        local clean_name=$(echo "$pname" | sed 's|.*/||' | sed 's/\.app.*//')
        if [ -n "$cpu" ]; then
            local cpu_int=$(echo "$cpu" | awk -F'.' '{print $1}' | tr -d '%')
            if [ "$cpu_int" -ge 50 ] 2>/dev/null; then
                print_bad "${BOLD}${clean_name}${NC} is using ${RED}${cpu} CPU${NC}"
            elif [ "$cpu_int" -ge 20 ] 2>/dev/null; then
                print_warning "${BOLD}${clean_name}${NC} is using ${YELLOW}${cpu} CPU${NC}"
            else
                print_info "${clean_name} — ${cpu} CPU"
            fi
        fi
    done

    # Check if nothing is hogging
    local high_cpu_count
    high_cpu_count=$(ps aux -r 2>/dev/null | awk 'NR>1 && $3>10.0' | wc -l | tr -d ' ')
    if [ "$high_cpu_count" -eq 0 ]; then
        print_good "No processes using excessive CPU"
    fi

    # ── RAM hogs ──
    print_section "TOP MEMORY CONSUMERS"

    # Get top 8 memory processes
    ps aux -m 2>/dev/null | awk 'NR>1 && $4>1.0 {printf "%-30s %s%% (%s MB)\n", substr($11,1,30), $4, int($6/1024)}' | head -8 | while read -r line; do
        local pname=$(echo "$line" | awk '{print $1}' | sed 's|.*/||' | sed 's/\.app.*//')
        local mem_pct=$(echo "$line" | grep -o '[0-9.]*%' | head -1)
        local mem_mb=$(echo "$line" | grep -o '([0-9]* MB)' | tr -d '()')

        if [ -n "$mem_pct" ]; then
            local mem_int=$(echo "$mem_pct" | awk -F'.' '{print $1}' | tr -d '%')
            if [ "$mem_int" -ge 10 ] 2>/dev/null; then
                print_warning "${BOLD}${pname}${NC} — ${YELLOW}${mem_pct} RAM${NC} ${DIM}(${mem_mb})${NC}"
            else
                print_info "${pname} — ${mem_pct} RAM ${DIM}(${mem_mb})${NC}"
            fi
        fi
    done

    # ── Memory pressure ──
    print_section "MEMORY PRESSURE"

    local mem_pressure=""
    if command -v memory_pressure &>/dev/null; then
        mem_pressure=$(timeout 10 memory_pressure 2>/dev/null | grep "System-wide memory free percentage" | grep -o '[0-9]*')
    fi
    local swap_used=$(sysctl -n vm.swapusage 2>/dev/null | grep -o 'used = [0-9.]*M' | grep -o '[0-9.]*')

    if [ -n "$mem_pressure" ]; then
        if [ "$mem_pressure" -ge 30 ]; then
            print_good "Memory pressure: ${BOLD}${mem_pressure}% free${NC} — Healthy"
            print_info "Your Mac has plenty of breathing room"
        elif [ "$mem_pressure" -ge 15 ]; then
            print_warning "Memory pressure: ${BOLD}${mem_pressure}% free${NC} — Getting tight"
            print_info "Consider closing some apps if things feel slow"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        else
            print_bad "Memory pressure: ${BOLD}${mem_pressure}% free${NC} — Under pressure!"
            print_info "Your Mac is struggling for memory. Close heavy apps."
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
            ALL_RECOMMENDATIONS+=("Memory is under heavy pressure. Close unused apps, especially browsers with many tabs.")
        fi
    fi

    if [ -n "$swap_used" ]; then
        local swap_int=$(echo "$swap_used" | awk -F'.' '{print $1}')
        if [ "$swap_int" -gt 1000 ] 2>/dev/null; then
            print_warning "Swap used: ${BOLD}${swap_used} MB${NC} — Mac is using disk as overflow memory"
            print_info "This slows things down. Restart or close heavy apps."
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
            ALL_RECOMMENDATIONS+=("High swap usage (${swap_used} MB). A restart would free this up and speed things up.")
        elif [ "$swap_int" -gt 0 ] 2>/dev/null; then
            print_info "Swap used: ${swap_used} MB ${DIM}(normal — macOS manages this)${NC}"
        else
            print_good "Swap: Not using any — RAM is sufficient"
        fi
    fi

    # ── Known resource hog detection ──
    print_section "KNOWN HEAVY APPS"

    local found_hogs=false

    # Parallel arrays for bash 3.2 compatibility (macOS ships ancient bash)
    local hog_names=()
    local hog_tips=()
    hog_names+=("Electron");         hog_tips+=("Many apps use Electron (Chrome under the hood). Consider native alternatives.")
    hog_names+=("Code Helper");      hog_tips+=("VS Code / Cursor uses significant RAM. Zed Editor is a lightweight alternative.")
    hog_names+=("Windsurf");         hog_tips+=("Windsurf is Electron-based and heavy. Zed Editor + Claude Code is lighter.")
    hog_names+=("com.docker");       hog_tips+=("Docker Desktop uses lots of RAM even when idle. OrbStack is a lighter alternative.")
    hog_names+=("Slack Helper");     hog_tips+=("Slack's desktop app is an Electron memory hog. Try the web version instead.")
    hog_names+=("Discord Helper");   hog_tips+=("Discord desktop is Electron-based. The web version uses less memory.")
    hog_names+=("Teams");            hog_tips+=("Microsoft Teams is notoriously heavy. Web version or alternatives like Slack are lighter.")
    hog_names+=("Spotify Helper");   hog_tips+=("Spotify desktop is Electron. The web player at open.spotify.com uses less RAM.")
    hog_names+=("figma_agent");      hog_tips+=("Figma desktop is Electron. Figma in the browser uses less RAM.")

    local running_procs
    running_procs=$(ps aux 2>/dev/null)

    local i=0
    while [ $i -lt ${#hog_names[@]} ]; do
        local hog="${hog_names[$i]}"
        local tip="${hog_tips[$i]}"
        if echo "$running_procs" | grep -qi "$hog"; then
            found_hogs=true
            local mem_for_hog
            mem_for_hog=$(echo "$running_procs" | grep -i "$hog" | awk '{sum += $6} END {printf "%.0f", sum/1024}')
            print_warning "${BOLD}${hog}${NC} detected — using ~${mem_for_hog} MB RAM"
            print_info "${DIM}${tip}${NC}"
            echo ""
        fi
        i=$((i + 1))
    done

    if [ "$found_hogs" = false ]; then
        print_good "No known resource-heavy apps detected"
    fi
}

# ============================================================================
# 4. STORAGE ANALYSIS & CLEANUP
# ============================================================================

check_storage() {
    print_header "STORAGE ANALYSIS"

    # ── Disk usage overview ──
    print_section "DISK SPACE"

    local disk_info
    disk_info=$(df -H / 2>/dev/null | tail -1)
    local disk_total=$(echo "$disk_info" | awk '{print $2}')
    local disk_used=$(echo "$disk_info" | awk '{print $3}')
    local disk_avail=$(echo "$disk_info" | awk '{print $4}')
    local disk_pct=$(echo "$disk_info" | awk '{print $5}' | tr -d '%')

    if [ -n "$disk_pct" ]; then
        if [ "$disk_pct" -lt 70 ]; then
            print_good "Disk: ${BOLD}${disk_used}${NC} used of ${disk_total} (${disk_avail} free)"
            print_info "Plenty of space — you're in good shape"
        elif [ "$disk_pct" -lt 85 ]; then
            print_warning "Disk: ${BOLD}${disk_used}${NC} used of ${disk_total} (${YELLOW}${disk_avail} free${NC})"
            print_info "Getting a bit full. Consider cleaning up."
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        elif [ "$disk_pct" -lt 95 ]; then
            print_bad "Disk: ${BOLD}${disk_used}${NC} used of ${disk_total} (${RED}only ${disk_avail} free${NC})"
            print_info "Low space! This can slow down your Mac and prevent updates."
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
            ALL_RECOMMENDATIONS+=("Disk is ${disk_pct}% full with only ${disk_avail} free. Clean up to prevent slowdowns.")
        else
            print_bad "Disk: ${BOLD}${RED}CRITICALLY LOW${NC} — only ${disk_avail} free!"
            print_info "Your Mac WILL have problems. Clean up immediately."
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
            ALL_RECOMMENDATIONS+=("CRITICAL: Disk is almost full! Clean up immediately to prevent crashes and data loss.")
        fi
    fi

    # ── SSD Health ──
    print_section "DISK HEALTH (SSD)"

    local smart_status
    smart_status=$(diskutil info disk0 2>/dev/null | grep "SMART Status" | awk -F': ' '{print $2}' | xargs)
    if [ "$smart_status" = "Verified" ]; then
        print_good "SSD health: ${BOLD}Verified${NC} — Drive is healthy"
    elif [ -n "$smart_status" ]; then
        print_bad "SSD health: ${BOLD}${smart_status}${NC}"
        TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
        ALL_RECOMMENDATIONS+=("SSD health is '$smart_status'. Back up your data immediately and consider drive replacement.")
    else
        print_info "SSD health: Could not determine (some Macs don't expose SMART data)"
    fi

    # ── Scan cleanable locations ──
    print_section "CLEANABLE JUNK"
    echo -e "  ${DIM}Scanning for files you can safely delete...${NC}"
    echo ""

    # Category arrays (global so run_cleanup can access them)
    CLEAN_NAMES=()
    CLEAN_PATHS=()
    CLEAN_SIZES=()
    CLEAN_DESCRIPTIONS=()
    CLEAN_ACTIONS=()   # cleanup method per category

    # 1. User caches
    local user_cache_size=$(dir_size_bytes "$HOME/Library/Caches")
    CLEAN_NAMES+=("App Caches")
    CLEAN_PATHS+=("$HOME/Library/Caches")
    CLEAN_SIZES+=("$user_cache_size")
    CLEAN_DESCRIPTIONS+=("Temporary data apps store to load faster. Safe to delete — apps rebuild them.")
    CLEAN_ACTIONS+=("clear_contents")

    # 2. User logs
    local user_log_size=$(dir_size_bytes "$HOME/Library/Logs")
    CLEAN_NAMES+=("App Logs")
    CLEAN_PATHS+=("$HOME/Library/Logs")
    CLEAN_SIZES+=("$user_log_size")
    CLEAN_DESCRIPTIONS+=("Old log files from apps. Only useful for debugging — safe to delete.")
    CLEAN_ACTIONS+=("delete_old_files")

    # 3. Trash
    local trash_size=$(dir_size_bytes "$HOME/.Trash")
    CLEAN_NAMES+=("Trash")
    CLEAN_PATHS+=("$HOME/.Trash")
    CLEAN_SIZES+=("$trash_size")
    CLEAN_DESCRIPTIONS+=("Files you already deleted but haven't emptied yet.")
    CLEAN_ACTIONS+=("empty_trash")

    # 4. Downloads older than 30 days
    local old_downloads_size=0
    if [ -d "$HOME/Downloads" ]; then
        old_downloads_size=$(find "$HOME/Downloads" -maxdepth 1 -type f -mtime +30 -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
    fi
    CLEAN_NAMES+=("Old Downloads (30+ days)")
    CLEAN_PATHS+=("DOWNLOADS_OLD")
    CLEAN_SIZES+=("$old_downloads_size")
    CLEAN_DESCRIPTIONS+=("Files in Downloads older than 30 days. Review before deleting.")
    CLEAN_ACTIONS+=("downloads_old")

    # 5. Browser caches (Chrome, Safari, Firefox, Edge, Arc, Brave)
    local browser_cache_size=0
    local browser_paths=()
    for bp in \
        "$HOME/Library/Caches/Google/Chrome" \
        "$HOME/Library/Caches/com.apple.Safari" \
        "$HOME/Library/Caches/Firefox" \
        "$HOME/Library/Caches/com.microsoft.edgemac" \
        "$HOME/Library/Caches/company.thebrowser.Browser" \
        "$HOME/Library/Caches/com.brave.Browser"; do
        if [ -d "$bp" ]; then
            local bp_size=$(dir_size_bytes "$bp")
            browser_cache_size=$((browser_cache_size + bp_size))
            browser_paths+=("$bp")
        fi
    done
    CLEAN_NAMES+=("Browser Caches")
    CLEAN_PATHS+=("BROWSER_CACHES")
    CLEAN_SIZES+=("$browser_cache_size")
    CLEAN_DESCRIPTIONS+=("Cached web pages and data. Pages may load slightly slower temporarily.")
    CLEAN_ACTIONS+=("browser_caches")

    # 6. Xcode derived data
    local xcode_size=0
    if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
        xcode_size=$(dir_size_bytes "$HOME/Library/Developer/Xcode/DerivedData")
    fi
    if [ "$xcode_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=("Xcode Build Data")
        CLEAN_PATHS+=("$HOME/Library/Developer/Xcode/DerivedData")
        CLEAN_SIZES+=("$xcode_size")
        CLEAN_DESCRIPTIONS+=("Old Xcode build artifacts. Rebuilds automatically when needed.")
        CLEAN_ACTIONS+=("rm_rf")
    fi

    # 7. Homebrew cache
    local brew_cache_size=0
    local brew_cache_path=""
    if command -v brew &>/dev/null; then
        brew_cache_path=$(brew --cache 2>/dev/null)
        if [ -d "$brew_cache_path" ]; then
            brew_cache_size=$(dir_size_bytes "$brew_cache_path")
        fi
    fi
    if [ "$brew_cache_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=("Homebrew Cache")
        CLEAN_PATHS+=("$brew_cache_path")
        CLEAN_SIZES+=("$brew_cache_size")
        CLEAN_DESCRIPTIONS+=("Downloaded package files. Homebrew re-downloads if needed.")
        CLEAN_ACTIONS+=("brew_cleanup")
    fi

    # 8. npm cache
    local npm_cache_size=0
    if [ -d "$HOME/.npm/_cacache" ]; then
        npm_cache_size=$(dir_size_bytes "$HOME/.npm/_cacache")
    fi
    if [ "$npm_cache_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=("npm Cache")
        CLEAN_PATHS+=("$HOME/.npm/_cacache")
        CLEAN_SIZES+=("$npm_cache_size")
        CLEAN_DESCRIPTIONS+=("Node.js package cache. Reinstalls re-download as needed.")
        CLEAN_ACTIONS+=("npm_cleanup")
    fi

    # 9. pip cache
    local pip_cache_size=0
    if [ -d "$HOME/Library/Caches/pip" ]; then
        pip_cache_size=$(dir_size_bytes "$HOME/Library/Caches/pip")
    fi
    if [ "$pip_cache_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=("Python pip Cache")
        CLEAN_PATHS+=("$HOME/Library/Caches/pip")
        CLEAN_SIZES+=("$pip_cache_size")
        CLEAN_DESCRIPTIONS+=("Python package cache. Reinstalls re-download as needed.")
        CLEAN_ACTIONS+=("rm_rf")
    fi

    # ── NEW CATEGORY: iOS Device Backups ──
    local ios_backup_size=0
    if [ -d "$HOME/Library/Application Support/MobileSync/Backup" ]; then
        ios_backup_size=$(dir_size_bytes "$HOME/Library/Application Support/MobileSync/Backup")
    fi
    if [ "$ios_backup_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=("iOS Device Backups")
        CLEAN_PATHS+=("$HOME/Library/Application Support/MobileSync/Backup")
        CLEAN_SIZES+=("$ios_backup_size")
        CLEAN_DESCRIPTIONS+=("iPhone/iPad backups stored locally. Each can be 10-50 GB. Remove backups for devices you no longer own.")
        CLEAN_ACTIONS+=("rm_rf")
    fi

    # ── NEW CATEGORY: Mail Attachment Cache ──
    local mail_attach_size=0
    local mail_v_dir
    for mail_v_dir in "$HOME"/Library/Mail/V*; do
        if [ -d "$mail_v_dir/MailData/Attachments" ]; then
            local _s
            _s=$(dir_size_bytes "$mail_v_dir/MailData/Attachments")
            mail_attach_size=$((mail_attach_size + _s))
        fi
        if [ -d "$mail_v_dir/MailData/EmbeddedData" ]; then
            local _s
            _s=$(dir_size_bytes "$mail_v_dir/MailData/EmbeddedData")
            mail_attach_size=$((mail_attach_size + _s))
        fi
    done
    if [ "$mail_attach_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=("Mail Attachment Cache")
        CLEAN_PATHS+=("MAIL_CLEANUP")
        CLEAN_SIZES+=("$mail_attach_size")
        CLEAN_DESCRIPTIONS+=("Downloaded email attachments cached by Mail.app. Safe to clear — re-downloads from server if needed.")
        CLEAN_ACTIONS+=("mail_cleanup")
    fi

    # ── NEW CATEGORY: Docker Images & Volumes ──
    local docker_size=0
    if command -v docker &>/dev/null; then
        local docker_vm_dir="$HOME/Library/Containers/com.docker.docker/Data/vms"
        if [ -d "$docker_vm_dir" ]; then
            docker_size=$(dir_size_bytes "$docker_vm_dir")
        fi
        if docker system df &>/dev/null 2>&1; then
            local docker_df_bytes
            docker_df_bytes=$(docker system df --format '{{.Size}}' 2>/dev/null | awk '
                function to_bytes(s,   n, u) {
                    n = s + 0; u = substr(s, length(s) - 1)
                    if (u == "GB") return int(n * 1073741824)
                    if (u == "MB") return int(n * 1048576)
                    if (u == "kB") return int(n * 1024)
                    return int(n)
                }
                { total += to_bytes($1) }
                END { print (total > 0 ? total : 0) }
            ')
            if [ -n "$docker_df_bytes" ] && [ "$docker_df_bytes" -gt "$docker_size" ] 2>/dev/null; then
                docker_size=$docker_df_bytes
            fi
        fi
    fi
    if [ "$docker_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=("Docker Images & Volumes")
        CLEAN_PATHS+=("DOCKER_CLEANUP")
        CLEAN_SIZES+=("$docker_size")
        CLEAN_DESCRIPTIONS+=("Unused Docker images, containers, and volumes. Reclaim space safely.")
        CLEAN_ACTIONS+=("docker_cleanup")
    fi

    # ── NEW CATEGORY: Time Machine Local Snapshots ──
    local tm_snapshot_count=0
    tm_snapshot_count=$(tmutil listlocalsnapshots / 2>/dev/null | wc -l | tr -d ' ')
    if [ "$tm_snapshot_count" -gt 0 ] 2>/dev/null; then
        local tm_snapshot_size=$((tm_snapshot_count * 524288000))
        CLEAN_NAMES+=("Time Machine Local Snapshots")
        CLEAN_PATHS+=("TM_SNAPSHOT_CLEANUP")
        CLEAN_SIZES+=("$tm_snapshot_size")
        CLEAN_DESCRIPTIONS+=("${tm_snapshot_count} local snapshot(s) on this disk. Safe to delete — full backups remain on your TM drive.")
        CLEAN_ACTIONS+=("tm_snapshot_cleanup")
    fi

    # ── NEW CATEGORY: Language Files (.lproj) ──
    local lproj_size=0
    if [ -d "/Applications" ]; then
        lproj_size=$(find /Applications -name "*.lproj" \
            ! -name "en.lproj" ! -name "Base.lproj" ! -name "English.lproj" \
            -type d 2>/dev/null -exec du -sk {} + 2>/dev/null \
            | awk '{s += $1} END {print s * 1024 + 0}')
    fi
    if [ "$lproj_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=("Language Files (.lproj)")
        CLEAN_PATHS+=("LANGUAGE_CLEANUP")
        CLEAN_SIZES+=("$lproj_size")
        CLEAN_DESCRIPTIONS+=("Non-English language resources in apps. Removing saves space but cannot be undone without reinstalling.")
        CLEAN_ACTIONS+=("language_cleanup")
    fi

    # ── NEW CATEGORY: .DS_Store Files ──
    local dsstore_size=0
    local dsstore_count=0
    dsstore_size=$(find "$HOME" -name ".DS_Store" -type f 2>/dev/null \
        -exec stat -f%z {} + 2>/dev/null | awk '{s += $1} END {print s + 0}')
    dsstore_count=$(find "$HOME" -name ".DS_Store" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$dsstore_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=(".DS_Store Files")
        CLEAN_PATHS+=("DSSTORE_CLEANUP")
        CLEAN_SIZES+=("$dsstore_size")
        CLEAN_DESCRIPTIONS+=("${dsstore_count} hidden folder-metadata files. Safe to delete — macOS recreates them.")
        CLEAN_ACTIONS+=("dsstore_cleanup")
    fi

    # ── NEW CATEGORY: Old iOS Simulators ──
    local simulator_size=0
    if [ -d "$HOME/Library/Developer/CoreSimulator/Devices" ]; then
        simulator_size=$(dir_size_bytes "$HOME/Library/Developer/CoreSimulator/Devices")
    fi
    if [ "$simulator_size" -gt 0 ] 2>/dev/null; then
        CLEAN_NAMES+=("Old iOS Simulators")
        CLEAN_PATHS+=("$HOME/Library/Developer/CoreSimulator/Devices")
        CLEAN_SIZES+=("$simulator_size")
        CLEAN_DESCRIPTIONS+=("iOS Simulator images for Xcode developers. Safe to remove if not actively developing.")
        CLEAN_ACTIONS+=("rm_rf")
    fi

    # ── Display categories ──
    local total_reclaimable=0
    local has_cleanable=false

    for i in "${!CLEAN_NAMES[@]}"; do
        local size=${CLEAN_SIZES[$i]}
        if [ "$size" -gt 1048576 ] 2>/dev/null; then  # Only show if > 1 MB
            has_cleanable=true
            local hr_size=$(human_size "$size")
            total_reclaimable=$((total_reclaimable + size))

            printf "  ${BOLD}%d.${NC} %-28s ${BOLD}%10s${NC}\n" "$((i + 1))" "${CLEAN_NAMES[$i]}" "$hr_size"
            echo -e "     ${DIM}${CLEAN_DESCRIPTIONS[$i]}${NC}"
            echo ""
        fi
    done

    TOTAL_RECLAIMABLE_BYTES=$total_reclaimable

    if [ "$has_cleanable" = true ]; then
        local total_hr=$(human_size "$total_reclaimable")
        echo -e "  ${BOLD}Total reclaimable: ${GREEN}~${total_hr}${NC}"
        echo ""

        if [ "$total_reclaimable" -gt 1073741824 ]; then  # > 1 GB
            ALL_RECOMMENDATIONS+=("You have ~${total_hr} of cleanable junk. Run the cleanup to free space.")
        fi
    else
        print_good "Your Mac is already pretty clean!"
    fi

}

# ============================================================================
# 5. CLEANUP (Interactive — pick what you want to clean)
# ============================================================================

run_cleanup() {
    print_header "CLEANUP"

    if [ "$TOTAL_RECLAIMABLE_BYTES" -lt 1048576 ] 2>/dev/null; then
        print_good "Nothing significant to clean up. You're all set!"
        return
    fi

    # Build display list (only items > 1 MB)
    local display_indices=()
    local display_count=0

    echo ""
    echo -e "  ${BOLD}Select what to clean:${NC}"
    echo ""

    local i=0
    while [ $i -lt ${#CLEAN_NAMES[@]} ]; do
        local size=${CLEAN_SIZES[$i]}
        if [ "$size" -gt 1048576 ] 2>/dev/null; then
            display_count=$((display_count + 1))
            display_indices+=($i)
            local hr_size=$(human_size "$size")
            printf "  ${BOLD}%2d.${NC} %-30s ${BOLD}%10s${NC}\n" "$display_count" "${CLEAN_NAMES[$i]}" "$hr_size"
            echo -e "      ${DIM}${CLEAN_DESCRIPTIONS[$i]}${NC}"
            echo ""
        fi
        i=$((i + 1))
    done

    if [ "$display_count" -eq 0 ]; then
        print_good "Nothing significant to clean!"
        return
    fi

    local total_hr=$(human_size "$TOTAL_RECLAIMABLE_BYTES")
    echo -e "  ${BOLD}Total reclaimable: ~${total_hr}${NC}"
    echo ""
    echo -e "  Enter numbers to clean (e.g. ${CYAN}1,3,5${NC}), ${CYAN}all${NC}, or ${CYAN}skip${NC}:"
    read -p "  > " selection
    echo ""

    if [ -z "$selection" ] || [ "$selection" = "skip" ] || [ "$selection" = "s" ]; then
        print_info "Skipping cleanup"
        return
    fi

    # Parse selection
    local selected=()
    if [ "$selection" = "all" ] || [ "$selection" = "a" ]; then
        local j=0
        while [ $j -lt $display_count ]; do
            selected+=($j)
            j=$((j + 1))
        done
    else
        IFS=', ' read -ra nums <<< "$selection"
        for num in "${nums[@]}"; do
            num=$(echo "$num" | tr -d ' ')
            if [ -n "$num" ] && [ "$num" -ge 1 ] && [ "$num" -le "$display_count" ] 2>/dev/null; then
                selected+=($((num - 1)))
            fi
        done
    fi

    if [ ${#selected[@]} -eq 0 ]; then
        print_info "No valid items selected. Skipping."
        return
    fi

    echo -e "  ${BOLD}Cleaning ${#selected[@]} item(s)...${NC}"
    echo ""

    local freed=0

    for sel in "${selected[@]}"; do
        local real_idx=${display_indices[$sel]}
        local name="${CLEAN_NAMES[$real_idx]}"
        local path="${CLEAN_PATHS[$real_idx]}"
        local action="${CLEAN_ACTIONS[$real_idx]}"

        case "$action" in
            clear_contents)
                if [ -d "$path" ]; then
                    local before=$(dir_size_bytes "$path")
                    find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
                    local after=$(dir_size_bytes "$path")
                    local diff=$((before - after))
                    [ "$diff" -gt 0 ] && freed=$((freed + diff))
                    print_good "Cleared ${name} ($(human_size $diff))"
                fi
                ;;
            delete_old_files)
                if [ -d "$path" ]; then
                    local before=$(dir_size_bytes "$path")
                    find "$path" -mindepth 1 -type f -mtime +7 -delete 2>/dev/null
                    find "$path" -mindepth 1 -type d -empty -delete 2>/dev/null
                    local after=$(dir_size_bytes "$path")
                    local diff=$((before - after))
                    [ "$diff" -gt 0 ] && freed=$((freed + diff))
                    print_good "Cleared ${name} ($(human_size $diff))"
                fi
                ;;
            empty_trash)
                if [ -d "$path" ]; then
                    local before=$(dir_size_bytes "$path")
                    rm -rf "$path/"* 2>/dev/null
                    rm -rf "$path/".[!.]* 2>/dev/null
                    freed=$((freed + before))
                    print_good "Emptied ${name} ($(human_size $before))"
                fi
                ;;
            downloads_old)
                echo -e "  ${YELLOW}${WARN}${NC}  This will delete files in Downloads older than 30 days."
                read -p "  Are you sure? (y/n): " confirm_dl
                if [[ "$confirm_dl" =~ ^[Yy] ]]; then
                    local dl_freed=0
                    while IFS= read -r -d '' file; do
                        local fsize=$(stat -f%z "$file" 2>/dev/null)
                        dl_freed=$((dl_freed + fsize))
                        rm -f "$file" 2>/dev/null
                    done < <(find "$HOME/Downloads" -maxdepth 1 -type f -mtime +30 -print0 2>/dev/null)
                    freed=$((freed + dl_freed))
                    print_good "Removed ${name} ($(human_size $dl_freed))"
                else
                    print_info "Skipped ${name}"
                fi
                ;;
            browser_caches)
                for bp in \
                    "$HOME/Library/Caches/Google/Chrome" \
                    "$HOME/Library/Caches/com.apple.Safari" \
                    "$HOME/Library/Caches/Firefox" \
                    "$HOME/Library/Caches/com.microsoft.edgemac" \
                    "$HOME/Library/Caches/company.thebrowser.Browser" \
                    "$HOME/Library/Caches/com.brave.Browser"; do
                    if [ -d "$bp" ]; then
                        local bp_size=$(dir_size_bytes "$bp")
                        rm -rf "$bp" 2>/dev/null
                        freed=$((freed + bp_size))
                    fi
                done
                print_good "Cleared ${name}"
                ;;
            brew_cleanup)
                if command -v brew &>/dev/null; then
                    local before=$(dir_size_bytes "$path")
                    brew cleanup --prune=all 2>/dev/null
                    local after=$(dir_size_bytes "$path")
                    local diff=$((before - after))
                    [ "$diff" -gt 0 ] && freed=$((freed + diff))
                    print_good "Cleaned ${name} ($(human_size $diff))"
                fi
                ;;
            npm_cleanup)
                if [ -d "$path" ]; then
                    local before=$(dir_size_bytes "$path")
                    npm cache clean --force 2>/dev/null
                    freed=$((freed + before))
                    print_good "Cleared ${name} ($(human_size $before))"
                fi
                ;;
            rm_rf)
                if [ -d "$path" ]; then
                    local before=$(dir_size_bytes "$path")
                    rm -rf "$path" 2>/dev/null
                    freed=$((freed + before))
                    print_good "Cleared ${name} ($(human_size $before))"
                fi
                ;;
            mail_cleanup)
                local mc_freed=0
                local mc_v_dir
                for mc_v_dir in "$HOME"/Library/Mail/V*; do
                    if [ -d "$mc_v_dir/MailData/Attachments" ]; then
                        local mc_s=$(dir_size_bytes "$mc_v_dir/MailData/Attachments")
                        rm -rf "$mc_v_dir/MailData/Attachments" 2>/dev/null
                        mc_freed=$((mc_freed + mc_s))
                    fi
                    if [ -d "$mc_v_dir/MailData/EmbeddedData" ]; then
                        local mc_s=$(dir_size_bytes "$mc_v_dir/MailData/EmbeddedData")
                        rm -rf "$mc_v_dir/MailData/EmbeddedData" 2>/dev/null
                        mc_freed=$((mc_freed + mc_s))
                    fi
                done
                freed=$((freed + mc_freed))
                print_good "Cleared ${name} ($(human_size $mc_freed))"
                ;;
            docker_cleanup)
                if command -v docker &>/dev/null && docker system df &>/dev/null 2>&1; then
                    echo -e "  ${YELLOW}${WARN}${NC}  This will remove ALL unused Docker images, containers, and volumes."
                    read -p "  Are you sure? (y/n): " confirm_docker
                    if [[ "$confirm_docker" =~ ^[Yy] ]]; then
                        docker system prune -af --volumes 2>/dev/null
                        print_good "Docker cleanup complete"
                    else
                        print_info "Skipped Docker cleanup"
                    fi
                else
                    print_info "Docker daemon not running — skipping"
                fi
                ;;
            tm_snapshot_cleanup)
                local snap_date
                snap_date=$(date +%Y%m%d%H%M%S)
                tmutil thinlocalsnapshots / "$snap_date" 1 2>/dev/null
                print_good "Time Machine snapshot thinning requested"
                print_info "macOS will reclaim space in the background"
                ;;
            language_cleanup)
                echo -e "  ${YELLOW}${WARN}${NC}  This removes non-English language files from apps."
                echo -e "  ${YELLOW}${WARN}${NC}  Cannot be undone without reinstalling apps."
                read -p "  Are you sure? (y/n): " confirm_lang
                if [[ "$confirm_lang" =~ ^[Yy] ]]; then
                    local lang_freed=0
                    lang_freed=$(find /Applications -name "*.lproj" \
                        ! -name "en.lproj" ! -name "Base.lproj" ! -name "English.lproj" \
                        -type d 2>/dev/null -exec du -sk {} + 2>/dev/null \
                        | awk '{s += $1} END {print s * 1024 + 0}')
                    find /Applications -name "*.lproj" \
                        ! -name "en.lproj" ! -name "Base.lproj" ! -name "English.lproj" \
                        -type d -exec rm -rf {} + 2>/dev/null
                    freed=$((freed + lang_freed))
                    print_good "Cleared ${name} ($(human_size $lang_freed))"
                else
                    print_info "Skipped language cleanup"
                fi
                ;;
            dsstore_cleanup)
                local ds_freed=0
                ds_freed=$(find "$HOME" -name ".DS_Store" -type f 2>/dev/null \
                    -exec stat -f%z {} + 2>/dev/null | awk '{s += $1} END {print s + 0}')
                find "$HOME" -name ".DS_Store" -type f -delete 2>/dev/null
                freed=$((freed + ds_freed))
                print_good "Cleared ${name} ($(human_size $ds_freed))"
                ;;
        esac
    done

    echo ""
    echo -e "  ${GREEN}${BOLD}Freed up ~$(human_size $freed)${NC}"
}

# ============================================================================
# 6. STALE APPS — What are you not using?
# ============================================================================

check_stale_apps() {
    print_header "UNUSED APPS"
    print_info "Checking for apps you haven't opened in 6+ months..."
    echo ""

    local six_months_ago
    six_months_ago=$(date -v-6m +%s 2>/dev/null)

    # Collect stale apps (sorted by size) into global arrays
    local stale_raw=()

    for app in /Applications/*.app; do
        [ -d "$app" ] || continue
        local app_name=$(basename "$app" .app)

        # Skip essential system apps
        case "$app_name" in
            Safari|Mail|Messages|FaceTime|Calendar|Contacts|Notes|Reminders|\
            "System Preferences"|"System Settings"|Finder|"App Store"|\
            "Font Book"|Preview|TextEdit|Calculator|"Photo Booth"|\
            Utilities|Automator|Terminal|"Activity Monitor"|"Disk Utility"|\
            "Console"|"Keychain Access"|"Migration Assistant"|"Screenshot"|\
            "Digital Color Meter"|"Grapher"|"Script Editor"|Siri)
                continue ;;
        esac

        local last_used
        last_used=$(mdls -name kMDItemLastUsedDate "$app" 2>/dev/null | grep -v "null" | awk -F'= ' '{print $2}')

        if [ -n "$last_used" ] && [ "$last_used" != "(null)" ]; then
            local last_used_epoch
            last_used_epoch=$(date -jf "%Y-%m-%d %H:%M:%S +0000" "$last_used" +%s 2>/dev/null)

            if [ -n "$last_used_epoch" ] && [ "$last_used_epoch" -lt "$six_months_ago" ] 2>/dev/null; then
                local app_size_kb=$(du -sk "$app" 2>/dev/null | awk '{print $1}')
                local app_size_bytes=$((app_size_kb * 1024))
                local app_size_hr=$(human_size "$app_size_bytes")
                local months_ago=$(( ($(date +%s) - last_used_epoch) / 2592000 ))

                stale_raw+=("${app_size_bytes}|${app_name}|${months_ago}|${app_size_hr}|${app}")
            fi
        fi
    done

    # Sort by size (largest first), store in parallel arrays
    local stale_names=()
    local stale_paths=()
    local stale_sizes_hr=()
    local stale_months=()
    local stale_sizes=()

    if [ ${#stale_raw[@]} -gt 0 ]; then
        local sorted
        sorted=$(printf '%s\n' "${stale_raw[@]}" | sort -t'|' -k1 -nr | head -15)

        while IFS='|' read -r size name months hr_size path; do
            [ -z "$name" ] && continue
            stale_names+=("$name")
            stale_paths+=("$path")
            stale_sizes_hr+=("$hr_size")
            stale_months+=("$months")
            stale_sizes+=("$size")
        done <<< "$sorted"
    fi

    if [ ${#stale_names[@]} -gt 0 ]; then
        local total_size=0
        local i=0
        while [ $i -lt ${#stale_names[@]} ]; do
            local num=$((i + 1))
            total_size=$((total_size + ${stale_sizes[$i]}))
            if [ "${stale_sizes[$i]}" -gt 104857600 ] 2>/dev/null; then
                printf "  ${YELLOW}${WARN}${NC}  ${BOLD}%2d.${NC} %-30s %10s  ${DIM}(unused %s months)${NC}\n" "$num" "${stale_names[$i]}" "${stale_sizes_hr[$i]}" "${stale_months[$i]}"
            else
                printf "  ${DIM}→${NC}  ${BOLD}%2d.${NC} %-30s %10s  ${DIM}(unused %s months)${NC}\n" "$num" "${stale_names[$i]}" "${stale_sizes_hr[$i]}" "${stale_months[$i]}"
            fi
            i=$((i + 1))
        done

        echo ""
        local total_hr=$(human_size "$total_size")
        echo -e "  ${DIM}${#stale_names[@]} unused apps — ~${total_hr} total${NC}"

        if [ "$total_size" -gt 1073741824 ]; then
            ALL_RECOMMENDATIONS+=("You have ${#stale_names[@]} unused apps taking up ~${total_hr}. Consider removing ones you don't need.")
        fi

        echo ""
        echo -e "  Enter numbers to move to Trash (e.g. ${CYAN}1,3,5${NC}), ${CYAN}all${NC}, or ${CYAN}skip${NC}:"
        read -p "  > " selection
        echo ""

        if [ -n "$selection" ] && [ "$selection" != "skip" ] && [ "$selection" != "s" ]; then
            local selected=()
            if [ "$selection" = "all" ] || [ "$selection" = "a" ]; then
                local j=0
                while [ $j -lt ${#stale_names[@]} ]; do
                    selected+=($j)
                    j=$((j + 1))
                done
            else
                IFS=', ' read -ra nums <<< "$selection"
                for num in "${nums[@]}"; do
                    num=$(echo "$num" | tr -d ' ')
                    if [ -n "$num" ] && [ "$num" -ge 1 ] && [ "$num" -le ${#stale_names[@]} ] 2>/dev/null; then
                        selected+=($((num - 1)))
                    fi
                done
            fi

            local removed_count=0
            local removed_size=0
            for idx in "${selected[@]}"; do
                local app_path="${stale_paths[$idx]}"
                local app_name="${stale_names[$idx]}"
                if [ -d "$app_path" ]; then
                    mv "$app_path" "$HOME/.Trash/" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        print_good "Moved ${app_name} to Trash"
                        removed_count=$((removed_count + 1))
                        removed_size=$((removed_size + ${stale_sizes[$idx]}))
                    else
                        print_bad "Could not move ${app_name} (may need admin rights)"
                    fi
                fi
            done

            if [ "$removed_count" -gt 0 ]; then
                echo ""
                echo -e "  ${GREEN}${BOLD}Moved ${removed_count} app(s) to Trash (~$(human_size $removed_size))${NC}"
                echo -e "  ${DIM}Empty Trash to fully reclaim the space${NC}"
            fi
        else
            print_info "Skipping — no apps removed"
        fi
    else
        print_good "No stale apps found — you're using what you have!"
    fi
}

# ============================================================================
# 7. STARTUP ITEMS — What launches when your Mac boots?
# ============================================================================

check_startup() {
    print_header "STARTUP ITEMS"
    print_info "Things that launch automatically when you log in..."
    echo ""

    # Collect all startup items into arrays
    local item_names=()
    local item_types=()     # "login" or "agent"
    local item_details=()   # login item name or plist path

    # ── Login Items (user-configured) ──
    local login_items
    login_items=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)

    if [ -n "$login_items" ] && [ "$login_items" != "" ]; then
        IFS=', ' read -ra items <<< "$login_items"
        for item in "${items[@]}"; do
            item=$(echo "$item" | xargs)
            [ -z "$item" ] && continue
            item_names+=("$item")
            item_types+=("login")
            item_details+=("$item")
        done
    fi

    # ── Launch Agents (background services) ──
    if [ -d "$HOME/Library/LaunchAgents" ]; then
        for plist in "$HOME/Library/LaunchAgents"/*.plist; do
            [ -f "$plist" ] || continue
            local label=$(basename "$plist" .plist)

            # Skip Apple's own agents
            case "$label" in
                com.apple.*) continue ;;
            esac

            local is_disabled
            is_disabled=$(defaults read "$plist" Disabled 2>/dev/null)
            if [ "$is_disabled" = "1" ]; then
                continue
            fi

            local friendly_name
            friendly_name=$(echo "$label" | sed 's/com\.//;s/\./ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')

            item_names+=("$friendly_name")
            item_types+=("agent")
            item_details+=("$plist")
        done
    fi

    local startup_count=${#item_names[@]}

    if [ "$startup_count" -gt 0 ]; then
        local i=0
        while [ $i -lt $startup_count ]; do
            local num=$((i + 1))
            local type_label=""
            if [ "${item_types[$i]}" = "login" ]; then
                type_label="Login Item"
            else
                type_label="Background"
            fi
            printf "  ${BOLD}%2d.${NC} %-35s ${DIM}(%s)${NC}\n" "$num" "${item_names[$i]}" "$type_label"
            i=$((i + 1))
        done

        echo ""
        if [ "$startup_count" -gt 8 ]; then
            print_warning "${BOLD}${startup_count} things launch at startup${NC} — that's a lot"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
            ALL_RECOMMENDATIONS+=("You have ${startup_count} startup items. Reducing these will make your Mac boot faster.")
        else
            print_info "${startup_count} startup items"
        fi

        echo ""
        echo -e "  Enter numbers to disable (e.g. ${CYAN}1,3,5${NC}), ${CYAN}all${NC}, or ${CYAN}skip${NC}:"
        read -p "  > " selection
        echo ""

        if [ -n "$selection" ] && [ "$selection" != "skip" ] && [ "$selection" != "s" ]; then
            local selected=()
            if [ "$selection" = "all" ] || [ "$selection" = "a" ]; then
                local j=0
                while [ $j -lt $startup_count ]; do
                    selected+=($j)
                    j=$((j + 1))
                done
            else
                IFS=', ' read -ra nums <<< "$selection"
                for num in "${nums[@]}"; do
                    num=$(echo "$num" | tr -d ' ')
                    if [ -n "$num" ] && [ "$num" -ge 1 ] && [ "$num" -le "$startup_count" ] 2>/dev/null; then
                        selected+=($((num - 1)))
                    fi
                done
            fi

            local disabled_count=0
            for idx in "${selected[@]}"; do
                local name="${item_names[$idx]}"
                local type="${item_types[$idx]}"
                local detail="${item_details[$idx]}"

                if [ "$type" = "login" ]; then
                    osascript -e "tell application \"System Events\" to delete login item \"$detail\"" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        print_good "Removed login item: ${name}"
                        disabled_count=$((disabled_count + 1))
                    else
                        print_bad "Could not remove: ${name}"
                    fi
                elif [ "$type" = "agent" ]; then
                    launchctl unload -w "$detail" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        print_good "Disabled: ${name}"
                        disabled_count=$((disabled_count + 1))
                    else
                        print_bad "Could not disable: ${name}"
                    fi
                fi
            done

            if [ "$disabled_count" -gt 0 ]; then
                echo ""
                echo -e "  ${GREEN}${BOLD}Disabled ${disabled_count} startup item(s)${NC}"
                echo -e "  ${DIM}Changes take effect on next login/restart${NC}"
            fi
        else
            print_info "Skipping — no startup items changed"
        fi
    else
        print_good "Clean startup — nothing unnecessary launching"
    fi
}

# ============================================================================
# 8. STATS APP CHECK
# ============================================================================

check_stats() {
    local stats_installed=false
    if [ -d "/Applications/Stats.app" ] || [ -d "$HOME/Applications/Stats.app" ] || (command -v brew &>/dev/null && brew list --cask stats &>/dev/null 2>&1); then
        stats_installed=true
    fi

    if [ "$stats_installed" = false ]; then
        print_header "RECOMMENDED: STATS APP"
        echo ""
        echo -e "  Stats is a free, open-source system monitor that shows battery"
        echo -e "  health, power wattage, CPU, RAM, and more in your menu bar."
        echo -e "  ${DIM}(https://github.com/exelban/stats — 36,500+ stars)${NC}"
        echo ""
        read -p "  Would you like to install Stats? (y/n): " install_choice
        echo ""

        if [[ "$install_choice" =~ ^[Yy] ]]; then
            if ! command -v brew &>/dev/null; then
                print_warning "Homebrew not installed (needed for Stats)"
                read -p "  Install Homebrew first? (y/n): " brew_choice
                if [[ "$brew_choice" =~ ^[Yy] ]]; then
                    print_info "Installing Homebrew..."
                    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                    [ -f "/opt/homebrew/bin/brew" ] && eval "$(/opt/homebrew/bin/brew shellenv)"
                fi
            fi

            if command -v brew &>/dev/null; then
                print_info "Installing Stats..."
                brew install stats 2>/dev/null && {
                    print_good "Stats installed! Opening..."
                    open -a Stats 2>/dev/null
                } || print_bad "Install failed. Try: brew install stats"
            fi
        fi
    fi
}

# ============================================================================
# 9. OPTIMIZATION RECOMMENDATIONS
# ============================================================================

show_optimizations() {
    print_header "SPEED & OPTIMIZATION TIPS"

    local opt_count=0

    # ── Check Spotlight indexing ──
    local mdworker_cpu
    mdworker_cpu=$(ps aux 2>/dev/null | grep -i "mdworker\|mds_stores" | grep -v grep | awk '{sum += $3} END {printf "%.0f", sum}')
    if [ "$mdworker_cpu" -gt 20 ] 2>/dev/null; then
        print_warning "Spotlight is actively indexing and using ${mdworker_cpu}% CPU"
        print_info "This is normal after updates but slows things down temporarily"
        print_info "If it persists, you can exclude large folders in System Settings → Spotlight"
        opt_count=$((opt_count + 1))
    fi

    # ── Check for pending macOS updates ──
    print_section "SYSTEM"

    local updates_available
    # Use timeout to prevent softwareupdate from hanging (can take 60+ seconds)
    updates_available=$(timeout 10 softwareupdate -l 2>&1 | grep -c "available" || echo "0")
    if [ "$updates_available" -gt 0 ] 2>/dev/null; then
        print_warning "macOS updates are available"
        print_info "Updates include security patches and performance improvements"
        print_info "Go to System Settings → General → Software Update"
        opt_count=$((opt_count + 1))
    else
        print_good "macOS is up to date"
    fi

    # ── DNS cache ──
    print_section "QUICK WINS"

    echo -e "  These are things you can do right now to speed up your Mac:"
    echo ""

    # Check if restart would help (uptime > 14 days)
    local uptime_days
    uptime_days=$(uptime 2>/dev/null | grep -o '[0-9]* day' | awk '{print $1}')
    if [ -n "$uptime_days" ] && [ "$uptime_days" -gt 14 ] 2>/dev/null; then
        print_warning "Your Mac has been running for ${BOLD}${uptime_days} days${NC} without a restart"
        print_info "A restart clears memory leaks, swap, and temporary files"
        print_info "This alone can make a noticeable difference"
        opt_count=$((opt_count + 1))
    elif [ -n "$uptime_days" ] && [ "$uptime_days" -gt 7 ] 2>/dev/null; then
        print_info "Uptime: ${uptime_days} days — a restart every couple weeks helps"
    else
        print_good "Recent restart — memory is fresh"
    fi

    # Offer to flush DNS
    echo ""
    read -p "  Would you like to flush your DNS cache? (speeds up web browsing) (y/n): " flush_dns
    if [[ "$flush_dns" =~ ^[Yy] ]]; then
        echo -e "  ${DIM}(requires admin password)${NC}"
        if sudo dscacheutil -flushcache 2>/dev/null && sudo killall -HUP mDNSResponder 2>/dev/null; then
            print_good "DNS cache flushed"
        else
            print_info "Could not flush DNS (admin password required)"
        fi
    fi

    # ── Reduce visual effects suggestion ──
    local reduce_motion
    reduce_motion=$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null)
    local reduce_transparency
    reduce_transparency=$(defaults read com.apple.universalaccess reduceTransparency 2>/dev/null)

    if [ "$reduce_motion" != "1" ] || [ "$reduce_transparency" != "1" ]; then
        echo ""
        print_info "${BOLD}Reduce visual effects for a snappier feel:${NC}"
        print_info "System Settings → Accessibility → Display"
        [ "$reduce_motion" != "1" ] && print_info "  • Turn on 'Reduce motion'"
        [ "$reduce_transparency" != "1" ] && print_info "  • Turn on 'Reduce transparency'"
        print_info "These make animations faster and reduce GPU work"
    fi
}

# ============================================================================
# 10. WI-FI & NETWORK
# ============================================================================

check_wifi() {
    print_header "WI-FI & NETWORK"

    # Get Wi-Fi interface name
    local wifi_if
    wifi_if=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{getline; print $2}')
    [ -z "$wifi_if" ] && wifi_if="en0"

    # Check if Wi-Fi is on
    local wifi_power
    wifi_power=$(networksetup -getairportpower "$wifi_if" 2>/dev/null | awk -F': ' '{print $2}')

    if [ "$wifi_power" = "Off" ]; then
        print_info "Wi-Fi is ${BOLD}OFF${NC}"
        return
    fi

    # Get Wi-Fi details using system_profiler (works on all macOS versions)
    local wifi_data
    wifi_data=$(system_profiler SPAirPortDataType 2>/dev/null)

    local wifi_name
    wifi_name=$(networksetup -getairportnetwork "$wifi_if" 2>/dev/null | awk -F': ' '{print $2}')

    if [ -n "$wifi_name" ] && [ "$wifi_name" != "You are not associated with an AirPort network." ]; then
        print_good "Connected to: ${BOLD}${wifi_name}${NC}"
    else
        print_bad "Not connected to any Wi-Fi network"
        TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
        ALL_RECOMMENDATIONS+=("Wi-Fi is not connected to any network.")
        return
    fi

    # Signal strength (RSSI)
    local rssi
    rssi=$(/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null | grep "agrCtlRSSI" | awk '{print $2}')

    if [ -n "$rssi" ]; then
        if [ "$rssi" -ge -50 ] 2>/dev/null; then
            print_good "Signal strength: ${BOLD}Excellent${NC} (${rssi} dBm)"
        elif [ "$rssi" -ge -60 ] 2>/dev/null; then
            print_good "Signal strength: ${BOLD}Good${NC} (${rssi} dBm)"
        elif [ "$rssi" -ge -70 ] 2>/dev/null; then
            print_warning "Signal strength: ${BOLD}Fair${NC} (${rssi} dBm)"
            print_info "Move closer to your router for better speed"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        else
            print_bad "Signal strength: ${BOLD}Weak${NC} (${rssi} dBm)"
            print_info "You're too far from the router or there's interference"
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
            ALL_RECOMMENDATIONS+=("Wi-Fi signal is weak (${rssi} dBm). Move closer to the router or consider a mesh system.")
        fi
    fi

    # Channel band (2.4 GHz vs 5 GHz)
    local channel
    channel=$(/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null | grep "channel" | head -1 | awk '{print $2}')
    if [ -n "$channel" ]; then
        local chan_num=$(echo "$channel" | awk -F',' '{print $1}')
        if [ "$chan_num" -le 14 ] 2>/dev/null; then
            print_info "Band: ${BOLD}2.4 GHz${NC} (channel ${channel})"
            print_info "5 GHz is faster if your router supports it"
        else
            print_good "Band: ${BOLD}5 GHz${NC} (channel ${channel}) — Faster band"
        fi
    fi

    # Quick internet connectivity test
    print_section "INTERNET"

    local ping_result
    ping_result=$(ping -c 1 -t 5 8.8.8.8 2>/dev/null | grep "time=" | grep -o "time=[0-9.]*" | cut -d= -f2)

    if [ -n "$ping_result" ]; then
        local ping_int=$(echo "$ping_result" | awk -F'.' '{print $1}')
        if [ "$ping_int" -lt 20 ] 2>/dev/null; then
            print_good "Ping: ${BOLD}${ping_result} ms${NC} — Excellent"
        elif [ "$ping_int" -lt 50 ] 2>/dev/null; then
            print_good "Ping: ${BOLD}${ping_result} ms${NC} — Good"
        elif [ "$ping_int" -lt 100 ] 2>/dev/null; then
            print_warning "Ping: ${BOLD}${ping_result} ms${NC} — Slow"
            print_info "High latency — video calls and browsing may feel sluggish"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        else
            print_bad "Ping: ${BOLD}${ping_result} ms${NC} — Very slow"
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
            ALL_RECOMMENDATIONS+=("Internet latency is very high (${ping_result} ms). Check your router or ISP.")
        fi
    else
        print_bad "Cannot reach the internet"
        print_info "Check your Wi-Fi connection and router"
        TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
    fi

    # DNS resolution speed
    local dns_time
    dns_time=$( { time nslookup google.com >/dev/null 2>&1; } 2>&1 | grep real | awk '{print $2}' | sed 's/[ms]//g')
    # Fallback: just check if DNS works
    if nslookup google.com >/dev/null 2>&1; then
        print_good "DNS resolution: Working"
    else
        print_bad "DNS resolution: ${BOLD}FAILING${NC}"
        print_info "Try changing DNS to 8.8.8.8 or 1.1.1.1 in System Settings → Wi-Fi → Details → DNS"
        TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
        ALL_RECOMMENDATIONS+=("DNS is not resolving. Change DNS servers to 8.8.8.8 or 1.1.1.1.")
    fi
}

# ============================================================================
# 11. BACKUP STATUS
# ============================================================================

check_backup() {
    print_header "BACKUP STATUS"

    # Check Time Machine
    local tm_dest
    tm_dest=$(tmutil destinationinfo 2>/dev/null | grep "Name" | head -1 | awk -F': ' '{print $2}')

    if [ -n "$tm_dest" ]; then
        print_good "Time Machine: ${BOLD}Configured${NC}"
        print_info "Backup destination: ${tm_dest}"

        # Last backup date
        local last_backup
        last_backup=$(tmutil latestbackup 2>/dev/null)
        if [ -n "$last_backup" ]; then
            local backup_date
            backup_date=$(echo "$last_backup" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}')
            local backup_epoch
            backup_epoch=$(date -jf "%Y-%m-%d" "$backup_date" +%s 2>/dev/null)
            local now_epoch=$(date +%s)

            if [ -n "$backup_epoch" ]; then
                local days_ago=$(( (now_epoch - backup_epoch) / 86400 ))

                if [ "$days_ago" -le 1 ]; then
                    print_good "Last backup: ${BOLD}Today${NC}"
                elif [ "$days_ago" -le 7 ]; then
                    print_good "Last backup: ${BOLD}${days_ago} days ago${NC}"
                elif [ "$days_ago" -le 30 ]; then
                    print_warning "Last backup: ${BOLD}${days_ago} days ago${NC}"
                    print_info "Consider running a backup soon"
                    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                else
                    print_bad "Last backup: ${BOLD}${days_ago} days ago${NC}"
                    print_info "Your data is at risk! Connect your backup drive."
                    TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
                    ALL_RECOMMENDATIONS+=("Last Time Machine backup was ${days_ago} days ago. Back up immediately.")
                fi
            fi
        fi
    else
        print_bad "Time Machine: ${BOLD}NOT CONFIGURED${NC}"
        print_info "You have NO backup. If your drive fails, your data is gone."
        print_info "Set up in System Settings → General → Time Machine"
        print_info "All you need is an external drive — macOS handles the rest."
        TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
        ALL_RECOMMENDATIONS+=("No backup configured! Set up Time Machine to protect your data.")
    fi

    # Check iCloud Drive
    if [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ]; then
        print_good "iCloud Drive: ${BOLD}Active${NC}"
    else
        print_info "iCloud Drive: Not detected"
    fi
}

# ============================================================================
# 12. SECURITY CHECK
# ============================================================================

check_security() {
    print_header "SECURITY CHECK"

    # Firewall
    local fw_status
    fw_status=$(/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -o "enabled\|disabled")
    if [ "$fw_status" = "enabled" ]; then
        print_good "Firewall: ${BOLD}ON${NC}"
    else
        print_warning "Firewall: ${BOLD}OFF${NC}"
        print_info "Turn on in System Settings → Network → Firewall"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        ALL_RECOMMENDATIONS+=("Firewall is off. Enable it in System Settings → Network → Firewall.")
    fi

    # FileVault
    local fv_status
    fv_status=$(fdesetup status 2>/dev/null)
    if echo "$fv_status" | grep -q "On"; then
        print_good "FileVault (disk encryption): ${BOLD}ON${NC}"
    else
        print_warning "FileVault (disk encryption): ${BOLD}OFF${NC}"
        print_info "Your data is not encrypted. If the Mac is stolen, files are readable."
        print_info "Enable in System Settings → Privacy & Security → FileVault"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        ALL_RECOMMENDATIONS+=("FileVault is off. Enable disk encryption to protect your data if the Mac is lost/stolen.")
    fi

    # System Integrity Protection (SIP)
    local sip_status
    sip_status=$(csrutil status 2>/dev/null | grep -o "enabled\|disabled")
    if [ "$sip_status" = "enabled" ]; then
        print_good "System Integrity Protection: ${BOLD}ON${NC}"
    elif [ "$sip_status" = "disabled" ]; then
        print_bad "System Integrity Protection: ${BOLD}DISABLED${NC}"
        print_info "SIP protects core macOS files from modification. Re-enable it."
        TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
        ALL_RECOMMENDATIONS+=("SIP is disabled! This is a major security risk. Re-enable via Recovery Mode.")
    fi

    # Remote access
    local remote_login
    remote_login=$(systemsetup -getremotelogin 2>/dev/null | grep -o "On\|Off")
    if [ "$remote_login" = "On" ]; then
        print_warning "Remote Login (SSH): ${BOLD}ON${NC}"
        print_info "Someone could SSH into this Mac. Turn off if not needed:"
        print_info "System Settings → General → Sharing → Remote Login"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
    else
        print_good "Remote Login (SSH): ${BOLD}OFF${NC}"
    fi

    local screen_sharing
    screen_sharing=$(defaults read /var/db/launchd.db/com.apple.launchd/overrides.plist com.apple.screensharing 2>/dev/null | grep -o "true\|false" || echo "")
    # Fallback check
    if launchctl list 2>/dev/null | grep -q "com.apple.screensharing"; then
        print_warning "Screen Sharing: ${BOLD}ON${NC}"
        print_info "Turn off if not needed: System Settings → General → Sharing"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
    else
        print_good "Screen Sharing: ${BOLD}OFF${NC}"
    fi

    # Gatekeeper
    local gk_status
    gk_status=$(spctl --status 2>/dev/null | grep -o "enabled\|disabled")
    if [ "$gk_status" = "enabled" ]; then
        print_good "Gatekeeper (app verification): ${BOLD}ON${NC}"
    elif [ "$gk_status" = "disabled" ]; then
        print_warning "Gatekeeper: ${BOLD}OFF${NC} — Apps are not being verified"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
    fi
}

# ============================================================================
# 13. SAVE REPORT
# ============================================================================

save_report() {
    print_header "SAVE REPORT"
    echo ""
    echo -e "  Would you like to save this diagnostic report to a file?"
    echo -e "  ${DIM}Useful for sharing with someone helping you, or for your records.${NC}"
    echo ""
    read -p "  Save report to Desktop? (y/n): " save_choice
    echo ""

    if [[ "$save_choice" =~ ^[Yy] ]]; then
        local report_file="$HOME/Desktop/Mac-Health-Report-$(date '+%Y-%m-%d-%H%M').txt"

        # Re-run the whole diagnostic but capture output (strip color codes)
        {
            echo "============================================================"
            echo "  MAC HEALTH CHECKUP REPORT"
            echo "  $(date '+%B %d, %Y at %I:%M %p')"
            echo "  ${MAC_MODEL} (${CHIP_TYPE} — ${MAC_CHIP})"
            echo "  macOS ${MACOS_VERSION}"
            echo "============================================================"
            echo ""
            echo "PROBLEMS: ${TOTAL_PROBLEMS}"
            echo "WARNINGS: ${TOTAL_WARNINGS}"
            echo ""
            if [ ${#ALL_RECOMMENDATIONS[@]} -gt 0 ]; then
                echo "RECOMMENDATIONS:"
                for rec in "${ALL_RECOMMENDATIONS[@]}"; do
                    echo "  • $rec"
                done
                echo ""
            fi
            echo "------------------------------------------------------------"
            echo "  Full diagnostic was displayed on screen."
            echo "  Re-run mac-checkup for the full interactive experience."
            echo "------------------------------------------------------------"
            echo ""
            echo "QUICK DATA SNAPSHOT:"
            echo ""
            echo "--- Battery ---"
            system_profiler SPPowerDataType 2>/dev/null | grep -E "Condition|Cycle Count|Maximum Capacity|Charging|Connected" | sed 's/^/  /'
            echo ""
            echo "--- Disk ---"
            df -H / 2>/dev/null | tail -1 | awk '{printf "  Used: %s of %s (%s free)\n", $3, $2, $4}'
            diskutil info disk0 2>/dev/null | grep "SMART" | sed 's/^/  /'
            echo ""
            echo "--- Memory ---"
            echo "  Total RAM: ${TOTAL_RAM_GB} GB"
            vm_stat 2>/dev/null | head -5 | sed 's/^/  /'
            echo ""
            echo "--- Top CPU ---"
            ps aux -r 2>/dev/null | head -6 | awk '{printf "  %-20s CPU: %s%%  MEM: %s%%\n", $11, $3, $4}' | sed 's|.*/||'
            echo ""
            echo "--- Top Memory ---"
            ps aux -m 2>/dev/null | head -6 | awk '{printf "  %-20s CPU: %s%%  MEM: %s%%  (%s MB)\n", $11, $3, $4, int($6/1024)}' | sed 's|.*/||'
            echo ""
            echo "--- Security ---"
            /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | sed 's/^/  /'
            fdesetup status 2>/dev/null | sed 's/^/  /'
            csrutil status 2>/dev/null | sed 's/^/  /'
            echo ""
            echo "--- Backup ---"
            tmutil destinationinfo 2>/dev/null | head -3 | sed 's/^/  /'
            echo ""
            echo "============================================================"
            echo "  Generated by Mac Health Checkup"
            echo "  https://github.com/Vibe-Marketer/mac-checkup"
            echo "============================================================"
        } > "$report_file"

        print_good "Report saved to: ${BOLD}${report_file}${NC}"
        print_info "You can AirDrop, email, or message this file to anyone"

        # Open in Finder
        open -R "$report_file" 2>/dev/null
    else
        print_info "Skipping report save"
    fi
}

# ============================================================================
# 14. LARGE FILE FINDER
# ============================================================================

find_large_files() {
    print_header "LARGE FILE FINDER"

    local tmp_results="/tmp/mhc_large_files_$$"
    local tmp_sorted="/tmp/mhc_large_sorted_$$"
    local tmp_display="/tmp/mhc_large_display_$$"

    trap 'rm -f "$tmp_results" "$tmp_sorted" "$tmp_display"' RETURN

    print_info "Scanning $HOME for files larger than 100 MB..."
    print_info "This may take a moment depending on how many files you have."
    echo ""

    find "$HOME" \
        \( \
            -path "$HOME/Library" -o \
            -path "$HOME/.Trash" -o \
            -path "$HOME/.*cache*" -o \
            -path "$HOME/.*Cache*" -o \
            -path "/Volumes" \
        \) -prune -o \
        -type f -size +100M -print 2>/dev/null | \
    while IFS= read -r filepath; do
        local fsize
        fsize=$(stat -f%z "$filepath" 2>/dev/null)
        if [ -n "$fsize" ]; then
            printf '%s|%s\n' "$fsize" "$filepath"
        fi
    done > "$tmp_results"

    local file_count
    file_count=$(wc -l < "$tmp_results" 2>/dev/null | tr -d ' ')

    if [ "$file_count" -eq 0 ]; then
        print_good "No files larger than 100 MB found outside excluded directories."
        echo ""
        return
    fi

    sort -t'|' -k1 -rn "$tmp_results" | head -20 > "$tmp_sorted"

    local total_bytes=0
    while IFS='|' read -r fsize fpath; do
        total_bytes=$(( total_bytes + fsize ))
    done < "$tmp_results"

    local total_human
    total_human=$(human_size "$total_bytes")

    local display_count
    display_count=$(wc -l < "$tmp_sorted" | tr -d ' ')

    print_section "Found $file_count large file(s) — Total size: ${BOLD}${total_human}${NC}"
    echo ""

    rm -f "$tmp_display"

    local idx=0
    while IFS='|' read -r fsize fpath; do
        idx=$(( idx + 1 ))
        local fname
        fname=$(basename "$fpath")
        local fsize_human
        fsize_human=$(human_size "$fsize")
        local fdir
        fdir=$(dirname "$fpath")
        local fdir_display
        fdir_display=$(printf '%s' "$fdir" | sed "s|^$HOME|~|")
        local fmod
        fmod=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$fpath" 2>/dev/null)
        [ -z "$fmod" ] && fmod="unknown"

        printf "  ${BOLD}%2d.${NC} ${CYAN}%-40s${NC} ${YELLOW}%8s${NC}  ${DIM}%s${NC}  ${DIM}Modified: %s${NC}\n" \
            "$idx" "$fname" "$fsize_human" "$fdir_display" "$fmod"

        printf '%d|%s\n' "$idx" "$fpath" >> "$tmp_display"
    done < "$tmp_sorted"

    if [ "$file_count" -gt 20 ]; then
        echo ""
        print_info "Showing top 20 of $file_count large files found."
    fi

    echo ""

    local gb5=$(( 5 * 1024 * 1024 * 1024 ))
    if [ "$total_bytes" -gt "$gb5" ]; then
        TOTAL_WARNINGS=$(( TOTAL_WARNINGS + 1 ))
        ALL_RECOMMENDATIONS+=("Large files consuming ${total_human} found in home directory — review and remove unneeded files.")
        print_warning "Total large-file usage exceeds 5 GB (${total_human}). Consider cleaning up."
    else
        print_good "Total large-file usage: ${total_human}"
    fi

    echo ""

    printf "${BOLD}Enter a number to reveal in Finder, or 'skip': ${NC}"
    local user_choice
    read -r user_choice 2>/dev/null

    case "$user_choice" in
        skip|s|"")
            print_info "Skipping Finder reveal."
            ;;
        *)
            if printf '%s' "$user_choice" | grep -qE '^[0-9]+$'; then
                local chosen_path
                chosen_path=$(grep "^${user_choice}|" "$tmp_display" 2>/dev/null | cut -d'|' -f2-)
                if [ -n "$chosen_path" ]; then
                    print_info "Revealing in Finder: $chosen_path"
                    open -R "$chosen_path" 2>/dev/null
                else
                    print_warning "No entry found for number $user_choice."
                fi
            else
                print_warning "Invalid input '$user_choice' — skipping Finder reveal."
            fi
            ;;
    esac

    echo ""
}

# ============================================================================
# 15. DUPLICATE FILE FINDER
# ============================================================================

find_duplicates() {
    print_header "DUPLICATE FILE FINDER"

    local scan_dirs="$HOME/Downloads $HOME/Documents $HOME/Desktop"

    local tmp_candidates="/tmp/mhc_dup_candidates_$$"
    local tmp_sized="/tmp/mhc_dup_sized_$$"
    local tmp_md5="/tmp/mhc_dup_md5_$$"
    local tmp_groups="/tmp/mhc_dup_groups_$$"
    local tmp_group_paths="/tmp/mhc_dup_gpaths_$$"

    trap 'rm -f "$tmp_candidates" "$tmp_sized" "$tmp_md5" "$tmp_groups" "$tmp_group_paths"' RETURN

    rm -f "$tmp_candidates" "$tmp_sized" "$tmp_md5" "$tmp_groups" "$tmp_group_paths"

    local mb1=$(( 1 * 1024 * 1024 ))

    local dir
    for dir in $scan_dirs; do
        if [ ! -d "$dir" ]; then
            print_info "Directory not found, skipping: $dir"
            continue
        fi

        printf "  ${DIM}Scanning %s ...${NC}\n" "$dir"

        find "$dir" \
            -not -name '.*' \
            -not -path '*/.*' \
            -type f -size +1M -print 2>/dev/null >> "$tmp_candidates"
    done

    local total_files
    total_files=$(wc -l < "$tmp_candidates" 2>/dev/null | tr -d ' ')

    echo ""

    if [ "$total_files" -eq 0 ]; then
        print_good "No files >= 1 MB found in scanned directories."
        echo ""
        return
    fi

    if [ "$total_files" -gt 5000 ]; then
        print_warning "Found $total_files files to check — this could take a while."
        printf "${BOLD}Continue scanning? (yes/no): ${NC}"
        local cont_choice
        read -r cont_choice 2>/dev/null
        case "$cont_choice" in
            yes|y|Y|YES)
                print_info "Continuing scan..."
                ;;
            *)
                print_info "Duplicate scan cancelled."
                echo ""
                return
                ;;
        esac
    else
        print_info "Found $total_files file(s) to check for duplicates."
    fi

    echo ""

    print_info "Gathering file sizes..."

    while IFS= read -r filepath; do
        local fsize
        fsize=$(stat -f%z "$filepath" 2>/dev/null)
        if [ -n "$fsize" ] && [ "$fsize" -ge "$mb1" ]; then
            printf '%s|%s\n' "$fsize" "$filepath"
        fi
    done < "$tmp_candidates" > "$tmp_sized"

    sort -t'|' -k1 -n "$tmp_sized" > "${tmp_sized}.sorted"
    mv "${tmp_sized}.sorted" "$tmp_sized"

    local tmp_dup_sizes="/tmp/mhc_dupsizes_$$"
    cut -d'|' -f1 "$tmp_sized" | sort | uniq -d > "$tmp_dup_sizes"

    local dup_size_count
    dup_size_count=$(wc -l < "$tmp_dup_sizes" | tr -d ' ')

    if [ "$dup_size_count" -eq 0 ]; then
        print_good "No files with matching sizes found — no duplicates detected."
        rm -f "$tmp_dup_sizes"
        echo ""
        return
    fi

    print_info "Found $dup_size_count size group(s) to verify with MD5 checksums..."
    echo ""

    local checked=0
    while IFS= read -r dup_size; do
        grep "^${dup_size}|" "$tmp_sized" | while IFS='|' read -r fsize fpath; do
            local fmd5
            fmd5=$(md5 -q "$fpath" 2>/dev/null)
            if [ -n "$fmd5" ]; then
                printf '%s|%s|%s\n' "$fsize" "$fmd5" "$fpath"
            fi
        done
        checked=$(( checked + 1 ))
        printf "\r  ${DIM}Checksumming group %d of %d ...${NC}" "$checked" "$dup_size_count"
    done < "$tmp_dup_sizes" >> "$tmp_md5"

    rm -f "$tmp_dup_sizes"
    echo ""
    echo ""

    if [ ! -s "$tmp_md5" ]; then
        print_good "No duplicates found after checksum verification."
        echo ""
        return
    fi

    sort -t'|' -k1,2 "$tmp_md5" > "${tmp_md5}.sorted"
    mv "${tmp_md5}.sorted" "$tmp_md5"

    local prev_key=""
    local group_lines=""
    local group_num=0
    local total_wasted=0

    while IFS='|' read -r fsize fmd5 fpath; do
        local cur_key="${fsize}|${fmd5}"
        if [ "$cur_key" = "$prev_key" ]; then
            group_lines="${group_lines}::${fpath}"
        else
            if [ -n "$prev_key" ]; then
                local path_count
                path_count=$(printf '%s' "$group_lines" | tr ':' '\n' | grep -c '/' 2>/dev/null)
                if [ "$path_count" -ge 2 ]; then
                    group_num=$(( group_num + 1 ))
                    local g_size g_md5
                    g_size=$(printf '%s' "$prev_key" | cut -d'|' -f1)
                    g_md5=$(printf '%s' "$prev_key" | cut -d'|' -f2)
                    printf 'GROUP|%d|%s|%s|%s\n' "$group_num" "$g_size" "$g_md5" "$group_lines" >> "$tmp_groups"
                    local wasted=$(( g_size * (path_count - 1) ))
                    total_wasted=$(( total_wasted + wasted ))
                fi
            fi
            prev_key="$cur_key"
            group_lines="$fpath"
        fi
    done < "$tmp_md5"

    if [ -n "$prev_key" ]; then
        local path_count
        path_count=$(printf '%s' "$group_lines" | tr ':' '\n' | grep -c '/' 2>/dev/null)
        if [ "$path_count" -ge 2 ]; then
            group_num=$(( group_num + 1 ))
            local g_size g_md5
            g_size=$(printf '%s' "$prev_key" | cut -d'|' -f1)
            g_md5=$(printf '%s' "$prev_key" | cut -d'|' -f2)
            printf 'GROUP|%d|%s|%s|%s\n' "$group_num" "$g_size" "$g_md5" "$group_lines" >> "$tmp_groups"
            local wasted=$(( g_size * (path_count - 1) ))
            total_wasted=$(( total_wasted + wasted ))
        fi
    fi

    if [ "$group_num" -eq 0 ]; then
        print_good "No duplicate files found after checksum verification."
        echo ""
        return
    fi

    local total_wasted_human
    total_wasted_human=$(human_size "$total_wasted")

    print_section "Found ${BOLD}$group_num${NC} duplicate group(s) — Wasted space: ${BOLD}${YELLOW}${total_wasted_human}${NC}"
    echo ""

    while IFS='|' read -r tag gidx gsize gmd5 gpaths; do
        local gsize_human
        gsize_human=$(human_size "$gsize")

        printf "  ${BOLD}${BLUE}Group %d${NC}  ${DIM}(size: %s, md5: %.8s...)${NC}\n" \
            "$gidx" "$gsize_human" "$gmd5"

        local path_idx=0
        local IFS_SAVE="$IFS"
        IFS=':'
        for segment in $gpaths; do
            if [ -n "$segment" ] && [ "$segment" != ":" ]; then
                path_idx=$(( path_idx + 1 ))
                local display_path
                display_path=$(printf '%s' "$segment" | sed "s|^$HOME|~|")
                if [ "$path_idx" -eq 1 ]; then
                    printf "    ${GREEN}[keep]${NC} %s\n" "$display_path"
                else
                    printf "    ${RED}[dupe]${NC} %s\n" "$display_path"
                fi
            fi
        done
        IFS="$IFS_SAVE"

        echo ""
    done < "$tmp_groups"

    local gb1=$(( 1 * 1024 * 1024 * 1024 ))
    if [ "$total_wasted" -gt "$gb1" ]; then
        TOTAL_WARNINGS=$(( TOTAL_WARNINGS + 1 ))
        ALL_RECOMMENDATIONS+=("Duplicate files wasting ${total_wasted_human} found — clean up duplicates in Downloads, Documents, Desktop.")
    fi

    printf "${BOLD}Enter groups to clean (e.g. 1,3,5), 'all', or 'skip': ${NC}"
    local del_choice
    read -r del_choice 2>/dev/null

    case "$del_choice" in
        skip|s|"")
            print_info "Skipping duplicate cleanup."
            echo ""
            return
            ;;
    esac

    local groups_to_clean=""
    if [ "$del_choice" = "all" ]; then
        local n=1
        while [ "$n" -le "$group_num" ]; do
            groups_to_clean="${groups_to_clean} $n"
            n=$(( n + 1 ))
        done
    else
        local IFS_SAVE="$IFS"
        IFS=','
        for token in $del_choice; do
            IFS="$IFS_SAVE"
            token=$(printf '%s' "$token" | tr -d ' ')
            if printf '%s' "$token" | grep -qE '^[0-9]+$'; then
                if [ "$token" -ge 1 ] && [ "$token" -le "$group_num" ]; then
                    groups_to_clean="${groups_to_clean} $token"
                else
                    print_warning "Group $token out of range, skipping."
                fi
            fi
            IFS=','
        done
        IFS="$IFS_SAVE"
    fi

    if [ -z "$groups_to_clean" ]; then
        print_warning "No valid groups selected."
        echo ""
        return
    fi

    local trash_dir="$HOME/.Trash"
    local deleted_count=0
    local deleted_bytes=0

    echo ""
    print_info "Moving duplicates to Trash (keeping first copy in each group)..."
    echo ""

    for gidx in $groups_to_clean; do
        local group_line
        group_line=$(grep "^GROUP|${gidx}|" "$tmp_groups" 2>/dev/null)
        if [ -z "$group_line" ]; then
            print_warning "Could not find group $gidx data, skipping."
            continue
        fi

        local gsize gpaths gmd5
        gsize=$(printf '%s' "$group_line" | cut -d'|' -f3)
        gmd5=$(printf '%s' "$group_line" | cut -d'|' -f4)
        gpaths=$(printf '%s' "$group_line" | cut -d'|' -f5-)

        printf "  ${BOLD}Group %d:${NC}\n" "$gidx"

        local path_idx=0
        local IFS_SAVE="$IFS"
        IFS=':'
        for segment in $gpaths; do
            IFS="$IFS_SAVE"
            if [ -n "$segment" ] && [ "$segment" != ":" ]; then
                path_idx=$(( path_idx + 1 ))
                if [ "$path_idx" -eq 1 ]; then
                    local keep_display
                    keep_display=$(printf '%s' "$segment" | sed "s|^$HOME|~|")
                    printf "    ${GREEN}Keeping:${NC}  %s\n" "$keep_display"
                else
                    if [ -f "$segment" ]; then
                        local fname
                        fname=$(basename "$segment")
                        local dest_path="$trash_dir/$fname"
                        if [ -e "$dest_path" ]; then
                            dest_path="${trash_dir}/${fname}_dup_$$_${path_idx}"
                        fi
                        mv "$segment" "$dest_path" 2>/dev/null
                        if [ $? -eq 0 ]; then
                            local del_display
                            del_display=$(printf '%s' "$segment" | sed "s|^$HOME|~|")
                            printf "    ${RED}Trashed:${NC}  %s\n" "$del_display"
                            deleted_count=$(( deleted_count + 1 ))
                            deleted_bytes=$(( deleted_bytes + gsize ))
                        else
                            print_warning "Failed to trash: $segment"
                        fi
                    else
                        print_warning "File no longer exists: $segment"
                    fi
                fi
            fi
            IFS=':'
        done
        IFS="$IFS_SAVE"

        echo ""
    done

    local deleted_human
    deleted_human=$(human_size "$deleted_bytes")

    if [ "$deleted_count" -gt 0 ]; then
        print_good "Moved $deleted_count duplicate file(s) to Trash — freed ${deleted_human}."
    else
        print_info "No files were moved."
    fi

    echo ""
}

# ============================================================================
# 16. APP UNINSTALLER (with leftover detection)
# ============================================================================

uninstall_apps() {
    print_header "APP UNINSTALLER"

    local SYSTEM_APPS="Safari|Mail|Messages|FaceTime|Maps|Photos|Music|Podcasts|TV|News|Stocks|Weather|Clock|Reminders|Notes|Calendar|Contacts|Preview|TextEdit|Chess|Stickies|Calculator|Dictionary|QuickTime Player|Font Book|Image Capture|Screenshot|Automator|Script Editor|Terminal|Activity Monitor|Console|Disk Utility|Migration Assistant|Boot Camp Assistant|Bluetooth File Exchange|AirPort Utility|ColorSync Utility|Directory Utility|System Information|Keychain Access|VoiceOver Utility|Audio MIDI Setup|Digital Color Meter|Grapher|System Preferences|System Settings|Finder|Launchpad|Mission Control|App Store|iBooks|Books|Home|Shortcuts|Freeform"

    echo ""
    print_info "Scanning /Applications for third-party apps..."
    echo ""

    local APP_NAMES=()
    local APP_PATHS=()
    local APP_SIZES=()

    local raw_list
    raw_list=$(find /Applications -maxdepth 1 -name "*.app" -type d 2>/dev/null | sort)

    local app
    while IFS= read -r app; do
        [ -z "$app" ] && continue

        local name
        name=$(basename "$app" .app)

        if echo "$name" | grep -qE "^(${SYSTEM_APPS})$" 2>/dev/null; then
            continue
        fi

        local size_bytes
        size_bytes=$(du -sk "$app" 2>/dev/null | awk '{print $1 * 1024}')
        [ -z "$size_bytes" ] && size_bytes=0

        APP_NAMES+=("$name")
        APP_PATHS+=("$app")
        APP_SIZES+=("$size_bytes")
    done <<EOF
$raw_list
EOF

    local total_apps=${#APP_NAMES[@]}

    if [ "$total_apps" -eq 0 ]; then
        print_info "No third-party apps found in /Applications."
        return
    fi

    echo -e "  ${BOLD}Third-party apps in /Applications:${NC}"
    echo ""

    local i=0
    while [ "$i" -lt "$total_apps" ]; do
        local human
        human=$(human_size "${APP_SIZES[$i]}")
        printf "  ${CYAN}%3d)${NC}  %-45s  ${DIM}%s${NC}\n" \
            "$((i + 1))" "${APP_NAMES[$i]}" "$human"
        i=$((i + 1))
    done

    echo ""
    echo -e "  ${DIM}Enter numbers separated by commas to uninstall (e.g. 1,3,5), or 'skip':${NC}"
    printf "  > "
    local selection
    read -r selection

    if [ -z "$selection" ] || [ "$selection" = "skip" ]; then
        print_info "Skipping app uninstaller."
        return
    fi

    local SELECTED_INDICES=()
    local token
    local selection_spaced
    selection_spaced=$(echo "$selection" | tr ',' ' ')
    for token in $selection_spaced; do
        if echo "$token" | grep -qE '^[0-9]+$'; then
            local idx=$((token - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "$total_apps" ]; then
                SELECTED_INDICES+=("$idx")
            else
                print_warning "Number $token is out of range — skipping."
            fi
        else
            print_warning "'$token' is not a valid number — skipping."
        fi
    done

    if [ "${#SELECTED_INDICES[@]}" -eq 0 ]; then
        print_info "No valid selections. Skipping."
        return
    fi

    local sel_idx
    for sel_idx in "${SELECTED_INDICES[@]}"; do
        local app_name="${APP_NAMES[$sel_idx]}"
        local app_path="${APP_PATHS[$sel_idx]}"

        echo ""
        echo -e "  ${BOLD}${MAGENTA}── Uninstalling: ${app_name} ──${NC}"

        local bundle_id
        bundle_id=$(defaults read "$app_path/Contents/Info.plist" CFBundleIdentifier 2>/dev/null)

        if [ -z "$bundle_id" ]; then
            print_warning "Could not read bundle ID for $app_name. Will search by app name only."
        else
            print_info "Bundle ID: ${bundle_id}"
        fi

        local LEFTOVER_CANDIDATES=()

        if [ -n "$bundle_id" ]; then
            LEFTOVER_CANDIDATES+=(
                "$HOME/Library/Application Support/$bundle_id"
                "$HOME/Library/Preferences/${bundle_id}.plist"
                "$HOME/Library/Caches/$bundle_id"
                "$HOME/Library/Saved Application State/${bundle_id}.savedState"
                "$HOME/Library/Containers/$bundle_id"
                "$HOME/Library/WebKit/$bundle_id"
                "$HOME/Library/HTTPStorages/$bundle_id"
                "$HOME/Library/Cookies/${bundle_id}.binarycookies"
                "$HOME/Library/Logs/$bundle_id"
            )
        fi

        LEFTOVER_CANDIDATES+=(
            "$HOME/Library/Application Support/$app_name"
            "$HOME/Library/Caches/$app_name"
            "$HOME/Library/Logs/$app_name"
        )

        local GLOB_FOUND=()

        if [ -n "$bundle_id" ]; then
            local pref_glob
            for pref_glob in "$HOME/Library/Preferences/${bundle_id}".*.plist; do
                [ -e "$pref_glob" ] && GLOB_FOUND+=("$pref_glob")
            done

            local gc
            for gc in "$HOME/Library/Group Containers/"*"${bundle_id}"*; do
                [ -e "$gc" ] && GLOB_FOUND+=("$gc")
            done

            local la
            for la in "$HOME/Library/LaunchAgents/"*"${bundle_id}"*.plist; do
                [ -e "$la" ] && GLOB_FOUND+=("$la")
            done
        fi

        local FOUND_LEFTOVERS=()
        local total_leftover_bytes=0

        local candidate
        for candidate in "${LEFTOVER_CANDIDATES[@]}"; do
            if [ -e "$candidate" ]; then
                FOUND_LEFTOVERS+=("$candidate")
                if [ -d "$candidate" ]; then
                    local sz
                    sz=$(du -sk "$candidate" 2>/dev/null | awk '{print $1 * 1024}')
                    total_leftover_bytes=$((total_leftover_bytes + sz))
                elif [ -f "$candidate" ]; then
                    local fsz
                    fsz=$(stat -f%z "$candidate" 2>/dev/null)
                    [ -n "$fsz" ] && total_leftover_bytes=$((total_leftover_bytes + fsz))
                fi
            fi
        done

        local gf
        for gf in "${GLOB_FOUND[@]}"; do
            FOUND_LEFTOVERS+=("$gf")
            if [ -d "$gf" ]; then
                local gsz
                gsz=$(du -sk "$gf" 2>/dev/null | awk '{print $1 * 1024}')
                total_leftover_bytes=$((total_leftover_bytes + gsz))
            elif [ -f "$gf" ]; then
                local gfsz
                gfsz=$(stat -f%z "$gf" 2>/dev/null)
                [ -n "$gfsz" ] && total_leftover_bytes=$((total_leftover_bytes + gfsz))
            fi
        done

        local leftover_count=${#FOUND_LEFTOVERS[@]}
        local leftover_human
        leftover_human=$(human_size "$total_leftover_bytes")

        if [ "$leftover_count" -gt 0 ]; then
            echo ""
            print_info "Found ${leftover_count} leftover item(s) (${leftover_human}):"
            local lf
            for lf in "${FOUND_LEFTOVERS[@]}"; do
                echo -e "    ${DIM}${lf}${NC}"
            done
        else
            print_info "No leftover files found in standard locations."
        fi

        echo ""
        local app_size_human
        app_size_human=$(human_size "${APP_SIZES[$sel_idx]}")
        echo -e "  ${YELLOW}Will move to Trash:${NC}"
        echo -e "    ${DIM}${app_path}${NC}  (${app_size_human})"
        if [ "$leftover_count" -gt 0 ]; then
            local lf2
            for lf2 in "${FOUND_LEFTOVERS[@]}"; do
                echo -e "    ${DIM}${lf2}${NC}"
            done
        fi
        echo ""
        printf "  Proceed? (y/n): "
        local confirm
        read -r confirm

        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            print_info "Skipped $app_name."
            continue
        fi

        local removed_count=0
        local removed_bytes=0

        if mv "$app_path" "$HOME/.Trash/" 2>/dev/null; then
            removed_bytes=$((removed_bytes + APP_SIZES[$sel_idx]))
            removed_count=$((removed_count + 1))
        else
            print_warning "Could not move $app_path to Trash (may need sudo or app is running)."
        fi

        local lf3
        for lf3 in "${FOUND_LEFTOVERS[@]}"; do
            if [ -e "$lf3" ]; then
                mv "$lf3" "$HOME/.Trash/" 2>/dev/null && removed_count=$((removed_count + 1))
            fi
        done

        local removed_human
        removed_human=$(human_size "$removed_bytes")
        print_good "Removed ${app_name}: ${removed_count} item(s) moved to Trash (~${removed_human} freed)"
        TOTAL_RECLAIMABLE_BYTES=$((TOTAL_RECLAIMABLE_BYTES + removed_bytes))
        ALL_RECOMMENDATIONS+=("Empty the Trash to permanently free space reclaimed from ${app_name}.")
    done

    echo ""
    print_info "Done. Remember to empty the Trash to permanently free disk space."
}

# ============================================================================
# 17. PRIVACY CLEANUP
# ============================================================================

cleanup_privacy() {
    print_header "PRIVACY CLEANUP"

    echo ""
    print_info "Scanning for privacy-sensitive data..."
    echo ""

    _sum_path_sizes() {
        local total=0
        local p
        for p in "$@"; do
            if [ -d "$p" ]; then
                local s
                s=$(du -sk "$p" 2>/dev/null | awk '{print $1 * 1024}')
                [ -n "$s" ] && total=$((total + s))
            elif [ -f "$p" ]; then
                local s
                s=$(stat -f%z "$p" 2>/dev/null)
                [ -n "$s" ] && total=$((total + s))
            fi
        done
        echo "$total"
    }

    local BROWSER_LABELS=()
    local BROWSER_PATHS=()
    local BROWSER_SIZES=()

    # Safari
    local safari_paths=()
    [ -f "$HOME/Library/Safari/History.db" ] && safari_paths+=("$HOME/Library/Safari/History.db")
    [ -f "$HOME/Library/Safari/History.db-wal" ] && safari_paths+=("$HOME/Library/Safari/History.db-wal")
    [ -f "$HOME/Library/Safari/History.db-shm" ] && safari_paths+=("$HOME/Library/Safari/History.db-shm")
    [ -f "$HOME/Library/Cookies/Cookies.binarycookies" ] && safari_paths+=("$HOME/Library/Cookies/Cookies.binarycookies")
    [ -d "$HOME/Library/Safari/LocalStorage" ] && safari_paths+=("$HOME/Library/Safari/LocalStorage")
    if [ "${#safari_paths[@]}" -gt 0 ]; then
        local safari_size
        safari_size=$(_sum_path_sizes "${safari_paths[@]}")
        BROWSER_LABELS+=("Safari (history + cookies)")
        local joined_safari
        joined_safari=$(printf '%s|' "${safari_paths[@]}")
        BROWSER_PATHS+=("$joined_safari")
        BROWSER_SIZES+=("$safari_size")
    fi

    # Chrome
    local chrome_base="$HOME/Library/Application Support/Google/Chrome/Default"
    local chrome_paths=()
    [ -f "$chrome_base/History" ] && chrome_paths+=("$chrome_base/History")
    [ -f "$chrome_base/Cookies" ] && chrome_paths+=("$chrome_base/Cookies")
    [ -d "$chrome_base/Local Storage" ] && chrome_paths+=("$chrome_base/Local Storage")
    [ -d "$chrome_base/Session Storage" ] && chrome_paths+=("$chrome_base/Session Storage")
    if [ "${#chrome_paths[@]}" -gt 0 ]; then
        local chrome_size
        chrome_size=$(_sum_path_sizes "${chrome_paths[@]}")
        BROWSER_LABELS+=("Google Chrome (history + cookies)")
        local joined_chrome
        joined_chrome=$(printf '%s|' "${chrome_paths[@]}")
        BROWSER_PATHS+=("$joined_chrome")
        BROWSER_SIZES+=("$chrome_size")
    fi

    # Firefox
    local ff_base="$HOME/Library/Application Support/Firefox/Profiles"
    local firefox_paths=()
    if [ -d "$ff_base" ]; then
        local ff_profile
        for ff_profile in "$ff_base"/*/; do
            [ -f "${ff_profile}places.sqlite" ] && firefox_paths+=("${ff_profile}places.sqlite")
            [ -f "${ff_profile}cookies.sqlite" ] && firefox_paths+=("${ff_profile}cookies.sqlite")
        done
    fi
    if [ "${#firefox_paths[@]}" -gt 0 ]; then
        local ff_size
        ff_size=$(_sum_path_sizes "${firefox_paths[@]}")
        BROWSER_LABELS+=("Firefox (history + cookies)")
        local joined_ff
        joined_ff=$(printf '%s|' "${firefox_paths[@]}")
        BROWSER_PATHS+=("$joined_ff")
        BROWSER_SIZES+=("$ff_size")
    fi

    # Edge
    local edge_base="$HOME/Library/Application Support/Microsoft Edge/Default"
    local edge_paths=()
    [ -f "$edge_base/History" ] && edge_paths+=("$edge_base/History")
    [ -f "$edge_base/Cookies" ] && edge_paths+=("$edge_base/Cookies")
    [ -d "$edge_base/Local Storage" ] && edge_paths+=("$edge_base/Local Storage")
    if [ "${#edge_paths[@]}" -gt 0 ]; then
        local edge_size
        edge_size=$(_sum_path_sizes "${edge_paths[@]}")
        BROWSER_LABELS+=("Microsoft Edge (history + cookies)")
        local joined_edge
        joined_edge=$(printf '%s|' "${edge_paths[@]}")
        BROWSER_PATHS+=("$joined_edge")
        BROWSER_SIZES+=("$edge_size")
    fi

    # Arc
    local arc_base="$HOME/Library/Application Support/Arc/User Data/Default"
    local arc_paths=()
    [ -f "$arc_base/History" ] && arc_paths+=("$arc_base/History")
    [ -f "$arc_base/Cookies" ] && arc_paths+=("$arc_base/Cookies")
    [ -d "$arc_base/Local Storage" ] && arc_paths+=("$arc_base/Local Storage")
    if [ "${#arc_paths[@]}" -gt 0 ]; then
        local arc_size
        arc_size=$(_sum_path_sizes "${arc_paths[@]}")
        BROWSER_LABELS+=("Arc (history + cookies)")
        local joined_arc
        joined_arc=$(printf '%s|' "${arc_paths[@]}")
        BROWSER_PATHS+=("$joined_arc")
        BROWSER_SIZES+=("$arc_size")
    fi

    # Brave
    local brave_base="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/Default"
    local brave_paths=()
    [ -f "$brave_base/History" ] && brave_paths+=("$brave_base/History")
    [ -f "$brave_base/Cookies" ] && brave_paths+=("$brave_base/Cookies")
    [ -d "$brave_base/Local Storage" ] && brave_paths+=("$brave_base/Local Storage")
    if [ "${#brave_paths[@]}" -gt 0 ]; then
        local brave_size
        brave_size=$(_sum_path_sizes "${brave_paths[@]}")
        BROWSER_LABELS+=("Brave (history + cookies)")
        local joined_brave
        joined_brave=$(printf '%s|' "${brave_paths[@]}")
        BROWSER_PATHS+=("$joined_brave")
        BROWSER_SIZES+=("$brave_size")
    fi

    local browser_count=${#BROWSER_LABELS[@]}

    # Recent Items
    local recent_items_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    local recent_size=0
    local recent_available=0
    if [ -d "$recent_items_dir" ]; then
        recent_size=$(_sum_path_sizes "$recent_items_dir")
        recent_available=1
    fi

    # Siri Suggestions
    local siri_dir="$HOME/Library/Suggestions"
    local siri_size=0
    local siri_available=0
    if [ -d "$siri_dir" ]; then
        siri_size=$(_sum_path_sizes "$siri_dir")
        siri_available=1
    fi

    # Quick Look Cache
    local ql_dir="$HOME/Library/Caches/com.apple.QuickLookDaemon"
    local ql_size=0
    local ql_available=0
    if [ -d "$ql_dir" ]; then
        ql_size=$(_sum_path_sizes "$ql_dir")
        ql_available=1
    fi
    ql_available=1

    # Wi-Fi count (info only)
    local wifi_count=0
    local wifi_list
    wifi_list=$(networksetup -listpreferredwirelessnetworks en0 2>/dev/null | tail -n +2 | grep -v "^$")
    wifi_count=$(echo "$wifi_list" | grep -c . 2>/dev/null)
    [ -z "$wifi_count" ] && wifi_count=0

    # Display menu
    print_section "What can be cleaned:"
    echo ""

    local MENU_LABELS=()
    local MENU_TYPES=()
    local MENU_SIZES=()
    local menu_num=1

    local bi=0
    while [ "$bi" -lt "$browser_count" ]; do
        local bh
        bh=$(human_size "${BROWSER_SIZES[$bi]}")
        printf "  ${CYAN}%3d)${NC}  %-50s  ${YELLOW}%s${NC}\n" \
            "$menu_num" "${BROWSER_LABELS[$bi]}" "$bh"
        MENU_LABELS+=("${BROWSER_LABELS[$bi]}")
        MENU_TYPES+=("browser_${bi}")
        MENU_SIZES+=("${BROWSER_SIZES[$bi]}")
        menu_num=$((menu_num + 1))
        bi=$((bi + 1))
    done

    if [ "$recent_available" -eq 1 ]; then
        local rh
        rh=$(human_size "$recent_size")
        printf "  ${CYAN}%3d)${NC}  %-50s  ${YELLOW}%s${NC}\n" \
            "$menu_num" "Recent Items (open recent menus)" "$rh"
        MENU_LABELS+=("Recent Items")
        MENU_TYPES+=("recent")
        MENU_SIZES+=("$recent_size")
        menu_num=$((menu_num + 1))
    fi

    if [ "$siri_available" -eq 1 ]; then
        local sh
        sh=$(human_size "$siri_size")
        printf "  ${CYAN}%3d)${NC}  %-50s  ${YELLOW}%s${NC}\n" \
            "$menu_num" "Siri Suggestions Data" "$sh"
        MENU_LABELS+=("Siri Suggestions")
        MENU_TYPES+=("siri")
        MENU_SIZES+=("$siri_size")
        menu_num=$((menu_num + 1))
    fi

    if [ "$ql_available" -eq 1 ]; then
        local qlh
        qlh=$(human_size "$ql_size")
        printf "  ${CYAN}%3d)${NC}  %-50s  ${YELLOW}%s${NC}\n" \
            "$menu_num" "Quick Look Cache" "$qlh"
        MENU_LABELS+=("Quick Look Cache")
        MENU_TYPES+=("ql")
        MENU_SIZES+=("$ql_size")
        menu_num=$((menu_num + 1))
    fi

    echo ""
    echo -e "  ${DIM}  (info)${NC}  Saved Wi-Fi networks: ${BOLD}${wifi_count}${NC} network(s) stored"
    echo -e "  ${DIM}          Managed via System Settings > Wi-Fi > Known Networks.${NC}"

    local total_menu_items=${#MENU_LABELS[@]}

    if [ "$total_menu_items" -eq 0 ]; then
        echo ""
        print_good "Nothing to clean — no privacy data found."
        return
    fi

    echo ""
    echo -e "  ${DIM}Enter numbers (e.g. 1,3), 'all' to clean everything, or 'skip':${NC}"
    printf "  > "
    local selection
    read -r selection

    if [ -z "$selection" ] || [ "$selection" = "skip" ]; then
        print_info "Skipping privacy cleanup."
        return
    fi

    local SELECTED=()
    if [ "$selection" = "all" ]; then
        local k=0
        while [ "$k" -lt "$total_menu_items" ]; do
            SELECTED+=("$k")
            k=$((k + 1))
        done
    else
        local token
        local sel_spaced
        sel_spaced=$(echo "$selection" | tr ',' ' ')
        for token in $sel_spaced; do
            if echo "$token" | grep -qE '^[0-9]+$'; then
                local idx=$((token - 1))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "$total_menu_items" ]; then
                    SELECTED+=("$idx")
                else
                    print_warning "Number $token is out of range — skipping."
                fi
            else
                print_warning "'$token' is not a valid number — skipping."
            fi
        done
    fi

    if [ "${#SELECTED[@]}" -eq 0 ]; then
        print_info "No valid selections. Skipping."
        return
    fi

    # Browser warning gate
    local browser_selected=0
    local sidx
    for sidx in "${SELECTED[@]}"; do
        local mtype="${MENU_TYPES[$sidx]}"
        if echo "$mtype" | grep -q "^browser_"; then
            browser_selected=1
            break
        fi
    done

    if [ "$browser_selected" -eq 1 ]; then
        echo ""
        echo -e "  ${RED}${BOLD}WARNING:${NC} ${YELLOW}Clearing browser history and cookies will log you out of all websites.${NC}"
        echo -e "  ${YELLOW}You will need to re-enter passwords for every site.${NC}"
        echo ""
        printf "  Are you sure you want to continue? (yes/no): "
        local bconfirm
        read -r bconfirm
        if [ "$bconfirm" != "yes" ] && [ "$bconfirm" != "y" ]; then
            local NEW_SELECTED=()
            for sidx in "${SELECTED[@]}"; do
                if ! echo "${MENU_TYPES[$sidx]}" | grep -q "^browser_"; then
                    NEW_SELECTED+=("$sidx")
                fi
            done
            SELECTED=("${NEW_SELECTED[@]}")
            print_info "Browser cleanup cancelled. Continuing with other selections."
        fi
    fi

    echo ""
    local total_freed=0

    for sidx in "${SELECTED[@]}"; do
        local label="${MENU_LABELS[$sidx]}"
        local mtype="${MENU_TYPES[$sidx]}"

        echo -e "  ${BOLD}Cleaning: ${label}${NC}"

        case "$mtype" in
            browser_*)
                local bidx
                bidx=$(echo "$mtype" | sed 's/browser_//')
                local raw_paths="${BROWSER_PATHS[$bidx]}"
                local bpath
                local freed_this=0
                local old_IFS="$IFS"
                IFS='|'
                for bpath in $raw_paths; do
                    IFS="$old_IFS"
                    [ -z "$bpath" ] && continue
                    if [ -e "$bpath" ]; then
                        local psz=0
                        if [ -d "$bpath" ]; then
                            psz=$(du -sk "$bpath" 2>/dev/null | awk '{print $1 * 1024}')
                        else
                            psz=$(stat -f%z "$bpath" 2>/dev/null)
                        fi
                        [ -z "$psz" ] && psz=0
                        mv "$bpath" "$HOME/.Trash/" 2>/dev/null && \
                            freed_this=$((freed_this + psz))
                    fi
                done
                IFS="$old_IFS"
                total_freed=$((total_freed + freed_this))
                print_good "Cleared ${label} (~$(human_size "$freed_this") moved to Trash)"
                ;;
            recent)
                osascript -e 'tell application "System Events" to delete every recent item of every recent items folder' 2>/dev/null
                local ritem
                for ritem in "$recent_items_dir"/*.sfl2 "$recent_items_dir"/*.sfl; do
                    [ -e "$ritem" ] && mv "$ritem" "$HOME/.Trash/" 2>/dev/null
                done
                total_freed=$((total_freed + recent_size))
                print_good "Cleared Recent Items (~$(human_size "$recent_size") moved to Trash)"
                ;;
            siri)
                if [ -d "$siri_dir" ]; then
                    mv "$siri_dir" "$HOME/.Trash/" 2>/dev/null && \
                        print_good "Cleared Siri Suggestions Data (~$(human_size "$siri_size") moved to Trash)" || \
                        print_warning "Could not move Siri Suggestions to Trash."
                    total_freed=$((total_freed + siri_size))
                fi
                ;;
            ql)
                if [ -d "$ql_dir" ]; then
                    mv "$ql_dir" "$HOME/.Trash/" 2>/dev/null
                    total_freed=$((total_freed + ql_size))
                fi
                qlmanage -r cache 2>/dev/null
                print_good "Cleared Quick Look Cache (~$(human_size "$ql_size") moved to Trash, system cache reset)"
                ;;
            *)
                print_warning "Unknown cleanup type: $mtype"
                ;;
        esac
    done

    echo ""
    if [ "$total_freed" -gt 0 ]; then
        print_good "Privacy cleanup complete. Total moved to Trash: $(human_size "$total_freed")"
        TOTAL_RECLAIMABLE_BYTES=$((TOTAL_RECLAIMABLE_BYTES + total_freed))
        ALL_RECOMMENDATIONS+=("Empty the Trash to permanently free space from privacy cleanup.")
    else
        print_info "Privacy cleanup complete. No data was removed."
    fi
    print_info "Remember to empty the Trash to permanently reclaim disk space."
}

# ============================================================================
# 18. SYSTEM MAINTENANCE
# ============================================================================

run_maintenance() {
    print_header "SYSTEM MAINTENANCE"

    echo ""
    echo -e "  ${DIM}These are built-in macOS maintenance tasks. No third-party tools needed.${NC}"
    echo ""

    local tm_snapshots=""
    tm_snapshots=$(tmutil listlocalsnapshots / 2>/dev/null)
    local has_tm_snapshots=0
    [ -n "$tm_snapshots" ] && has_tm_snapshots=1

    local mail_glob
    mail_glob=$(ls -d ~/Library/Mail/V*/MailData/Envelope\ Index 2>/dev/null | head -1)
    local has_mail=0
    [ -n "$mail_glob" ] && has_mail=1

    echo -e "  ${BOLD}Available maintenance tasks:${NC}"
    echo ""
    echo -e "  ${CYAN}1.${NC} ${BOLD}Run Periodic Scripts${NC} ${DIM}[requires admin]${NC}"
    echo -e "     Rotates logs, rebuilds databases, cleans temp files"
    echo ""
    echo -e "  ${CYAN}2.${NC} ${BOLD}Rebuild Spotlight Index${NC} ${DIM}[requires admin]${NC}"
    echo -e "     Fixes slow or broken Spotlight search"
    echo ""
    echo -e "  ${CYAN}3.${NC} ${BOLD}Rebuild Launch Services${NC}"
    echo -e "     Fixes duplicate 'Open With' menu entries"
    echo ""
    echo -e "  ${CYAN}4.${NC} ${BOLD}Clear Font Cache${NC} ${DIM}[requires admin]${NC}"
    echo -e "     Fixes font rendering glitches and corruption"
    echo ""

    if [ "$has_mail" -eq 1 ]; then
        echo -e "  ${CYAN}5.${NC} ${BOLD}Speed Up Mail${NC}"
        echo -e "     Reindexes Mail database for faster search"
        echo ""
    fi

    echo -e "  ${CYAN}6.${NC} ${BOLD}Free Purgeable Space${NC}"
    echo -e "     Triggers macOS to release purgeable disk space"
    echo ""

    if [ "$has_tm_snapshots" -eq 1 ]; then
        echo -e "  ${CYAN}7.${NC} ${BOLD}Thin Time Machine Snapshots${NC}"
        echo -e "     Frees space by trimming local Time Machine snapshots"
        echo ""
    fi

    echo -e "  ${CYAN}8.${NC} ${BOLD}Flush DNS Cache${NC} ${DIM}[requires admin]${NC}"
    echo -e "     Clears stale DNS entries; fixes site-not-found errors"
    echo ""

    echo -e "  ${DIM}Tasks marked [requires admin] will prompt for your password.${NC}"
    echo ""
    printf "  Enter numbers (e.g. 1,3,5), 'all', or 'skip': "
    local selection
    read -r selection

    if [ -z "$selection" ] || [ "$selection" = "skip" ]; then
        print_info "Skipping maintenance tasks."
        return
    fi

    if [ "$selection" = "all" ]; then
        selection="1,2,3,4,6,8"
        [ "$has_mail" -eq 1 ] && selection="${selection},5"
        [ "$has_tm_snapshots" -eq 1 ] && selection="${selection},7"
    fi

    local tasks
    tasks=$(echo "$selection" | tr ' ' ',' | tr ',' '\n' | sort -un | tr '\n' ' ')

    echo ""
    print_section "RUNNING SELECTED TASKS"

    _maint_run() {
        local task="$1"
        case "$task" in
            1)
                echo -e "\n  ${BOLD}[1/8] Running periodic maintenance scripts...${NC}"
                print_info "This runs daily, weekly, and monthly maintenance (may take a minute)..."
                if sudo periodic daily weekly monthly 2>/dev/null; then
                    print_good "Periodic scripts completed"
                else
                    print_warning "Periodic scripts failed or were cancelled"
                    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                fi
                ;;
            2)
                echo -e "\n  ${BOLD}[2/8] Rebuilding Spotlight index...${NC}"
                print_info "Spotlight will be unavailable for a few minutes while it reindexes..."
                if sudo mdutil -E / 2>/dev/null; then
                    print_good "Spotlight index rebuild initiated"
                    print_info "Reindexing happens in the background — Spotlight will be slow briefly"
                else
                    print_warning "Spotlight rebuild failed or requires admin access"
                    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                fi
                ;;
            3)
                echo -e "\n  ${BOLD}[3/8] Rebuilding Launch Services database...${NC}"
                print_info "Clearing 'Open With' duplicates..."
                local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                if [ -x "$lsregister" ]; then
                    if "$lsregister" -kill -r -domain local -domain system -domain user 2>/dev/null; then
                        print_good "Launch Services database rebuilt"
                        print_info "Log out and back in for 'Open With' menus to refresh"
                    else
                        print_warning "Launch Services rebuild encountered an error"
                        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                    fi
                else
                    print_warning "lsregister not found — skipping"
                    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                fi
                ;;
            4)
                echo -e "\n  ${BOLD}[4/8] Clearing font cache...${NC}"
                print_info "Removing corrupted font caches (requires admin)..."
                local font_ok=1
                sudo atsutil databases -remove 2>/dev/null || font_ok=0
                sudo atsutil server -shutdown 2>/dev/null
                sudo atsutil server -ping 2>/dev/null
                if [ "$font_ok" -eq 1 ]; then
                    print_good "Font cache cleared"
                    print_info "A restart may be needed for all font changes to take effect"
                else
                    print_warning "Font cache clear failed or requires admin access"
                    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                fi
                ;;
            5)
                echo -e "\n  ${BOLD}[5/8] Optimizing Mail database...${NC}"
                if [ "$has_mail" -eq 0 ]; then
                    print_info "No Mail data found — skipping"
                    return
                fi
                print_info "Running VACUUM on Mail Envelope Index (may take a moment)..."
                local mail_db
                mail_db=$(ls ~/Library/Mail/V*/MailData/Envelope\ Index 2>/dev/null | head -1)
                if [ -n "$mail_db" ] && [ -f "$mail_db" ]; then
                    if sqlite3 "$mail_db" vacuum 2>/dev/null; then
                        print_good "Mail database optimized"
                    else
                        print_warning "Mail database optimization failed (Mail may be open — close it first)"
                        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                    fi
                else
                    print_info "Mail Envelope Index not found — skipping"
                fi
                ;;
            6)
                echo -e "\n  ${BOLD}[6/8] Freeing purgeable disk space...${NC}"
                print_info "Writing and deleting a 1 GB temp file to trigger purgeable space release..."
                dd if=/dev/zero of=/tmp/mhc_purgeable bs=1m count=1024 2>/dev/null
                local dd_exit=$?
                rm -f /tmp/mhc_purgeable 2>/dev/null
                if [ "$dd_exit" -eq 0 ]; then
                    print_good "Purgeable space trigger complete"
                    print_info "macOS will reclaim purgeable space over the next few minutes"
                else
                    print_warning "Purgeable space trigger may not have completed fully"
                    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                fi
                ;;
            7)
                echo -e "\n  ${BOLD}[7/8] Thinning Time Machine local snapshots...${NC}"
                if [ "$has_tm_snapshots" -eq 0 ]; then
                    print_info "No local Time Machine snapshots found — skipping"
                    return
                fi
                print_info "Requesting macOS to thin local snapshots..."
                local snap_date
                snap_date=$(date +%Y%m%d%H%M%S)
                tmutil thinlocalsnapshots / "$snap_date" 1 2>/dev/null
                local thin_exit=$?
                if [ "$thin_exit" -eq 0 ]; then
                    print_good "Time Machine snapshot thinning requested"
                    print_info "macOS will reclaim space in the background"
                else
                    print_warning "Snapshot thinning returned an error (snapshots may already be minimal)"
                    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                fi
                ;;
            8)
                echo -e "\n  ${BOLD}[8/8] Flushing DNS cache...${NC}"
                print_info "Clearing stale DNS entries (requires admin)..."
                local dns_ok=1
                sudo dscacheutil -flushcache 2>/dev/null || dns_ok=0
                sudo killall -HUP mDNSResponder 2>/dev/null || dns_ok=0
                if [ "$dns_ok" -eq 1 ]; then
                    print_good "DNS cache flushed"
                else
                    print_warning "DNS flush failed or requires admin access"
                    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                fi
                ;;
            *)
                print_info "Unknown task number: $task — skipping"
                ;;
        esac
    }

    for task in $tasks; do
        if [ "$task" -eq 5 ] && [ "$has_mail" -eq 0 ] 2>/dev/null; then
            print_info "Task 5 (Speed Up Mail): No Mail data found — skipping"
            continue
        fi
        if [ "$task" -eq 7 ] && [ "$has_tm_snapshots" -eq 0 ] 2>/dev/null; then
            print_info "Task 7 (Thin TM Snapshots): No snapshots found — skipping"
            continue
        fi
        _maint_run "$task"
    done

    echo ""
    print_good "Maintenance tasks complete."
    echo ""
}

# ============================================================================
# 19. HARDWARE MONITOR
# ============================================================================

check_hardware() {
    print_header "HARDWARE MONITOR"

    local ARCH
    ARCH=$(uname -m)
    local is_apple_silicon=0
    [ "$ARCH" = "arm64" ] && is_apple_silicon=1

    # CPU Temperature
    print_section "CPU TEMPERATURE"

    local cpu_temp_c=""

    if [ -z "$cpu_temp_c" ]; then
        local pm_out
        pm_out=$(sudo powermetrics --samplers smc -n 1 -i 1 2>/dev/null | grep "CPU die temperature")
        if [ -n "$pm_out" ]; then
            cpu_temp_c=$(echo "$pm_out" | grep -o '[0-9]*\.[0-9]*' | head -1)
        fi
    fi

    if [ -z "$cpu_temp_c" ]; then
        local ioreg_temp
        ioreg_temp=$(ioreg -rn AppleSMC 2>/dev/null | grep -E '"TC0[PD]"' | grep -o '[0-9]\{4,6\}' | head -1)
        if [ -n "$ioreg_temp" ] && [ "$ioreg_temp" -gt 0 ] 2>/dev/null; then
            if [ "$ioreg_temp" -gt 1000 ] 2>/dev/null; then
                cpu_temp_c=$(echo "scale=1; $ioreg_temp / 100" | bc 2>/dev/null)
            else
                cpu_temp_c="$ioreg_temp"
            fi
        fi
    fi

    if [ -z "$cpu_temp_c" ] && [ "$is_apple_silicon" -eq 0 ]; then
        local thermal_level
        thermal_level=$(sysctl machdep.xcpm.cpu_thermal_level 2>/dev/null | awk '{print $2}')
        if [ -n "$thermal_level" ]; then
            print_info "CPU thermal level (Intel proxy): ${BOLD}${thermal_level}%${NC}"
            if [ "$thermal_level" -eq 0 ] 2>/dev/null; then
                print_good "No thermal throttling detected"
            elif [ "$thermal_level" -ge 50 ] 2>/dev/null; then
                print_bad "CPU is thermally throttling at ${thermal_level}%"
                TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
                ALL_RECOMMENDATIONS+=("CPU is throttling due to heat. Ensure vents are clear and consider cleaning internal fans.")
            else
                print_warning "Mild CPU thermal throttling at ${thermal_level}%"
                TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
            fi
        fi
    fi

    if [ -n "$cpu_temp_c" ]; then
        local temp_int
        temp_int=$(echo "$cpu_temp_c" | awk -F'.' '{print $1}')
        local temp_f
        temp_f=$(echo "scale=1; $cpu_temp_c * 9 / 5 + 32" | bc 2>/dev/null)

        if [ "$temp_int" -lt 60 ] 2>/dev/null; then
            print_good "CPU temperature: ${BOLD}${cpu_temp_c}°C / ${temp_f}°F${NC} — Excellent"
        elif [ "$temp_int" -lt 75 ] 2>/dev/null; then
            print_good "CPU temperature: ${BOLD}${cpu_temp_c}°C / ${temp_f}°F${NC} — Normal"
        elif [ "$temp_int" -lt 85 ] 2>/dev/null; then
            print_warning "CPU temperature: ${BOLD}${cpu_temp_c}°C / ${temp_f}°F${NC} — Warm"
            print_info "Consider closing heavy apps or checking for dust in vents"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        else
            print_bad "CPU temperature: ${BOLD}${cpu_temp_c}°C / ${temp_f}°F${NC} — Hot / Throttling likely"
            print_info "Check for runaway processes and ensure vents are not blocked"
            TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
            ALL_RECOMMENDATIONS+=("CPU is running very hot (${cpu_temp_c}°C). Check for runaway processes, clear vents, and let the Mac cool down.")
        fi
    else
        print_info "Temperature monitoring requires admin access (run with sudo for full data)"
        print_info "Try: sudo powermetrics --samplers smc -n 1 -i 1 | grep 'CPU die temperature'"
    fi

    # Fan Speed
    print_section "FAN SPEED"

    local fan_rpm=""

    if [ -z "$fan_rpm" ]; then
        local fan_pm_out
        fan_pm_out=$(sudo powermetrics --samplers smc -n 1 -i 1 2>/dev/null | grep -i "Fan")
        if [ -n "$fan_pm_out" ]; then
            fan_rpm=$(echo "$fan_pm_out" | grep -o '[0-9]\{3,5\}' | head -1)
        fi
    fi

    if [ -z "$fan_rpm" ]; then
        local ioreg_fan
        ioreg_fan=$(ioreg -rn AppleSMC 2>/dev/null | grep '"F0Ac"' | grep -o '[0-9]\{2,6\}' | head -1)
        if [ -n "$ioreg_fan" ] && [ "$ioreg_fan" -gt 0 ] 2>/dev/null; then
            if [ "$ioreg_fan" -gt 20000 ] 2>/dev/null; then
                fan_rpm=$(echo "scale=0; $ioreg_fan / 4" | bc 2>/dev/null)
            else
                fan_rpm="$ioreg_fan"
            fi
        fi
    fi

    if [ -n "$fan_rpm" ] && [ "$fan_rpm" -gt 0 ] 2>/dev/null; then
        if [ "$fan_rpm" -lt 2000 ] 2>/dev/null; then
            print_good "Fan speed: ${BOLD}${fan_rpm} RPM${NC} — Quiet"
        elif [ "$fan_rpm" -lt 4000 ] 2>/dev/null; then
            print_good "Fan speed: ${BOLD}${fan_rpm} RPM${NC} — Normal"
        elif [ "$fan_rpm" -lt 6000 ] 2>/dev/null; then
            print_warning "Fan speed: ${BOLD}${fan_rpm} RPM${NC} — Running high"
            print_info "Mac is working hard — check for heavy processes"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        else
            print_bad "Fan speed: ${BOLD}${fan_rpm} RPM${NC} — Very high / near maximum"
            print_info "High heat load detected. Check for runaway processes."
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
            ALL_RECOMMENDATIONS+=("Fans are running at very high speed (${fan_rpm} RPM). Investigate heavy CPU processes and check vents.")
        fi
    else
        if [ "$is_apple_silicon" -eq 1 ]; then
            print_info "Fan data not exposed via SMC on this Apple Silicon Mac"
            print_info "Apple Silicon Macs manage thermals passively or with firmware-controlled fans"
        else
            print_info "Fan speed data unavailable (try running with sudo for powermetrics access)"
        fi
    fi

    # GPU & Display
    print_section "GPU & DISPLAY"

    local gpu_data
    gpu_data=$(system_profiler SPDisplaysDataType 2>/dev/null)

    if [ -n "$gpu_data" ]; then
        local gpu_model
        gpu_model=$(echo "$gpu_data" | grep "Chipset Model" | head -1 | awk -F': ' '{print $2}' | xargs)
        [ -n "$gpu_model" ] && print_info "GPU: ${BOLD}${gpu_model}${NC}"

        local vram
        vram=$(echo "$gpu_data" | grep "VRAM" | head -1 | awk -F': ' '{print $2}' | xargs)
        [ -n "$vram" ] && print_info "VRAM: ${vram}"

        local metal
        metal=$(echo "$gpu_data" | grep "Metal" | head -1 | awk -F': ' '{print $2}' | xargs)
        [ -n "$metal" ] && print_good "Metal: ${metal}"

        local display_count
        display_count=$(echo "$gpu_data" | grep -c "Resolution:")
        if [ "$display_count" -gt 0 ]; then
            print_info "Connected displays: ${BOLD}${display_count}${NC}"
            echo "$gpu_data" | grep "Resolution:" | while read -r res_line; do
                local res
                res=$(echo "$res_line" | awk -F': ' '{print $2}' | xargs)
                print_info "  Display: ${res}"
            done
        fi
    else
        print_info "GPU info unavailable"
    fi

    # Disk I/O
    print_section "DISK I/O"

    local io_line
    io_line=$(iostat -d 1 2 2>/dev/null | tail -1)

    if [ -n "$io_line" ]; then
        local kbt tps mbs
        kbt=$(echo "$io_line" | awk '{print $1}')
        tps=$(echo "$io_line" | awk '{print $2}')
        mbs=$(echo "$io_line" | awk '{print $3}')
        if [ -n "$mbs" ]; then
            print_info "Disk throughput (last 1s): ${BOLD}${mbs} MB/s${NC}  |  ${tps} transfers/s  |  ${kbt} KB/transfer"
            local mbs_int
            mbs_int=$(echo "$mbs" | awk -F'.' '{print $1}')
            if [ "$mbs_int" -ge 500 ] 2>/dev/null; then
                print_good "Disk I/O is excellent (SSD performing well)"
            elif [ "$mbs_int" -ge 100 ] 2>/dev/null; then
                print_good "Disk I/O is normal"
            elif [ "$mbs_int" -ge 1 ] 2>/dev/null; then
                print_info "Light disk activity"
            else
                print_info "Disk is mostly idle"
            fi
        fi
    else
        print_info "Disk I/O data unavailable"
    fi

    # USB Devices
    print_section "USB DEVICES"

    local usb_data
    usb_data=$(system_profiler SPUSBDataType 2>/dev/null)

    if [ -n "$usb_data" ]; then
        local usb_count
        usb_count=$(echo "$usb_data" | grep -c "Product ID:")
        print_info "USB devices detected: ${BOLD}${usb_count}${NC}"
    else
        print_info "No USB data available"
    fi

    # Bluetooth Devices
    print_section "BLUETOOTH DEVICES"

    local bt_data
    bt_data=$(system_profiler SPBluetoothDataType 2>/dev/null)

    if [ -n "$bt_data" ]; then
        local bt_state
        bt_state=$(echo "$bt_data" | grep "State:" | head -1 | awk -F': ' '{print $2}' | xargs)

        if [ "$bt_state" = "On" ] || [ -z "$bt_state" ]; then
            local bt_connected
            bt_connected=$(echo "$bt_data" | grep -B5 "Connected: Yes" | grep -E "^\s{4,8}[A-Za-z]" | grep -v "Connected\|Address\|Services" | sed 's/^[[:space:]]*//' | sed 's/:$//')
            if [ -n "$bt_connected" ]; then
                print_info "Connected Bluetooth devices:"
                echo "$bt_connected" | while IFS= read -r bt_name; do
                    [ -n "$bt_name" ] && print_good "  ${bt_name}"
                done
            else
                print_info "Bluetooth is on but no devices are connected"
            fi
        else
            print_info "Bluetooth is off"
        fi
    else
        print_info "Bluetooth data unavailable"
    fi
}

# ============================================================================
# 20. SYSTEM UPDATES & OPTIMIZATIONS
# ============================================================================

check_system_updates() {
    print_header "SYSTEM UPDATES & OPTIMIZATIONS"

    # macOS Software Update
    print_section "macOS UPDATE STATUS"

    local last_sw_check
    last_sw_check=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate LastSuccessfulDate 2>/dev/null)
    if [ -n "$last_sw_check" ]; then
        print_info "Last update check: ${BOLD}${last_sw_check}${NC}"
        local check_date
        check_date=$(echo "$last_sw_check" | awk '{print $1}')
        local today_stamp
        today_stamp=$(date +%Y-%m-%d)
        local days_since
        days_since=$(perl -e "
            use POSIX qw(floor);
            my (\$y1,\$m1,\$d1) = split('-','$check_date');
            my (\$y2,\$m2,\$d2) = split('-','$today_stamp');
            use Time::Local;
            my \$t1 = timelocal(0,0,12,\$d1,\$m1-1,\$y1-1900);
            my \$t2 = timelocal(0,0,12,\$d2,\$m2-1,\$y2-1900);
            print floor((\$t2-\$t1)/86400);
        " 2>/dev/null)
        if [ -n "$days_since" ]; then
            if [ "$days_since" -le 7 ] 2>/dev/null; then
                print_good "Update check is recent (${days_since} days ago)"
            elif [ "$days_since" -le 30 ] 2>/dev/null; then
                print_warning "Update check was ${days_since} days ago — consider running Software Update"
                TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
            else
                print_bad "Update check was ${days_since} days ago — updates may be overdue"
                TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
                ALL_RECOMMENDATIONS+=("macOS update check hasn't run in ${days_since} days. Open System Settings > General > Software Update.")
            fi
        fi
    else
        print_info "Could not determine last update check date"
    fi

    print_info "Checking for macOS updates (this may take 15-30 seconds)..."
    local sw_updates
    sw_updates=$(timeout 30 softwareupdate -l 2>/dev/null)
    local sw_exit=$?

    if [ "$sw_exit" -eq 124 ]; then
        print_warning "Software update check timed out — Apple servers may be slow"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
    elif echo "$sw_updates" | grep -q "No new software available" 2>/dev/null; then
        print_good "macOS is up to date"
    elif echo "$sw_updates" | grep -q "\*" 2>/dev/null; then
        local update_count
        update_count=$(echo "$sw_updates" | grep -c "^\*")
        print_bad "${update_count} macOS update(s) available:"
        echo "$sw_updates" | grep "Title:" | while IFS= read -r u_line; do
            local u_name
            u_name=$(echo "$u_line" | awk -F': ' '{print $2}' | xargs)
            print_info "  ${u_name}"
        done
        TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
        ALL_RECOMMENDATIONS+=("${update_count} macOS update(s) are available. Open System Settings > General > Software Update to install.")
    else
        print_info "Could not determine update status"
    fi

    # Homebrew Updates
    print_section "HOMEBREW PACKAGES"

    if command -v brew &>/dev/null; then
        print_info "Homebrew is installed — checking for outdated packages..."

        local brew_outdated
        brew_outdated=$(brew outdated 2>/dev/null)

        if [ -z "$brew_outdated" ]; then
            print_good "All Homebrew packages are up to date"
        else
            local brew_count
            brew_count=$(echo "$brew_outdated" | grep -c "." 2>/dev/null || echo "0")
            print_warning "${brew_count} outdated Homebrew package(s):"
            echo "$brew_outdated" | while IFS= read -r pkg_line; do
                [ -n "$pkg_line" ] && print_info "  ${pkg_line}"
            done
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
            ALL_RECOMMENDATIONS+=("${brew_count} Homebrew package(s) are outdated. Run 'brew upgrade' to update them.")
            echo ""
            printf "  Upgrade all Homebrew packages now? (y/n): "
            local brew_ans
            read -r brew_ans
            if [ "$brew_ans" = "y" ] || [ "$brew_ans" = "Y" ]; then
                print_info "Running 'brew upgrade'..."
                if brew upgrade 2>/dev/null; then
                    print_good "Homebrew packages upgraded successfully"
                else
                    print_warning "Some Homebrew packages may have failed to upgrade"
                    TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
                fi
            else
                print_info "Skipping Homebrew upgrade — run 'brew upgrade' when ready"
            fi
        fi
    else
        print_info "Homebrew is not installed — skipping"
        print_info "Install at: https://brew.sh"
    fi

    # Recommended System Settings
    print_section "RECOMMENDED SYSTEM SETTINGS"

    echo -e "  ${DIM}Checking your update and security settings...${NC}"
    echo ""

    local auto_check
    auto_check=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled 2>/dev/null)
    if [ "$auto_check" = "1" ]; then
        print_good "Automatic update checks: ${BOLD}Enabled${NC}"
    else
        print_warning "Automatic update checks: ${BOLD}Disabled${NC}"
        print_info "  Enable: System Settings > General > Software Update > Automatic updates"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        ALL_RECOMMENDATIONS+=("Automatic update checks are off. Enable them in System Settings > General > Software Update.")
    fi

    local auto_download
    auto_download=$(defaults read /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload 2>/dev/null)
    if [ "$auto_download" = "1" ]; then
        print_good "Automatic update downloads: ${BOLD}Enabled${NC}"
    else
        print_warning "Automatic update downloads: ${BOLD}Disabled${NC}"
        print_info "  Enable: System Settings > General > Software Update > Download updates automatically"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        ALL_RECOMMENDATIONS+=("Automatic update downloads are off. Enable them in System Settings > General > Software Update.")
    fi

    local as_auto_update
    as_auto_update=$(defaults read /Library/Preferences/com.apple.commerce AutoUpdate 2>/dev/null)
    if [ "$as_auto_update" = "1" ]; then
        print_good "App Store automatic updates: ${BOLD}Enabled${NC}"
    else
        print_warning "App Store automatic updates: ${BOLD}Disabled${NC}"
        print_info "  Enable: System Settings > General > Software Update > App updates"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        ALL_RECOMMENDATIONS+=("App Store automatic updates are off. Enable them in System Settings > General > Software Update.")
    fi

    local screen_lock_delay
    screen_lock_delay=$(defaults read com.apple.screensaver askForPasswordDelay 2>/dev/null)
    local screen_lock_enabled
    screen_lock_enabled=$(defaults read com.apple.screensaver askForPassword 2>/dev/null)

    if [ "$screen_lock_enabled" = "1" ]; then
        if [ -z "$screen_lock_delay" ] || [ "$screen_lock_delay" = "0" ] 2>/dev/null; then
            print_good "Screen lock: ${BOLD}Immediately on sleep${NC}"
        elif [ "$screen_lock_delay" -le 5 ] 2>/dev/null; then
            print_good "Screen lock: ${BOLD}After ${screen_lock_delay}s${NC}"
        else
            print_warning "Screen lock delay: ${BOLD}${screen_lock_delay} seconds${NC} — consider reducing to 5s or less"
            print_info "  Change: System Settings > Lock Screen > Require password"
            TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
            ALL_RECOMMENDATIONS+=("Screen lock is delayed ${screen_lock_delay}s after sleep. Reduce to 5s or less for better security.")
        fi
    else
        print_bad "Screen lock: ${BOLD}Disabled${NC} — screen does not require password after sleep"
        print_info "  Enable: System Settings > Lock Screen > Require password after sleep"
        TOTAL_PROBLEMS=$((TOTAL_PROBLEMS + 1))
        ALL_RECOMMENDATIONS+=("Screen lock is disabled. Enable it in System Settings > Lock Screen > Require password after sleep.")
    fi

    echo ""
    print_good "System settings check complete."
    echo ""
}

# ============================================================================
# FINAL SUMMARY
# ============================================================================

show_summary() {
    print_header "OVERALL HEALTH SUMMARY"
    echo ""

    if [ "$TOTAL_PROBLEMS" -eq 0 ] && [ "$TOTAL_WARNINGS" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}Your Mac is in great shape!${NC}"
        echo -e "  No problems or concerns detected."
    elif [ "$TOTAL_PROBLEMS" -eq 0 ]; then
        echo -e "  ${YELLOW}${BOLD}Your Mac is OK, with a few things to watch:${NC}"
    else
        echo -e "  ${RED}${BOLD}Your Mac has some issues that need attention:${NC}"
    fi

    if [ ${#ALL_RECOMMENDATIONS[@]} -gt 0 ]; then
        echo ""
        for rec in "${ALL_RECOMMENDATIONS[@]}"; do
            if echo "$rec" | grep -qi "critical\|replace\|immediately"; then
                echo -e "  ${RED}•${NC} $rec"
            elif echo "$rec" | grep -qi "consider\|watch\|should"; then
                echo -e "  ${YELLOW}•${NC} $rec"
            else
                echo -e "  ${BLUE}•${NC} $rec"
            fi
        done
    fi

    echo ""
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  Mac Health Checkup | $(date '+%Y-%m-%d %H:%M') | ${MAC_MODEL}${NC}"
    echo -e "${DIM}  Run again anytime: double-click Mac Health Checkup, or run:${NC}"
    echo -e "${DIM}  mac-checkup${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${DIM}Press Enter to exit...${NC}"
    read -r _
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    clear
    echo ""
    echo -e "${BOLD}  🩺 Mac Health Checkup${NC}"
    echo -e "${DIM}  Complete diagnostic for your Mac — battery, performance, storage, and more${NC}"
    echo -e "${DIM}  No AI, no internet, no accounts needed. 100% private & local.${NC}"

    show_system_info
    check_battery
    check_resource_hogs
    check_storage
    find_large_files
    find_duplicates
    check_stale_apps
    uninstall_apps
    check_startup
    run_cleanup
    cleanup_privacy
    run_maintenance
    check_hardware
    show_optimizations
    check_system_updates
    check_wifi
    check_backup
    check_security
    check_stats
    save_report
    show_summary
}

main "$@"
