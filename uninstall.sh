#!/bin/bash

# --- Configuration & Colors ---
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}--------------------------------------------------------${NC}"
echo -e "🗑️  Anycubic Slicer Next Uninstaller (Universal Bash)"
echo -e "${BLUE}--------------------------------------------------------${NC}"

# Distrobox must run rootless as the normal user (same as the installer)
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}❌ Do not run this uninstaller with sudo or as root.${NC}"
    echo -e "   Run it as your normal user:  ./uninstall.sh"
    exit 1
fi

# --- Logging: mirror all output into uninstall.log next to this script ---
# Same approach as install.sh: re-run inside `script` (keeps a real terminal
# for prompts), fall back to tee, then strip color/control codes.
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
LOG_FILE="$(dirname "$SCRIPT_PATH")/uninstall.log"
if [ -z "$ANYSLICER_LOGGING" ]; then
    export ANYSLICER_LOGGING=1
    echo -e "📝 Logging all output to: $LOG_FILE"
    if command -v script &> /dev/null; then
        SHELL=/bin/sh script -q -e -f -c "bash '${SCRIPT_PATH//\'/\'\\\'\'}'" "$LOG_FILE"
        rc=$?
    else
        bash "$SCRIPT_PATH" 2>&1 | tee "$LOG_FILE"
        rc=${PIPESTATUS[0]}
    fi
    LC_ALL=C sed -i -E 's/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g; s/\x1bP[^\x1b]*\x1b\\//g; s/\x1b\[[0-9;?<=>]*[@-~]//g; s/\x1b[=>78]//g; s/\r//g' "$LOG_FILE" 2>/dev/null
    echo -e "📝 Full log saved to: $LOG_FILE"
    exit $rc
fi

# 1. Unexport the application (removes menu entries and binaries)
if distrobox list | grep -q "anycubic-slicer"; then
    echo -e "${YELLOW}--- Step 1: Removing Menu Entries & Binaries ---${NC}"
    # We try to use the internal unexport first for a clean removal
    distrobox enter anycubic-slicer -- distrobox-export --app AnycubicSlicerNext --delete
else
    echo -e "${BLUE}Info: No active container 'anycubic-slicer' found for unexporting.${NC}"
fi

# 2. Remove the Distrobox container
if distrobox list | grep -q "anycubic-slicer"; then
    echo -e "${YELLOW}--- Step 2: Removing Distrobox Container ---${NC}"
    distrobox rm -f anycubic-slicer
    echo -e "${GREEN}Container 'anycubic-slicer' removed.${NC}"
else
    echo -e "${BLUE}Info: Container 'anycubic-slicer' does not exist.${NC}"
fi

# 3. Remove custom Podman images
echo -e "${YELLOW}--- Step 3: Removing Podman Images ---${NC}"
# Look for images created during custom installation
IMAGES=$(podman images | grep "anycubic-custom" | awk '{print $3}')
if [ -n "$IMAGES" ]; then
    podman rmi -f $IMAGES
    echo -e "${GREEN}Custom Anycubic images removed.${NC}"
else
    echo -e "${BLUE}No custom Anycubic images found.${NC}"
fi

# 4. Manual Cleanup (Safety Net)
echo -e "${YELLOW}--- Step 4: Final Cleanup of Local Files ---${NC}"
# Remove leftover desktop files and binaries just in case
rm -f ~/.local/share/applications/*anycubic*.desktop
rm -f ~/.local/share/applications/*AnycubicSlicerNext*.desktop
rm -f ~/.local/bin/AnycubicSlicerNext ~/.local/bin/anycubic-slicer*

# Update host desktop database
if command -v update-desktop-database &> /dev/null; then
    update-desktop-database ~/.local/share/applications
fi
echo -e "${GREEN}Desktop database updated.${NC}"

# 5. Optional: Config files cleanup
echo -e "\n${RED}⚠️  CAUTION: Configuration Cleanup${NC}"
echo -e "Your slicer profiles and settings are stored in ${BLUE}~/.config/AnycubicSlicerNext${NC}"
read -p "Do you want to delete all your profiles and settings? (y/N): " cleanup_config

if [[ "$cleanup_config" == "y" || "$cleanup_config" == "Y" ]]; then
    rm -rf ~/.config/AnycubicSlicerNext
    rm -rf ~/.config/anycubic-slicer-next
    echo -e "${GREEN}Configuration directories deleted.${NC}"
else
    echo -e "${BLUE}Configuration directories kept.${NC}"
fi

echo -e "${BLUE}--------------------------------------------------------${NC}"
echo -e "✅ Uninstallation complete!"
echo -e "${BLUE}--------------------------------------------------------${NC}"
