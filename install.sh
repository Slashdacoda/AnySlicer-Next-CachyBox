#!/bin/bash

# --- Configuration & Colors ---
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}--------------------------------------------------------${NC}"
echo -e "🚀 Anycubic Slicer Next Installer (Universal Bash)"
echo -e "${BLUE}--------------------------------------------------------${NC}"

# --- Pre-Check: Do not run as root ---
# Distrobox must run rootless as the normal user; with sudo it either refuses
# to run or creates a root-owned container whose menu entry ends up in /root.
if [ "$(id -u)" -eq 0 ]; then
    echo -e "${RED}❌ Do not run this installer with sudo or as root.${NC}"
    echo -e "   Run it as your normal user:  ./install.sh"
    echo -e "   (You will be asked for your password when root rights are needed.)"
    exit 1
fi

# --- Logging: mirror all output into install.log next to this script ---
# The script re-runs itself inside `script` (util-linux) so the installer keeps
# a real terminal (prompts, sudo, distrobox enter behave as before), while
# everything shown on screen is also recorded. Falls back to tee.
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
LOG_FILE="$(dirname "$SCRIPT_PATH")/install.log"
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
    # Strip color codes and carriage returns so the log is readable / shareable
    LC_ALL=C sed -i -E 's/\x1b\][^\x07\x1b]*(\x07|\x1b\\)//g; s/\x1bP[^\x1b]*\x1b\\//g; s/\x1b\[[0-9;?<=>]*[@-~]//g; s/\x1b[=>78]//g; s/\r//g' "$LOG_FILE" 2>/dev/null
    echo -e "📝 Full log saved to: $LOG_FILE"
    exit $rc
fi

# --- Pre-Check: Host Dependencies ---
if ! command -v distrobox &> /dev/null || ! command -v podman &> /dev/null; then
    echo -e "${YELLOW}📦 Installing host dependencies (distrobox, podman)...${NC}"
    if command -v pacman &> /dev/null; then sudo pacman -S --needed --noconfirm distrobox podman
    elif command -v apt &> /dev/null; then sudo apt update && sudo apt install -y distrobox podman
    elif command -v dnf &> /dev/null; then sudo dnf install -y distrobox podman
    else echo -e "${RED}❌ Please install distrobox and podman first.${NC}"; exit 1; fi || {
        echo -e "${RED}❌ Could not install distrobox/podman.${NC}"; exit 1; }
fi

# --- System Info (for the log / bug reports) ---
echo -e "\n${BLUE}--- System Info ---${NC}"
echo "Date:      $(date)"
echo "Kernel:    $(uname -sr)"
echo "OS:        $(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")"
echo "Session:   ${XDG_SESSION_TYPE:-?} / ${XDG_CURRENT_DESKTOP:-?}"
echo "Distrobox: $(distrobox version 2>&1 | tr '\n' ' ')"
echo "Podman:    $(podman --version 2>&1)"
lspci | grep -Ei "VGA|3D" | sed 's/^/GPU:       /'
if command -v nvidia-smi &> /dev/null; then
    echo "Nvidia:    $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1 | tr '\n' ' ')"
fi

# --- Pre-Check: Resource Availability ---
echo -e "${BLUE}🔍 Checking resource availability...${NC}"
GLOBAL_URL="https://cdn-global-slicer.anycubic.com/install/AnycubicSlicerNextInstaller.sh"
UNIVERSE_URL="https://cdn-universe-slicer.anycubic.com/install/AnycubicSlicerNextInstaller.sh"

GLOBAL_AVAILABLE=false
if curl --head --silent --fail --connect-timeout 5 "$GLOBAL_URL" > /dev/null 2>&1; then
    GLOBAL_AVAILABLE=true
fi

# --- Step 1: Version Selection ---
echo -e "\n${YELLOW}--- Step 1: Region / Version Selection ---${NC}"
V_DEFAULT="2"
if [ "$GLOBAL_AVAILABLE" = true ]; then
    V_DEFAULT="1"
    echo -e "1) Global Version (International - ${GREEN}Available / Recommended Default${NC})"
    echo -e "2) Universe Version (Asia-Pacific)"
else
    V_DEFAULT="2"
    echo -e "1) Global Version (${RED}Not available / Offline${NC})"
    echo -e "2) Universe Version (Asia-Pacific - ${GREEN}Default${NC})"
fi

read -p "Selection [$V_DEFAULT]: " v_choice
v_choice=${v_choice:-$V_DEFAULT}

SELECTED_URL="$UNIVERSE_URL"
if [ "$v_choice" == "1" ]; then
    SELECTED_URL="$GLOBAL_URL"
    echo -e "Selection: ${BLUE}Global Version${NC}"
else
    echo -e "Selection: ${BLUE}Universe Version${NC}"
fi

# --- Step 2: Hardware Detection & GPU Override ---
echo -e "\n${YELLOW}--- Step 2: GPU Selection ---${NC}"
detected_gpu="none"
if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    detected_gpu="nvidia"
elif lspci | grep -Ei "VGA|3D" | grep -iq "AMD"; then
    detected_gpu="amd"
elif lspci | grep -Ei "VGA|3D" | grep -iq "Intel"; then
    detected_gpu="intel"
fi

echo -e "Detected Hardware: ${GREEN}$detected_gpu${NC}"

gpu_default="4"
case $detected_gpu in
    "nvidia") gpu_default="1" ;;
    "amd")    gpu_default="2" ;;
    "intel")  gpu_default="3" ;;
esac

echo "1) Nvidia (uses --nvidia flag)"
echo "2) AMD (uses DRI pass-through)"
echo "3) Intel (uses DRI pass-through)"
echo "4) Generic / None / Software Rendering"
read -p "Select Driver Stack [$gpu_default]: " gpu_choice
gpu_choice=${gpu_choice:-$gpu_default}

GPU_FLAG=""
ADD_FLAGS=""
GPU_TYPE="generic"
CONTAINERFILE="containerfile.amd"

case $gpu_choice in
    1) GPU_FLAG="--nvidia"; GPU_TYPE="nvidia"; CONTAINERFILE="containerfile.nvidia" ;;
    2) ADD_FLAGS="--device /dev/dri:/dev/dri"; GPU_TYPE="amd"; CONTAINERFILE="containerfile.amd" ;;
    3) ADD_FLAGS="--device /dev/dri:/dev/dri"; GPU_TYPE="intel"; CONTAINERFILE="containerfile.intel" ;;
    *) GPU_TYPE="generic"; CONTAINERFILE="containerfile.amd" ;;
esac

# --nvidia mounts the host's Nvidia driver into the container; without a
# working host driver this fails or hangs.
if [ "$GPU_TYPE" = "nvidia" ] && [ "$detected_gpu" != "nvidia" ]; then
    echo -e "${RED}⚠️  Nvidia selected, but no working Nvidia driver was found (nvidia-smi failed).${NC}"
    echo -e "   Install/fix the host driver (e.g. nvidia-utils) and reboot, or choose 4) Generic."
    read -p "Continue anyway? [y/N]: " nv_confirm
    [[ "$nv_confirm" =~ ^[yY] ]] || exit 1
fi

# --- Step 3: Image Source ---
echo -e "\n${YELLOW}--- Step 3: Image Source ---${NC}"
echo "1) Standard Ubuntu 24.04 from DockerHub (Default)"
echo "2) Custom Local Containerfile (Build locally)"
read -p "Selection [1]: " img_choice
img_choice=${img_choice:-1}

# --- Step 4: Installation Loop with DNS Retry ---
SUCCESS=false
USE_DNS=false

while [ "$SUCCESS" = false ]; do
    # Cleanup old container if exists
    if distrobox list | grep -q "anycubic-slicer"; then
        distrobox rm -f anycubic-slicer
    fi

    CURRENT_ADD_FLAGS="$ADD_FLAGS"
    if [ "$USE_DNS" = true ]; then
        echo -e "${YELLOW}🔧 DNS/Network issues detected. Re-creating container with explicit DNS (1.1.1.1)...${NC}"
        CURRENT_ADD_FLAGS="$CURRENT_ADD_FLAGS --dns 1.1.1.1 --dns 8.8.8.8"
    fi

    # Image Preparation
    IMAGE_NAME="ubuntu:24.04"
    if [ "$img_choice" == "2" ]; then
        if [ -f "$CONTAINERFILE" ]; then
            echo -e "${BLUE}🏗️ Building local image...${NC}"
            podman build -t "anycubic-custom-$GPU_TYPE" -f "$CONTAINERFILE" .
            IMAGE_NAME="anycubic-custom-$GPU_TYPE"
        else
            echo -e "${RED}Warning: $CONTAINERFILE not found, using standard image.${NC}"
        fi
    fi

    echo -e "${BLUE}📦 Creating Distrobox container...${NC}"
    if ! eval "distrobox create --name anycubic-slicer --image $IMAGE_NAME --no-entry $GPU_FLAG --additional-flags '$CURRENT_ADD_FLAGS' --yes"; then
        echo -e "${RED}❌ Container creation failed.${NC}"
        exit 1
    fi

    echo -e "\n${YELLOW}⏳ First container start + installing basic packages. This can take several minutes...${NC}"
    if [ "$GPU_TYPE" = "nvidia" ]; then
        echo -e "${YELLOW}   (Nvidia: the first start links the host driver into the container and may show no output for a while — this is not a freeze.)${NC}"
    fi

    # Package list fixed for Ubuntu 24.04 (Noble)
    # Quiet apt (no progress bars) in the container, also for Anycubic's installer -> readable install.log
    distrobox enter anycubic-slicer -- bash -c "
        echo 'quiet \"1\"; Dpkg::Progress-Fancy \"0\"; APT::Color \"0\";' | sudo tee /etc/apt/apt.conf.d/99anyslicer-quiet > /dev/null && \
        sudo apt update && \
        sudo apt install -y curl ca-certificates lsb-release locales libfuse2* sudo libgl1 libglx-mesa0 libegl1 libgl1-mesa-dri && \
        sudo locale-gen en_US.UTF-8 && \
        echo 'Downloading and running Anycubic installer...' && \
        curl -fsSL $SELECTED_URL -o /tmp/installer.sh && \
        sed -i '1s/^\xEF\xBB\xBF//' /tmp/installer.sh && \
        /bin/bash /tmp/installer.sh
    "

    # Check if binary exists
    if distrobox enter anycubic-slicer -- bash -c "command -v AnycubicSlicerNext" &> /dev/null; then
        SUCCESS=true
    else
        if [ "$USE_DNS" = false ]; then
            echo -e "${RED}⚠️ Installation failed. Retrying with DNS fix...${NC}"
            USE_DNS=true
        else
            echo -e "${RED}❌ Installation failed twice. Please check your internet connection.${NC}"
            exit 1
        fi
    fi
done

# --- Step 5: Export & Final Fixes ---
echo -e "\n${BLUE}🔗 Exporting application and applying fixes...${NC}"
distrobox enter anycubic-slicer -- distrobox-export --app AnycubicSlicerNext

D_FILE=$(find ~/.local/share/applications -name "*anycubic*.desktop" | head -n 1)

if [ -n "$D_FILE" ]; then
    # Fix Icon Path
    sed -i 's|/run/host||' "$D_FILE"

    # Apply Auto-Stop logic
    OLD_EXEC=$(grep "Exec=" "$D_FILE" | cut -d'=' -f2-)
    if ! grep -q "distrobox stop" "$D_FILE"; then
        sed -i "s|Exec=.*|Exec=sh -c \"$OLD_EXEC; distrobox stop anycubic-slicer --yes\"|" "$D_FILE"
    fi

    [ -x "$(command -v update-desktop-database)" ] && update-desktop-database ~/.local/share/applications
    echo -e "${GREEN}✅ Installation successful!${NC}"
    echo -e "You can now find 'Anycubic Slicer Next' in your app menu."
else
    echo -e "${RED}❌ Export failed. Desktop file not found.${NC}"
    exit 1
fi
