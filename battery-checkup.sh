#!/bin/bash
# ============================================================================
# Battery Checkup - Mac Battery & Power Diagnostic Tool
# Works on both Intel and Apple Silicon Macs
# ============================================================================

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Symbols
PASS="✓"
WARN="⚠️"
FAIL="✗"

# ============================================================================
# Helper functions
# ============================================================================

print_header() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_section() {
    echo ""
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${DIM}  ──────────────────────────────────────────────────${NC}"
}

print_good() {
    echo -e "  ${GREEN}${PASS}${NC}  $1"
}

print_warning() {
    echo -e "  ${YELLOW}${WARN}${NC}  $1"
}

print_bad() {
    echo -e "  ${RED}${FAIL}${NC}  $1"
}

print_info() {
    echo -e "  ${DIM}→${NC}  $1"
}

# ============================================================================
# Step 1: Check for Stats app
# ============================================================================

check_stats() {
    print_header "CHECKING FOR STATS APP"

    local stats_installed=false

    # Check if Stats is installed (multiple locations)
    if [ -d "/Applications/Stats.app" ] || [ -d "$HOME/Applications/Stats.app" ]; then
        stats_installed=true
    fi

    # Also check via brew
    if brew list --cask stats &>/dev/null; then
        stats_installed=true
    fi

    if [ "$stats_installed" = true ]; then
        print_good "Stats is installed"

        # Check if it's running
        if pgrep -x "Stats" >/dev/null 2>&1; then
            print_good "Stats is running"
        else
            print_warning "Stats is installed but not running"
            print_info "You can open it with: open -a Stats"
        fi

        # Check if Sensors module is enabled
        local sensors_state
        sensors_state=$(defaults read eu.exelban.Stats "Sensors_state" 2>/dev/null)
        if [ "$sensors_state" != "1" ]; then
            echo ""
            print_warning "Stats 'Sensors' module doesn't appear to be enabled"
            print_info "To see power wattage data:"
            print_info "  1. Open Stats settings (click any Stats icon in menu bar → gear icon)"
            print_info "  2. Find 'Sensors' in the left sidebar"
            print_info "  3. Toggle it ON"
            print_info "  4. This shows real-time CPU/GPU/system power in watts"
        fi

        # Check battery widget type
        local battery_widget
        battery_widget=$(defaults read eu.exelban.Stats "Battery_widget" 2>/dev/null)
        if [ "$battery_widget" = "mini" ]; then
            echo ""
            print_warning "Stats battery widget is set to 'mini' (percentage only)"
            print_info "To see full battery details:"
            print_info "  1. Open Stats settings → Battery section"
            print_info "  2. Change widget from 'Mini' to 'Battery Details'"
            print_info "  3. This shows health, cycle count, and more in the dropdown"
        fi
    else
        print_warning "Stats is not installed"
        echo ""
        echo -e "  Stats is a free, open-source system monitor that shows battery"
        echo -e "  health, power wattage, and more in your menu bar."
        echo -e "  ${DIM}(https://github.com/exelban/stats - 36,500+ stars)${NC}"
        echo ""
        read -p "  Would you like to install Stats? (y/n): " install_choice
        echo ""

        if [[ "$install_choice" =~ ^[Yy] ]]; then
            # Check if Homebrew is installed
            if ! command -v brew &>/dev/null; then
                print_warning "Homebrew is not installed (needed to install Stats)"
                read -p "  Would you like to install Homebrew first? (y/n): " brew_choice
                if [[ "$brew_choice" =~ ^[Yy] ]]; then
                    echo ""
                    print_info "Installing Homebrew... (this may take a minute)"
                    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

                    # Add brew to PATH for Apple Silicon
                    if [ -f "/opt/homebrew/bin/brew" ]; then
                        eval "$(/opt/homebrew/bin/brew shellenv)"
                    fi

                    if command -v brew &>/dev/null; then
                        print_good "Homebrew installed successfully"
                    else
                        print_bad "Homebrew installation failed"
                        print_info "You can install Stats manually from: https://github.com/exelban/stats/releases"
                        return
                    fi
                else
                    print_info "Skipping Stats installation"
                    print_info "You can install it later with: brew install stats"
                    return
                fi
            fi

            print_info "Installing Stats..."
            if brew install stats 2>/dev/null; then
                print_good "Stats installed successfully"
                print_info "Opening Stats..."
                open -a Stats 2>/dev/null
                print_info "Stats is now in your menu bar. Right-click its icons to configure."
            else
                print_bad "Stats installation failed"
                print_info "You can try manually: brew install stats"
            fi
        else
            print_info "Skipping Stats installation"
            print_info "You can install it later with: brew install stats"
        fi
    fi
}

# ============================================================================
# Step 2: Gather all battery data
# ============================================================================

gather_data() {
    # Architecture
    ARCH=$(uname -m)
    if [ "$ARCH" = "arm64" ]; then
        CHIP_TYPE="Apple Silicon"
    else
        CHIP_TYPE="Intel"
    fi

    # Mac model
    MAC_MODEL=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Model Name" | awk -F': ' '{print $2}')
    MAC_CHIP=$(system_profiler SPHardwareDataType 2>/dev/null | grep "Chip\|Processor Name" | head -1 | awk -F': ' '{print $2}')
    MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null)

    # ── Use system_profiler as primary source (clean, reliable output) ──
    SP_DATA=$(system_profiler SPPowerDataType 2>/dev/null)
    BATTERY_CONDITION=$(echo "$SP_DATA" | grep "Condition" | awk -F': ' '{print $2}' | xargs)
    CHARGER_CONNECTED=$(echo "$SP_DATA" | grep "Connected" | head -1 | awk -F': ' '{print $2}' | xargs)
    CHARGER_WATTS=$(echo "$SP_DATA" | grep "Wattage" | awk -F': ' '{print $2}' | xargs)
    CHARGER_NAME=$(echo "$SP_DATA" | grep "Name" | tail -1 | awk -F': ' '{print $2}' | xargs)

    # Cycle count from system_profiler (always clean)
    CYCLE_COUNT=$(echo "$SP_DATA" | grep "Cycle Count" | awk -F': ' '{print $2}' | xargs)

    # ── Use ioreg with careful parsing for detailed values ──
    # The trick: ioreg top-level properties use " = " (with spaces)
    # Nested dictionary blobs use "=" (no spaces). We only want top-level.
    # Also filter to lines starting with whitespace + " (IORegistry property lines)

    # Helper: extract a single numeric value from ioreg top-level properties
    ioreg_val() {
        ioreg -rn AppleSmartBattery 2>/dev/null | grep -E "^\s+\"$1\" = " | head -1 | sed 's/.*= //'
    }

    # Helper: extract a Yes/No value
    ioreg_bool() {
        ioreg -rn AppleSmartBattery 2>/dev/null | grep -E "^\s+\"$1\" = " | head -1 | sed 's/.*= //'
    }

    CURRENT_CAPACITY=$(ioreg_val "CurrentCapacity")
    MAX_CAPACITY=$(ioreg_val "AppleRawMaxCapacity")
    DESIGN_CAPACITY=$(ioreg_val "DesignCapacity")
    NOMINAL_CAPACITY=$(ioreg_val "NominalChargeCapacity")
    DESIGN_CYCLES=$(ioreg_val "DesignCycleCount9C")
    IS_CHARGING=$(ioreg_bool "IsCharging")
    EXTERNAL_CONNECTED=$(ioreg_bool "ExternalConnected")
    FULLY_CHARGED=$(ioreg_bool "FullyCharged")
    TEMPERATURE_RAW=$(ioreg_val "Temperature")
    VOLTAGE=$(ioreg_val "Voltage")
    AMPERAGE_RAW=$(ioreg_val "InstantAmperage")

    # Cell voltages: may be at top level OR inside BatteryData blob
    # Try top-level first, then fall back to extracting from BatteryData
    CELL_VOLTAGES=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep -E '^\s+"CellVoltage" = ' | head -1 | sed 's/.*= (//' | sed 's/)//' | tr ',' '\n')
    if [ -z "$CELL_VOLTAGES" ]; then
        # Extract from BatteryData blob: "CellVoltage"=(3804,3804,3804)
        CELL_VOLTAGES=$(ioreg -rn AppleSmartBattery 2>/dev/null | grep "BatteryData" | grep -o '"CellVoltage"=([0-9,]*)' | sed 's/.*=(//' | sed 's/)//' | tr ',' '\n')
    fi

    # ── pmset data ──
    PMSET_DATA=$(pmset -g batt 2>/dev/null)
    POWER_SOURCE=$(echo "$PMSET_DATA" | head -1 | grep -o "'.*'" | tr -d "'")
    BATTERY_PCT=$(echo "$PMSET_DATA" | grep -o '[0-9]*%' | tr -d '%')
    TIME_REMAINING=$(echo "$PMSET_DATA" | grep -o '[0-9]*:[0-9]*' | head -1)
    CHARGING_STATUS=$(echo "$PMSET_DATA" | grep -o 'charging\|discharging\|charged\|finishing charge\|AC attached' | head -1)

    # ── Calculations ──

    # Health percentage
    if [ -n "$MAX_CAPACITY" ] && [ -n "$DESIGN_CAPACITY" ] && [ "$DESIGN_CAPACITY" -gt 0 ] 2>/dev/null; then
        HEALTH_PCT=$(( (MAX_CAPACITY * 100) / DESIGN_CAPACITY ))
    else
        HEALTH_PCT=""
    fi

    # Temperature in F and C
    if [ -n "$TEMPERATURE_RAW" ] && [ "$TEMPERATURE_RAW" -gt 0 ] 2>/dev/null; then
        TEMP_C=$(echo "scale=1; $TEMPERATURE_RAW / 100" | bc 2>/dev/null)
        TEMP_F=$(echo "scale=1; ($TEMPERATURE_RAW / 100) * 9 / 5 + 32" | bc 2>/dev/null)
    else
        TEMP_C=""
        TEMP_F=""
    fi

    # Amperage (unsigned overflow means negative/discharging)
    if [ -n "$AMPERAGE_RAW" ] 2>/dev/null; then
        if [ "$AMPERAGE_RAW" -gt 1000000 ] 2>/dev/null; then
            AMPERAGE_DIRECTION="discharging"
            AMPERAGE_MA=$(python3 -c "print(18446744073709551616 - $AMPERAGE_RAW)" 2>/dev/null)
        else
            AMPERAGE_DIRECTION="charging"
            AMPERAGE_MA="$AMPERAGE_RAW"
        fi
    fi

    # Cycle percentage used
    if [ -n "$CYCLE_COUNT" ] && [ -n "$DESIGN_CYCLES" ] && [ "$DESIGN_CYCLES" -gt 0 ] 2>/dev/null; then
        CYCLE_PCT=$(( (CYCLE_COUNT * 100) / DESIGN_CYCLES ))
    else
        CYCLE_PCT=""
    fi

    # Voltage in volts
    if [ -n "$VOLTAGE" ] && [ "$VOLTAGE" -gt 0 ] 2>/dev/null; then
        VOLTAGE_V=$(echo "scale=2; $VOLTAGE / 1000" | bc 2>/dev/null)
    else
        VOLTAGE_V=""
    fi
}

# ============================================================================
# Step 3: Run diagnostics and print results
# ============================================================================

run_diagnostics() {
    # Track overall issues
    PROBLEMS=0
    WARNINGS=0
    DIAGNOSIS_NOTES=()

    print_header "BATTERY CHECKUP"
    echo ""
    echo -e "  ${DIM}Machine:${NC}  $MAC_MODEL ($CHIP_TYPE - $MAC_CHIP)"
    echo -e "  ${DIM}macOS:${NC}    $MACOS_VERSION"
    echo -e "  ${DIM}Date:${NC}     $(date '+%B %d, %Y at %I:%M %p')"

    # ── Battery Health ──────────────────────────────────────────
    print_section "BATTERY HEALTH"

    if [ -n "$HEALTH_PCT" ]; then
        if [ "$HEALTH_PCT" -ge 90 ]; then
            print_good "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Excellent"
            print_info "Your battery is holding its charge well"
        elif [ "$HEALTH_PCT" -ge 80 ]; then
            print_good "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Good"
            print_info "Normal wear, still has plenty of life left"
        elif [ "$HEALTH_PCT" -ge 70 ]; then
            print_warning "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Worn"
            print_info "Battery holds about ${HEALTH_PCT}% of its original charge"
            print_info "You'll notice shorter battery life than when it was new"
            WARNINGS=$((WARNINGS + 1))
            DIAGNOSIS_NOTES+=("Battery health is below 80%. Apple considers this degraded and may recommend service.")
        elif [ "$HEALTH_PCT" -ge 50 ]; then
            print_bad "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Degraded"
            print_info "Battery only holds about half its original charge"
            print_info "Replacement recommended for regular use"
            PROBLEMS=$((PROBLEMS + 1))
            DIAGNOSIS_NOTES+=("Battery health is significantly degraded at ${HEALTH_PCT}%. Replacement is recommended.")
        else
            print_bad "Battery health: ${BOLD}${HEALTH_PCT}%${NC} — Critical"
            print_info "Battery is severely degraded and may cause unexpected shutdowns"
            print_info "Replacement strongly recommended"
            PROBLEMS=$((PROBLEMS + 1))
            DIAGNOSIS_NOTES+=("Battery health is critical at ${HEALTH_PCT}%. Replace as soon as possible to avoid unexpected shutdowns.")
        fi

        if [ -n "$MAX_CAPACITY" ] && [ -n "$DESIGN_CAPACITY" ]; then
            print_info "Capacity: ${MAX_CAPACITY} mAh remaining out of ${DESIGN_CAPACITY} mAh original"
        fi
    else
        print_warning "Could not determine battery health"
    fi

    # Apple's own condition assessment
    if [ -n "$BATTERY_CONDITION" ]; then
        echo ""
        if [ "$BATTERY_CONDITION" = "Normal" ]; then
            print_good "Apple says: ${BOLD}Normal${NC}"
        elif echo "$BATTERY_CONDITION" | grep -qi "service"; then
            print_warning "Apple says: ${BOLD}${BATTERY_CONDITION}${NC}"
            DIAGNOSIS_NOTES+=("Apple's own diagnostics flag this battery for service.")
        elif echo "$BATTERY_CONDITION" | grep -qi "replace"; then
            print_bad "Apple says: ${BOLD}${BATTERY_CONDITION}${NC}"
            PROBLEMS=$((PROBLEMS + 1))
            DIAGNOSIS_NOTES+=("Apple says this battery needs replacement.")
        else
            print_info "Apple says: ${BOLD}${BATTERY_CONDITION}${NC}"
        fi
    fi

    # ── Charge Cycles ──────────────────────────────────────────
    print_section "CHARGE CYCLES"

    if [ -n "$CYCLE_COUNT" ]; then
        local cycle_display="${CYCLE_COUNT}"
        if [ -n "$DESIGN_CYCLES" ] && [ "$DESIGN_CYCLES" -gt 0 ]; then
            cycle_display="${CYCLE_COUNT} of ${DESIGN_CYCLES} designed"
        fi

        if [ -n "$CYCLE_PCT" ]; then
            if [ "$CYCLE_PCT" -le 50 ]; then
                print_good "Cycles used: ${BOLD}${cycle_display}${NC} (${CYCLE_PCT}% of lifespan)"
                print_info "Plenty of life left in terms of charge cycles"
            elif [ "$CYCLE_PCT" -le 80 ]; then
                print_good "Cycles used: ${BOLD}${cycle_display}${NC} (${CYCLE_PCT}% of lifespan)"
                print_info "Battery has been well-used but still within normal range"
            elif [ "$CYCLE_PCT" -le 100 ]; then
                print_warning "Cycles used: ${BOLD}${cycle_display}${NC} (${CYCLE_PCT}% of lifespan)"
                print_info "Approaching the designed cycle limit"
                WARNINGS=$((WARNINGS + 1))
                DIAGNOSIS_NOTES+=("Battery is at ${CYCLE_PCT}% of its designed cycle life (${CYCLE_COUNT}/${DESIGN_CYCLES} cycles).")
            else
                print_bad "Cycles used: ${BOLD}${cycle_display}${NC} (${CYCLE_PCT}% — over designed limit)"
                print_info "Battery has exceeded its designed cycle count"
                PROBLEMS=$((PROBLEMS + 1))
                DIAGNOSIS_NOTES+=("Battery has exceeded its designed cycle limit of ${DESIGN_CYCLES} cycles.")
            fi
        else
            print_info "Cycles used: ${BOLD}${CYCLE_COUNT}${NC}"
        fi
    else
        print_warning "Could not read cycle count"
    fi

    # ── Power & Charging Status ──────────────────────────────────
    print_section "POWER & CHARGING"

    # Power source
    if [ "$EXTERNAL_CONNECTED" = "Yes" ]; then
        print_good "Power adapter: ${BOLD}Connected${NC}"

        if [ -n "$CHARGER_WATTS" ]; then
            print_info "Charger wattage: ${CHARGER_WATTS}W"
        fi

        if [ -n "$CHARGER_NAME" ] && [ "$CHARGER_NAME" != "" ]; then
            print_info "Charger type: ${CHARGER_NAME}"
        fi

        # Check if actually charging
        if [ "$IS_CHARGING" = "Yes" ]; then
            print_good "Charging: ${BOLD}Yes${NC} — Power is going into the battery"
            if [ -n "$AMPERAGE_MA" ] && [ "$AMPERAGE_DIRECTION" = "charging" ]; then
                print_info "Charge rate: ~${AMPERAGE_MA} mA"
            fi
        elif [ "$FULLY_CHARGED" = "Yes" ]; then
            print_good "Charging: ${BOLD}Fully charged${NC}"
        else
            print_warning "Plugged in but ${BOLD}NOT charging${NC}"
            print_info "This could mean:"
            print_info "  • Battery is being held at a charge limit (if you set one)"
            print_info "  • The charger isn't providing enough power"
            print_info "  • macOS Optimized Charging is waiting to finish charging"
            print_info "  • There may be a problem with the charging circuit"
            WARNINGS=$((WARNINGS + 1))
            DIAGNOSIS_NOTES+=("Mac is plugged in but not actively charging. Check if Optimized Battery Charging or a charge limiter is active.")
        fi
    else
        print_info "Power adapter: ${BOLD}Not connected${NC} — Running on battery"

        if [ -n "$AMPERAGE_MA" ] && [ "$AMPERAGE_DIRECTION" = "discharging" ]; then
            print_info "Current draw: ~${AMPERAGE_MA} mA (what the system is using right now)"
        fi

        if [ -n "$TIME_REMAINING" ] && [ "$TIME_REMAINING" != "0:00" ]; then
            print_info "Estimated time remaining: ${TIME_REMAINING}"
        fi
    fi

    echo ""
    print_info "Current charge level: ${BOLD}${BATTERY_PCT:-unknown}%${NC}"

    # ── Temperature ──────────────────────────────────────────
    print_section "TEMPERATURE"

    if [ -n "$TEMP_C" ] && [ -n "$TEMP_F" ]; then
        # Compare using integer part of temp_c
        TEMP_C_INT=$(echo "$TEMP_C" | awk -F'.' '{print $1}')

        if [ "$TEMP_C_INT" -le 35 ] && [ "$TEMP_C_INT" -ge 10 ]; then
            print_good "Battery temperature: ${BOLD}${TEMP_F}°F / ${TEMP_C}°C${NC} — Normal"
            print_info "Safe operating range is 50–95°F (10–35°C)"
        elif [ "$TEMP_C_INT" -le 45 ]; then
            print_warning "Battery temperature: ${BOLD}${TEMP_F}°F / ${TEMP_C}°C${NC} — Warm"
            print_info "A bit warm. Avoid charging in hot environments."
            WARNINGS=$((WARNINGS + 1))
            DIAGNOSIS_NOTES+=("Battery temperature is elevated at ${TEMP_F}°F. High temps accelerate battery wear.")
        else
            print_bad "Battery temperature: ${BOLD}${TEMP_F}°F / ${TEMP_C}°C${NC} — Hot!"
            print_info "High temperature damages battery health over time"
            print_info "Let the machine cool down. Check for runaway processes."
            PROBLEMS=$((PROBLEMS + 1))
            DIAGNOSIS_NOTES+=("Battery temperature is high at ${TEMP_F}°F. This can cause permanent damage. Check for apps using excessive CPU.")
        fi
    else
        print_warning "Could not read battery temperature"
    fi

    # ── Voltage & Cell Health ──────────────────────────────────
    print_section "VOLTAGE & CELL HEALTH"

    if [ -n "$VOLTAGE_V" ]; then
        print_info "Battery voltage: ${BOLD}${VOLTAGE_V}V${NC}"
    fi

    if [ -n "$CELL_VOLTAGES" ]; then
        echo -e "  ${DIM}→${NC}  Individual cell voltages:"
        local cell_num=1
        local min_cell=99999
        local max_cell=0
        local cell_values=()

        while IFS= read -r cv; do
            if [ -n "$cv" ] && [ "$cv" -gt 0 ] 2>/dev/null; then
                cell_v=$(echo "scale=3; $cv / 1000" | bc 2>/dev/null)
                echo -e "       Cell $cell_num: ${cell_v}V (${cv} mV)"
                cell_num=$((cell_num + 1))
                cell_values+=("$cv")
                [ "$cv" -lt "$min_cell" ] && min_cell=$cv
                [ "$cv" -gt "$max_cell" ] && max_cell=$cv
            fi
        done <<< "$CELL_VOLTAGES"

        if [ "$min_cell" -lt 99999 ] && [ "$max_cell" -gt 0 ]; then
            local cell_diff=$((max_cell - min_cell))
            echo ""
            if [ "$cell_diff" -le 30 ]; then
                print_good "Cell balance: ${BOLD}${cell_diff} mV difference${NC} — Excellent"
                print_info "Cells are well-matched (under 30 mV spread is great)"
            elif [ "$cell_diff" -le 50 ]; then
                print_good "Cell balance: ${BOLD}${cell_diff} mV difference${NC} — Good"
                print_info "Cells are reasonably balanced"
            elif [ "$cell_diff" -le 100 ]; then
                print_warning "Cell balance: ${BOLD}${cell_diff} mV difference${NC} — Uneven"
                print_info "Some cell imbalance detected. This can mean one cell is aging faster."
                WARNINGS=$((WARNINGS + 1))
                DIAGNOSIS_NOTES+=("Cell voltage imbalance of ${cell_diff} mV detected. One cell may be weaker than the others.")
            else
                print_bad "Cell balance: ${BOLD}${cell_diff} mV difference${NC} — Significant imbalance"
                print_info "Large voltage difference between cells suggests a failing cell"
                PROBLEMS=$((PROBLEMS + 1))
                DIAGNOSIS_NOTES+=("Significant cell voltage imbalance (${cell_diff} mV). A cell may be failing, which can cause unexpected shutdowns.")
            fi
        fi
    else
        print_info "Individual cell data not available on this machine"
    fi

    # ── Power Management ──────────────────────────────────────
    print_section "POWER SETTINGS"

    # Check for Optimized Battery Charging
    local optimized_charging
    optimized_charging=$(defaults read com.apple.smartcharging.topoffprotection isEnabled 2>/dev/null)
    if [ "$optimized_charging" = "1" ]; then
        print_good "Optimized Battery Charging: ${BOLD}ON${NC}"
        print_info "macOS learns your routine and delays charging past 80% to reduce wear"
    elif [ "$optimized_charging" = "0" ]; then
        print_info "Optimized Battery Charging: ${BOLD}OFF${NC}"
        print_info "Consider turning this on in System Settings → Battery to extend battery life"
    else
        print_info "Optimized Battery Charging: Could not determine status"
    fi

    # Check Low Power Mode
    local power_mode
    power_mode=$(pmset -g 2>/dev/null | grep "powermode" | awk '{print $2}')
    if [ "$power_mode" = "1" ]; then
        print_info "Low Power Mode: ${BOLD}ON${NC} — Saving energy"
    else
        print_info "Low Power Mode: ${BOLD}OFF${NC}"
    fi

    # Check what's preventing sleep
    local sleep_preventers
    sleep_preventers=$(pmset -g assertions 2>/dev/null | grep "pid.*Prevent" | head -5)
    if [ -n "$sleep_preventers" ]; then
        echo ""
        print_info "Something is preventing your Mac from sleeping:"
        echo "$sleep_preventers" | while read -r line; do
            # Extract app name from "pid 63333(WhatsApp):" format
            local app_name
            app_name=$(echo "$line" | grep -o '([^)]*)' | head -1 | tr -d '()')
            # Extract the reason from 'named: "..."' format
            local reason
            reason=$(echo "$line" | grep -o 'named: ".*"' | sed 's/named: "//' | sed 's/"$//' | cut -c1-60)
            if [ -n "$app_name" ]; then
                if [ -n "$reason" ]; then
                    print_info "  • ${app_name} — ${reason}"
                else
                    print_info "  • ${app_name}"
                fi
            fi
        done
        print_info "This can drain battery faster if you walk away from the machine"
    fi

    # ============================================================================
    # FINAL DIAGNOSIS
    # ============================================================================

    print_header "DIAGNOSIS"

    if [ "$PROBLEMS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
        echo ""
        echo -e "  ${GREEN}${BOLD}All clear!${NC} Your battery looks healthy."
        echo -e "  No problems or concerns detected."
        echo ""
    elif [ "$PROBLEMS" -eq 0 ] && [ "$WARNINGS" -gt 0 ]; then
        echo ""
        echo -e "  ${YELLOW}${BOLD}Some things to keep an eye on:${NC}"
        echo ""
        for note in "${DIAGNOSIS_NOTES[@]}"; do
            echo -e "  ${YELLOW}•${NC} $note"
        done
        echo ""
        echo -e "  ${DIM}Nothing critical, but the battery is showing its age.${NC}"
    else
        echo ""
        echo -e "  ${RED}${BOLD}Issues found:${NC}"
        echo ""
        for note in "${DIAGNOSIS_NOTES[@]}"; do
            echo -e "  ${RED}•${NC} $note"
        done
        echo ""
    fi

    # ── Specific recommendations based on what we found ──
    print_section "WHAT TO DO ABOUT IT"

    if [ -n "$HEALTH_PCT" ] && [ "$HEALTH_PCT" -lt 80 ]; then
        echo -e "  ${BOLD}Your battery is past its prime.${NC} Here are your options:"
        echo ""
        echo -e "  ${BOLD}Option 1: Keep using it${NC}"
        echo -e "  ${DIM}  It still works — you'll just have shorter battery life.${NC}"
        echo -e "  ${DIM}  Keep it plugged in more often when you can.${NC}"
        echo ""
        echo -e "  ${BOLD}Option 2: Apple battery replacement${NC}"
        echo -e "  ${DIM}  ~\$199 at Apple for MacBook Pro battery replacement.${NC}"
        echo -e "  ${DIM}  They do the job right with genuine parts and warranty.${NC}"
        echo ""
        echo -e "  ${BOLD}Option 3: DIY replacement${NC}"
        echo -e "  ${DIM}  ~\$50–80 for a battery kit (iFixit, Amazon, etc.)${NC}"
        echo -e "  ${DIM}  With your repair shop background, this is very doable.${NC}"
        echo -e "  ${DIM}  Check iFixit.com for your specific model's guide.${NC}"
    elif [ -n "$HEALTH_PCT" ] && [ "$HEALTH_PCT" -lt 90 ]; then
        echo -e "  Your battery is fine for now. To make it last longer:"
        echo ""
        echo -e "  • Avoid letting it sit at 100% for long periods"
        echo -e "  • Avoid letting it drain to 0% regularly"
        echo -e "  • Keep it in a cool environment (heat kills batteries)"
        echo -e "  • Turn on Optimized Battery Charging in System Settings → Battery"
    else
        echo -e "  Your battery is in great shape. Just the basics:"
        echo ""
        echo -e "  • Keep Optimized Battery Charging turned on"
        echo -e "  • Avoid extreme temperatures"
        echo -e "  • Run this checkup again in a few months"
    fi

    # ── Footer ──
    echo ""
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  Battery Checkup | $(date '+%Y-%m-%d %H:%M') | $MAC_MODEL${NC}"
    echo -e "${DIM}  Run again anytime: ./battery-checkup.sh${NC}"
    echo -e "${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ============================================================================
# Main
# ============================================================================

main() {
    clear
    echo ""
    echo -e "${BOLD}  🔋 Mac Battery Checkup${NC}"
    echo -e "${DIM}  Checking your battery health, power, and charging...${NC}"

    check_stats
    gather_data
    run_diagnostics
}

main "$@"
