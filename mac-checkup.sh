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
# 14. FINAL SUMMARY
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
    check_stale_apps
    check_startup
    run_cleanup
    show_optimizations
    check_wifi
    check_backup
    check_security
    check_stats
    save_report
    show_summary
}

main "$@"
