#!/bin/bash
# ============================================================================
# Mac Health Checkup - Uninstaller
# Cleanly removes Mac Health Checkup from your Mac.
# ============================================================================

# Colors (matching Mac Health Checkup style)
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

PASS="✓"
WARN="⚠️"
FAIL="✗"

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

ask_yes_no() {
    local prompt="$1"
    local answer
    echo ""
    echo -ne "  ${CYAN}${BOLD}?${NC}  ${prompt} ${DIM}(y/n)${NC} "
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================================
# PATHS
# ============================================================================

APP_PATH="/Applications/Mac Health Checkup.app"
CLI_PATH="/usr/local/bin/mac-checkup"

# ============================================================================
# WELCOME
# ============================================================================

clear
print_header "Mac Health Checkup - Uninstaller"

echo ""
echo -e "  This will remove ${BOLD}Mac Health Checkup${NC} from your Mac."
echo ""
echo -e "  ${DIM}It will check for and offer to remove:${NC}"
echo -e "  ${RED}1.${NC}  App at ${DIM}$APP_PATH${NC}"
echo -e "  ${RED}2.${NC}  CLI tool at ${DIM}$CLI_PATH${NC}"

# Track what we found and removed
FOUND_SOMETHING=false
REMOVED_SOMETHING=false

# ============================================================================
# STEP 1: Remove the .app from /Applications
# ============================================================================

print_section "Step 1: Remove App from /Applications"

if [ -d "$APP_PATH" ]; then
    FOUND_SOMETHING=true
    print_warning "Found: $APP_PATH"

    if ask_yes_no "Remove Mac Health Checkup.app from /Applications?"; then
        if rm -rf "$APP_PATH" 2>/dev/null; then
            print_good "App removed from /Applications."
            REMOVED_SOMETHING=true
        else
            print_info "Need elevated permissions. Trying with sudo..."
            if sudo rm -rf "$APP_PATH"; then
                print_good "App removed from /Applications (with sudo)."
                REMOVED_SOMETHING=true
            else
                print_bad "Could not remove the app. Try deleting it manually from Finder."
            fi
        fi
    else
        print_info "Skipped. App left in place."
    fi
else
    print_info "App not found in /Applications. Nothing to remove."
fi

# ============================================================================
# STEP 2: Remove the CLI tool
# ============================================================================

print_section "Step 2: Remove CLI Tool"

if [ -f "$CLI_PATH" ]; then
    FOUND_SOMETHING=true
    print_warning "Found: $CLI_PATH"

    if ask_yes_no "Remove the mac-checkup CLI tool? (requires sudo)"; then
        if sudo rm -f "$CLI_PATH"; then
            print_good "CLI tool removed."
            REMOVED_SOMETHING=true
        else
            print_bad "Could not remove the CLI tool."
        fi
    else
        print_info "Skipped. CLI tool left in place."
    fi
else
    print_info "CLI tool not found at $CLI_PATH. Nothing to remove."
fi

# ============================================================================
# DONE
# ============================================================================

print_header "Uninstall Complete"

echo ""

if [ "$FOUND_SOMETHING" = false ]; then
    echo -e "  ${DIM}Mac Health Checkup was not installed on this Mac.${NC}"
    echo -e "  ${DIM}Nothing needed to be removed.${NC}"
elif [ "$REMOVED_SOMETHING" = true ]; then
    echo -e "  ${GREEN}${PASS}${NC}  Mac Health Checkup has been removed from your Mac."
    echo ""
    echo -e "  ${DIM}Note: This uninstaller does NOT delete the original project folder${NC}"
    echo -e "  ${DIM}you downloaded. You can delete that folder yourself if you like,${NC}"
    echo -e "  ${DIM}or keep it to reinstall later with ${CYAN}./install.sh${NC}"
else
    echo -e "  ${DIM}No changes were made. Everything is still in place.${NC}"
fi

echo ""
echo -e "  ${BOLD}Thanks for trying Mac Health Checkup!${NC}"
echo ""
