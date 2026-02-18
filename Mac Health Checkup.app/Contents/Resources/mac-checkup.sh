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

    MAC_MODEL=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Model Name" | awk -F': ' '{print $2}')
    MAC_CHIP=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Chip\|Processor Name" | head -1 | awk -F': ' '{print $2}')
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

    local mem_pressure
    mem_pressure=$(memory_pressure 2>/dev/null | grep "System-wide memory free percentage" | grep -o '[0-9]*')
    local pages_free=$(vm_stat 2>/dev/null | grep "Pages free" | awk '{print $3}' | tr -d '.')
    local pages_inactive=$(vm_stat 2>/dev/null | grep "Pages inactive" | awk '{print $3}' | tr -d '.')
    local pages_speculative=$(vm_stat 2>/dev/null | grep "Pages speculative" | awk '{print $3}' | tr -d '.')
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

    # Category arrays: name, path, size_bytes
    declare -a CLEAN_NAMES CLEAN_PATHS CLEAN_SIZES CLEAN_DESCRIPTIONS

    # 1. User caches
    local user_cache_size=$(dir_size_bytes "$HOME/Library/Caches")
    CLEAN_NAMES+=("App Caches")
    CLEAN_PATHS+=("$HOME/Library/Caches")
    CLEAN_SIZES+=("$user_cache_size")
    CLEAN_DESCRIPTIONS+=("Temporary data apps store to load faster. Safe to delete — apps rebuild them.")

    # 2. User logs
    local user_log_size=$(dir_size_bytes "$HOME/Library/Logs")
    CLEAN_NAMES+=("App Logs")
    CLEAN_PATHS+=("$HOME/Library/Logs")
    CLEAN_SIZES+=("$user_log_size")
    CLEAN_DESCRIPTIONS+=("Old log files from apps. Only useful for debugging — safe to delete.")

    # 3. Trash
    local trash_size=$(dir_size_bytes "$HOME/.Trash")
    CLEAN_NAMES+=("Trash")
    CLEAN_PATHS+=("$HOME/.Trash")
    CLEAN_SIZES+=("$trash_size")
    CLEAN_DESCRIPTIONS+=("Files you already deleted but haven't emptied yet.")

    # 4. Downloads older than 30 days
    local old_downloads_size=0
    if [ -d "$HOME/Downloads" ]; then
        old_downloads_size=$(find "$HOME/Downloads" -maxdepth 1 -type f -mtime +30 -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
    fi
    CLEAN_NAMES+=("Old Downloads (30+ days)")
    CLEAN_PATHS+=("DOWNLOADS_OLD")
    CLEAN_SIZES+=("$old_downloads_size")
    CLEAN_DESCRIPTIONS+=("Files in Downloads older than 30 days. Review before deleting.")

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

    # Store for cleanup phase
    export CLEAN_NAMES_STR=$(printf '%s\n' "${CLEAN_NAMES[@]}")
    export CLEAN_PATHS_STR=$(printf '%s\n' "${CLEAN_PATHS[@]}")
    export CLEAN_SIZES_STR=$(printf '%s\n' "${CLEAN_SIZES[@]}")
}

# ============================================================================
# 5. CLEANUP (Interactive)
# ============================================================================

run_cleanup() {
    print_header "CLEANUP"

    if [ "$TOTAL_RECLAIMABLE_BYTES" -lt 1048576 ] 2>/dev/null; then
        print_good "Nothing significant to clean up. You're all set!"
        return
    fi

    echo ""
    echo -e "  Would you like to clean up junk files?"
    echo ""
    echo -e "  ${BOLD}1.${NC} Quick clean — Caches, logs, and Trash ${DIM}(safest)${NC}"
    echo -e "  ${BOLD}2.${NC} Deep clean  — Everything above + browser caches, dev caches"
    echo -e "  ${BOLD}3.${NC} Full clean  — All of the above + old Downloads (30+ days)"
    echo -e "  ${BOLD}4.${NC} Skip        — Don't clean anything right now"
    echo ""
    read -p "  Choose (1-4): " clean_choice
    echo ""

    case "$clean_choice" in
        1)
            echo -e "  ${BOLD}Quick Clean — Clearing caches, logs, and Trash...${NC}"
            echo ""
            local freed=0

            # Clear user caches
            if [ -d "$HOME/Library/Caches" ]; then
                local before=$(dir_size_bytes "$HOME/Library/Caches")
                find "$HOME/Library/Caches" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
                local after=$(dir_size_bytes "$HOME/Library/Caches")
                local diff=$((before - after))
                [ "$diff" -gt 0 ] && freed=$((freed + diff))
                print_good "Cleared app caches ($(human_size $diff))"
            fi

            # Clear user logs
            if [ -d "$HOME/Library/Logs" ]; then
                local before=$(dir_size_bytes "$HOME/Library/Logs")
                find "$HOME/Library/Logs" -mindepth 1 -type f -mtime +7 -delete 2>/dev/null
                find "$HOME/Library/Logs" -mindepth 1 -type d -empty -delete 2>/dev/null
                local after=$(dir_size_bytes "$HOME/Library/Logs")
                local diff=$((before - after))
                [ "$diff" -gt 0 ] && freed=$((freed + diff))
                print_good "Cleared old logs ($(human_size $diff))"
            fi

            # Empty Trash
            if [ -d "$HOME/.Trash" ]; then
                local before=$(dir_size_bytes "$HOME/.Trash")
                rm -rf "$HOME/.Trash/"* 2>/dev/null
                rm -rf "$HOME/.Trash/".* 2>/dev/null
                freed=$((freed + before))
                print_good "Emptied Trash ($(human_size $before))"
            fi

            echo ""
            echo -e "  ${GREEN}${BOLD}Freed up ~$(human_size $freed)${NC}"
            ;;
        2)
            echo -e "  ${BOLD}Deep Clean — Clearing everything safe...${NC}"
            echo ""
            local freed=0

            # User caches
            if [ -d "$HOME/Library/Caches" ]; then
                local before=$(dir_size_bytes "$HOME/Library/Caches")
                find "$HOME/Library/Caches" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
                local after=$(dir_size_bytes "$HOME/Library/Caches")
                local diff=$((before - after))
                [ "$diff" -gt 0 ] && freed=$((freed + diff))
                print_good "Cleared app caches ($(human_size $diff))"
            fi

            # Logs
            if [ -d "$HOME/Library/Logs" ]; then
                local before=$(dir_size_bytes "$HOME/Library/Logs")
                find "$HOME/Library/Logs" -mindepth 1 -type f -mtime +7 -delete 2>/dev/null
                find "$HOME/Library/Logs" -mindepth 1 -type d -empty -delete 2>/dev/null
                local after=$(dir_size_bytes "$HOME/Library/Logs")
                local diff=$((before - after))
                [ "$diff" -gt 0 ] && freed=$((freed + diff))
                print_good "Cleared old logs ($(human_size $diff))"
            fi

            # Trash
            if [ -d "$HOME/.Trash" ]; then
                local before=$(dir_size_bytes "$HOME/.Trash")
                rm -rf "$HOME/.Trash/"* 2>/dev/null
                rm -rf "$HOME/.Trash/".* 2>/dev/null
                freed=$((freed + before))
                print_good "Emptied Trash ($(human_size $before))"
            fi

            # Browser caches
            for bp in \
                "$HOME/Library/Caches/Google/Chrome" \
                "$HOME/Library/Caches/com.apple.Safari" \
                "$HOME/Library/Caches/Firefox" \
                "$HOME/Library/Caches/com.microsoft.edgemac" \
                "$HOME/Library/Caches/company.thebrowser.Browser" \
                "$HOME/Library/Caches/com.brave.Browser"; do
                if [ -d "$bp" ]; then
                    local before=$(dir_size_bytes "$bp")
                    rm -rf "$bp" 2>/dev/null
                    freed=$((freed + before))
                    local bname=$(echo "$bp" | sed 's|.*/||')
                    print_good "Cleared browser cache: $bname ($(human_size $before))"
                fi
            done

            # Xcode
            if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
                local before=$(dir_size_bytes "$HOME/Library/Developer/Xcode/DerivedData")
                rm -rf "$HOME/Library/Developer/Xcode/DerivedData" 2>/dev/null
                freed=$((freed + before))
                print_good "Cleared Xcode build data ($(human_size $before))"
            fi

            # Homebrew cache
            if command -v brew &>/dev/null; then
                local brew_cache=$(brew --cache 2>/dev/null)
                if [ -d "$brew_cache" ]; then
                    local before=$(dir_size_bytes "$brew_cache")
                    brew cleanup --prune=all 2>/dev/null
                    local after=$(dir_size_bytes "$brew_cache")
                    local diff=$((before - after))
                    [ "$diff" -gt 0 ] && freed=$((freed + diff))
                    print_good "Cleaned Homebrew cache ($(human_size $diff))"
                fi
            fi

            # npm cache
            if [ -d "$HOME/.npm/_cacache" ]; then
                local before=$(dir_size_bytes "$HOME/.npm/_cacache")
                npm cache clean --force 2>/dev/null
                freed=$((freed + before))
                print_good "Cleared npm cache ($(human_size $before))"
            fi

            # pip cache
            if [ -d "$HOME/Library/Caches/pip" ]; then
                local before=$(dir_size_bytes "$HOME/Library/Caches/pip")
                rm -rf "$HOME/Library/Caches/pip" 2>/dev/null
                freed=$((freed + before))
                print_good "Cleared pip cache ($(human_size $before))"
            fi

            echo ""
            echo -e "  ${GREEN}${BOLD}Freed up ~$(human_size $freed)${NC}"
            ;;
        3)
            echo -e "  ${BOLD}Full Clean — Including old Downloads...${NC}"
            echo ""
            echo -e "  ${YELLOW}${WARN}${NC}  This will delete files in Downloads older than 30 days."
            echo -e "  ${DIM}  Make sure anything important is saved elsewhere first.${NC}"
            echo ""
            read -p "  Are you sure? (y/n): " confirm_full
            echo ""

            if [[ ! "$confirm_full" =~ ^[Yy] ]]; then
                print_info "Skipping full clean. Running deep clean instead..."
                clean_choice=2
                # Recurse with deep clean (simplified: just do the same as option 2)
            fi

            local freed=0

            # All the deep clean items first
            # Caches
            if [ -d "$HOME/Library/Caches" ]; then
                local before=$(dir_size_bytes "$HOME/Library/Caches")
                find "$HOME/Library/Caches" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
                local after=$(dir_size_bytes "$HOME/Library/Caches")
                local diff=$((before - after))
                [ "$diff" -gt 0 ] && freed=$((freed + diff))
                print_good "Cleared app caches ($(human_size $diff))"
            fi

            # Logs
            if [ -d "$HOME/Library/Logs" ]; then
                local before=$(dir_size_bytes "$HOME/Library/Logs")
                find "$HOME/Library/Logs" -mindepth 1 -type f -mtime +7 -delete 2>/dev/null
                find "$HOME/Library/Logs" -mindepth 1 -type d -empty -delete 2>/dev/null
                local after=$(dir_size_bytes "$HOME/Library/Logs")
                local diff=$((before - after))
                [ "$diff" -gt 0 ] && freed=$((freed + diff))
                print_good "Cleared old logs ($(human_size $diff))"
            fi

            # Trash
            if [ -d "$HOME/.Trash" ]; then
                local before=$(dir_size_bytes "$HOME/.Trash")
                rm -rf "$HOME/.Trash/"* 2>/dev/null
                rm -rf "$HOME/.Trash/".* 2>/dev/null
                freed=$((freed + before))
                print_good "Emptied Trash ($(human_size $before))"
            fi

            # Browser caches
            for bp in \
                "$HOME/Library/Caches/Google/Chrome" \
                "$HOME/Library/Caches/com.apple.Safari" \
                "$HOME/Library/Caches/Firefox" \
                "$HOME/Library/Caches/com.microsoft.edgemac" \
                "$HOME/Library/Caches/company.thebrowser.Browser" \
                "$HOME/Library/Caches/com.brave.Browser"; do
                if [ -d "$bp" ]; then
                    local before=$(dir_size_bytes "$bp")
                    rm -rf "$bp" 2>/dev/null
                    freed=$((freed + before))
                fi
            done
            print_good "Cleared all browser caches"

            # Dev caches
            [ -d "$HOME/Library/Developer/Xcode/DerivedData" ] && {
                local before=$(dir_size_bytes "$HOME/Library/Developer/Xcode/DerivedData")
                rm -rf "$HOME/Library/Developer/Xcode/DerivedData" 2>/dev/null
                freed=$((freed + before))
            }
            command -v brew &>/dev/null && brew cleanup --prune=all 2>/dev/null
            [ -d "$HOME/.npm/_cacache" ] && { npm cache clean --force 2>/dev/null; }
            [ -d "$HOME/Library/Caches/pip" ] && rm -rf "$HOME/Library/Caches/pip" 2>/dev/null
            print_good "Cleared developer caches"

            # Old downloads (only if confirmed)
            if [[ "$confirm_full" =~ ^[Yy] ]]; then
                local dl_freed=0
                while IFS= read -r -d '' file; do
                    local fsize=$(stat -f%z "$file" 2>/dev/null)
                    dl_freed=$((dl_freed + fsize))
                    rm -f "$file" 2>/dev/null
                done < <(find "$HOME/Downloads" -maxdepth 1 -type f -mtime +30 -print0 2>/dev/null)
                freed=$((freed + dl_freed))
                print_good "Removed old Downloads ($(human_size $dl_freed))"
            fi

            echo ""
            echo -e "  ${GREEN}${BOLD}Freed up ~$(human_size $freed)${NC}"
            ;;
        *)
            print_info "Skipping cleanup"
            ;;
    esac
}

# ============================================================================
# 6. STALE APPS — What are you not using?
# ============================================================================

check_stale_apps() {
    print_header "UNUSED APPS"
    print_info "Checking for apps you haven't opened in 6+ months..."
    echo ""

    local stale_count=0
    local stale_total_size=0
    local six_months_ago
    six_months_ago=$(date -v-6m +%s 2>/dev/null)

    # Collect stale apps into array for sorting
    local stale_apps=()

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

                stale_apps+=("${app_size_bytes}|${app_name}|${months_ago}|${app_size_hr}")
                stale_total_size=$((stale_total_size + app_size_bytes))
                stale_count=$((stale_count + 1))
            fi
        fi
    done

    # Sort by size (largest first) and display
    if [ "$stale_count" -gt 0 ]; then
        printf '%s\n' "${stale_apps[@]}" | sort -t'|' -k1 -nr | head -15 | while IFS='|' read -r size name months hr_size; do
            if [ "$size" -gt 104857600 ] 2>/dev/null; then  # > 100 MB
                print_warning "${BOLD}${name}${NC} — ${hr_size}, unused for ${months} months"
            else
                print_info "${name} — ${hr_size}, unused for ${months} months"
            fi
        done

        echo ""
        local total_hr=$(human_size "$stale_total_size")
        echo -e "  ${DIM}${stale_count} apps haven't been used in 6+ months (${total_hr} total)${NC}"
        echo -e "  ${DIM}To uninstall: drag the app from /Applications to Trash${NC}"

        if [ "$stale_total_size" -gt 1073741824 ]; then  # > 1 GB
            ALL_RECOMMENDATIONS+=("You have ${stale_count} unused apps taking up ~${total_hr}. Consider removing ones you don't need.")
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

    local startup_count=0

    # ── Login Items (user-configured) ──
    print_section "LOGIN ITEMS"

    local login_items
    login_items=$(osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null)

    if [ -n "$login_items" ] && [ "$login_items" != "" ]; then
        IFS=', ' read -ra items <<< "$login_items"
        for item in "${items[@]}"; do
            item=$(echo "$item" | xargs)
            [ -z "$item" ] && continue
            print_info "$item"
            startup_count=$((startup_count + 1))
        done
    else
        print_good "No login items configured"
    fi

    # ── Launch Agents (background services) ──
    print_section "BACKGROUND SERVICES"

    local agent_count=0
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

            # Try to get a friendly name
            local friendly_name
            friendly_name=$(echo "$label" | sed 's/com\.//;s/\./ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')

            print_info "${friendly_name} ${DIM}(${label})${NC}"
            agent_count=$((agent_count + 1))
            startup_count=$((startup_count + 1))
        done
    fi

    if [ "$agent_count" -eq 0 ]; then
        print_good "No third-party background services"
    fi

    echo ""
    if [ "$startup_count" -gt 8 ]; then
        print_warning "${BOLD}${startup_count} things launch at startup${NC} — that's a lot"
        print_info "Consider removing items you don't need from System Settings → General → Login Items"
        TOTAL_WARNINGS=$((TOTAL_WARNINGS + 1))
        ALL_RECOMMENDATIONS+=("You have ${startup_count} startup items. Reducing these will make your Mac boot faster.")
    elif [ "$startup_count" -gt 0 ]; then
        print_info "${startup_count} startup items — reasonable"
    else
        print_good "Clean startup — nothing unnecessary launching"
    fi
}

# ============================================================================
# 8. STATS APP CHECK
# ============================================================================

check_stats() {
    local stats_installed=false
    if [ -d "/Applications/Stats.app" ] || [ -d "$HOME/Applications/Stats.app" ] || brew list --cask stats &>/dev/null 2>&1; then
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
    updates_available=$(softwareupdate -l 2>&1 | grep -c "available")
    if [ "$updates_available" -gt 0 ]; then
        print_warning "macOS updates are available"
        print_info "Updates include security patches and performance improvements"
        print_info "Go to System Settings → General → Software Update"
        opt_count=$((opt_count + 1))
    else
        print_good "macOS is up to date"
    fi

    # ── Check FileVault ──
    local fv_status
    fv_status=$(fdesetup status 2>/dev/null)
    if echo "$fv_status" | grep -q "On"; then
        print_good "FileVault encryption: ${BOLD}ON${NC} — Your data is protected"
    else
        print_info "FileVault encryption: ${BOLD}OFF${NC}"
        print_info "Consider enabling in System Settings → Privacy & Security → FileVault"
        opt_count=$((opt_count + 1))
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
        sudo dscacheutil -flushcache 2>/dev/null && sudo killall -HUP mDNSResponder 2>/dev/null
        print_good "DNS cache flushed"
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
# 10. FINAL SUMMARY
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
    check_stats
    show_summary
}

main "$@"
