#!/bin/bash
# ============================================================================
# Mac Health Checkup - Installer
# Installs the app and optional CLI tool on any Mac.
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
# LOCATE PROJECT FILES
# ============================================================================

# Try to find the project directory
# Priority: 1) directory this script is in, 2) current working directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -d "$SCRIPT_DIR/Mac Health Checkup.app" ] && [ -f "$SCRIPT_DIR/mac-checkup.sh" ]; then
    PROJECT_DIR="$SCRIPT_DIR"
elif [ -d "$(pwd)/Mac Health Checkup.app" ] && [ -f "$(pwd)/mac-checkup.sh" ]; then
    PROJECT_DIR="$(pwd)"
else
    echo ""
    print_bad "Could not find the Mac Health Checkup files."
    echo ""
    print_info "Make sure this script is in the same folder as:"
    print_info "  - Mac Health Checkup.app"
    print_info "  - mac-checkup.sh"
    echo ""
    print_info "Or run this script from the diagnostic-mac folder:"
    print_info "  cd /path/to/diagnostic-mac && ./install.sh"
    echo ""
    exit 1
fi

APP_SOURCE="$PROJECT_DIR/Mac Health Checkup.app"
CLI_SOURCE="$PROJECT_DIR/mac-checkup.sh"
APP_DEST="/Applications/Mac Health Checkup.app"
CLI_DEST="/usr/local/bin/mac-checkup"

# ============================================================================
# WELCOME
# ============================================================================

clear
print_header "Mac Health Checkup - Installer"

echo ""
echo -e "  Welcome! This installer will set up ${BOLD}Mac Health Checkup${NC} on your Mac."
echo ""
echo -e "  ${DIM}What gets installed:${NC}"
echo -e "  ${GREEN}1.${NC}  ${BOLD}App${NC} in /Applications  (double-click to run from Launchpad/Finder)"
echo -e "  ${GREEN}2.${NC}  ${BOLD}CLI tool${NC} at /usr/local/bin  (run ${CYAN}mac-checkup${NC} from any Terminal)"
echo ""
echo -e "  ${DIM}Found project files in:${NC} $PROJECT_DIR"

# ============================================================================
# STEP 1: Install the .app to /Applications
# ============================================================================

APP_INSTALLED=false

print_section "Step 1: Install App to /Applications"

if [ -d "$APP_DEST" ]; then
    print_warning "Mac Health Checkup.app already exists in /Applications."
    if ask_yes_no "Overwrite the existing app?"; then
        rm -rf "$APP_DEST"
        if cp -R "$APP_SOURCE" "$APP_DEST" 2>/dev/null; then
            chmod +x "$APP_DEST/Contents/MacOS/launcher"
            print_good "App updated in /Applications."
            APP_INSTALLED=true
        else
            print_bad "Failed to copy app. You may need to close it first."
        fi
    else
        print_info "Skipped. Keeping existing app."
        APP_INSTALLED=true  # it's already there
    fi
else
    if ask_yes_no "Install Mac Health Checkup.app to /Applications?"; then
        if cp -R "$APP_SOURCE" "$APP_DEST" 2>/dev/null; then
            chmod +x "$APP_DEST/Contents/MacOS/launcher"
            print_good "App installed to /Applications."
            APP_INSTALLED=true
        else
            print_bad "Failed to copy app to /Applications."
            print_info "You may not have write permission to /Applications."
            if ask_yes_no "Try again with sudo (requires your password)?"; then
                if sudo cp -R "$APP_SOURCE" "$APP_DEST"; then
                    sudo chmod +x "$APP_DEST/Contents/MacOS/launcher"
                    print_good "App installed to /Applications (with sudo)."
                    APP_INSTALLED=true
                else
                    print_bad "Still could not install the app. Skipping."
                fi
            else
                print_info "Skipped app installation."
            fi
        fi
    else
        print_info "Skipped app installation."
    fi
fi

# ============================================================================
# STEP 2: Refresh icon cache
# ============================================================================

if [ "$APP_INSTALLED" = true ] && [ -d "$APP_DEST" ]; then
    print_section "Step 2: Refresh Icon Cache"

    if ask_yes_no "Refresh icon cache so the app icon shows up properly?"; then
        touch "$APP_DEST"
        # Clear icon services cache
        if command -v killall &>/dev/null; then
            killall Finder 2>/dev/null
            sleep 1
        fi
        print_good "Icon cache refreshed. The icon should appear shortly."
    else
        print_info "Skipped. The icon may not show correctly until you restart Finder."
    fi
else
    print_section "Step 2: Refresh Icon Cache"
    print_info "Skipped (app was not installed)."
fi

# ============================================================================
# STEP 3: Install CLI tool to /usr/local/bin
# ============================================================================

CLI_INSTALLED=false

print_section "Step 3: Install CLI Tool"

echo -e "  ${DIM}This lets you type ${CYAN}mac-checkup${DIM} in any Terminal window to run the checkup.${NC}"
echo -e "  ${DIM}Requires your admin password (sudo).${NC}"

if [ -f "$CLI_DEST" ]; then
    print_warning "mac-checkup already exists at $CLI_DEST."
    if ask_yes_no "Overwrite the existing CLI tool?"; then
        if sudo cp "$CLI_SOURCE" "$CLI_DEST" && sudo chmod +x "$CLI_DEST"; then
            print_good "CLI tool updated at $CLI_DEST."
            CLI_INSTALLED=true
        else
            print_bad "Failed to update CLI tool."
        fi
    else
        print_info "Skipped. Keeping existing CLI tool."
        CLI_INSTALLED=true  # it's already there
    fi
else
    if ask_yes_no "Install the mac-checkup CLI tool? (requires sudo)"; then
        # Ensure /usr/local/bin exists
        if [ ! -d "/usr/local/bin" ]; then
            print_info "Creating /usr/local/bin..."
            sudo mkdir -p /usr/local/bin
        fi

        if sudo cp "$CLI_SOURCE" "$CLI_DEST" && sudo chmod +x "$CLI_DEST"; then
            print_good "CLI tool installed at $CLI_DEST."
            CLI_INSTALLED=true
        else
            print_bad "Failed to install CLI tool."
            print_info "You can still use the app from /Applications."
        fi
    else
        print_info "Skipped CLI installation. You can still use the app."
    fi
fi

# ============================================================================
# DONE
# ============================================================================

print_header "Installation Complete!"

echo ""

if [ "$APP_INSTALLED" = true ]; then
    echo -e "  ${GREEN}${PASS}${NC}  ${BOLD}App installed${NC}"
    echo -e "     ${DIM}Open from Launchpad, Spotlight, or Finder > Applications${NC}"
    echo -e "     ${DIM}You can also type: ${CYAN}open \"/Applications/Mac Health Checkup.app\"${NC}"
else
    echo -e "  ${DIM}${FAIL}  App was not installed${NC}"
fi

echo ""

if [ "$CLI_INSTALLED" = true ]; then
    echo -e "  ${GREEN}${PASS}${NC}  ${BOLD}CLI tool installed${NC}"
    echo -e "     ${DIM}Open any Terminal and type: ${CYAN}mac-checkup${NC}"
else
    echo -e "  ${DIM}${FAIL}  CLI tool was not installed${NC}"
fi

echo ""
echo -e "  ${DIM}To uninstall later, run:${NC}  ${CYAN}./uninstall.sh${NC}"
echo ""
echo -e "  ${BOLD}Stay healthy! 🩺${NC}"
echo ""
