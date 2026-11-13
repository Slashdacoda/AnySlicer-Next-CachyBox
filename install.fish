#!/usr/bin/fish

set blue (set_color blue); set green (set_color green); set red (set_color red); set yellow (set_color yellow); set normal (set_color normal)

echo -e "$blue--------------------------------------------------------"
echo -e "🚀 Anycubic Slicer Next Installer for CachyOS"
echo -e "--------------------------------------------------------$normal"

# --- Pre-Check: Do not run as root ---
# Distrobox must run rootless as the normal user; with sudo it either refuses
# to run or creates a root-owned container whose menu entry ends up in /root.
if test (id -u) -eq 0
    echo -e "$red❌ Do not run this installer with sudo or as root.$normal"
    echo -e "   Run it as your normal user:  ./install.fish"
    echo -e "   (You will be asked for your password when root rights are needed.)"
    exit 1
end

# --- Logging: mirror all output into install.log next to this script ---
# The script re-runs itself inside `script` (util-linux) so the installer keeps
# a real terminal (prompts, sudo, distrobox enter behave as before), while
# everything shown on screen is also recorded. Falls back to tee.
set script_path (realpath (status filename))
set log_file (dirname $script_path)/install.log
if not set -q ANYSLICER_LOGGING
    set -gx ANYSLICER_LOGGING 1
    echo -e "📝 Logging all output to: $log_file"
    if type -q script
        set -l quoted (string replace -a "'" "'\\''" -- $script_path)
        env SHELL=/bin/sh script -q -e -f -c "fish '$quoted'" $log_file
        set rc $status
    else
        fish $script_path 2>&1 | tee $log_file
        set rc $pipestatus[1]
    end
    # Strip color codes and carriage returns so the log is readable / shareable
    LC_ALL=C sed -i -E 's/\x1b\][^\x07\x1b]*(\x07|\x1b\\\\)//g; s/\x1bP[^\x1b]*\x1b\\\\//g; s/\x1b\[[0-9;?<=>]*[@-~]//g; s/\x1b[=>78]//g; s/\r//g' $log_file 2>/dev/null
    echo -e "📝 Full log saved to: $log_file"
    exit $rc
end

# --- Pre-Check: Host Dependencies ---
set missing_pkgs
for pkg in distrobox podman curl
    if not type -q $pkg; set -a missing_pkgs $pkg; end
end
if test (count $missing_pkgs) -gt 0
    echo -e "$yellow📦 Missing host packages: $missing_pkgs$normal"
    if type -q pacman
        sudo pacman -S --needed --noconfirm $missing_pkgs; or begin
            echo -e "$red❌ Could not install: $missing_pkgs$normal"; exit 1
        end
    else
        echo -e "$red❌ Please install these packages first: $missing_pkgs$normal"; exit 1
    end
end

# --- System Info (for the log / bug reports) ---
echo -e "\n$blue--- System Info ---$normal"
echo "Date:      "(date)
echo "Kernel:    "(uname -sr)
echo "OS:        "(grep -m1 PRETTY_NAME /etc/os-release | cut -d= -f2 | string trim -c '"')
echo "Session:   $XDG_SESSION_TYPE / $XDG_CURRENT_DESKTOP"
echo "Distrobox: "(distrobox version 2>&1 | string join ' ')
echo "Podman:    "(podman --version 2>&1)
lspci | grep -Ei "VGA|3D" | sed 's/^/GPU:       /'
if type -q nvidia-smi
    echo "Nvidia:    "(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1 | string join '; ')
end

# --- Pre-Check: Resource Availability ---
echo -e "$blue🔍 Checking resource availability...$normal"
set global_url "https://cdn-global-slicer.anycubic.com/install/AnycubicSlicerNextInstaller.sh"
set universe_url "https://cdn-universe-slicer.anycubic.com/install/AnycubicSlicerNextInstaller.sh"

set global_available false
if curl --head --silent --fail --connect-timeout 5 "$global_url" > /dev/null 2>&1
    set global_available true
end

# --- Step 1: Version Selection ---
echo -e "\n$yellow--- Step 1: Version Selection ---$normal"
set v_default "2"
set global_note ""

if test "$global_available" = true
    set v_default "1"
    echo -e "1) Global Version (International - $greenAvailable / Default$normal)"
    echo -e "2) Universe Version (Asia-Pacific)"
else
    set v_default "2"
    set global_note " ($red Not available / Offline $normal)"
    echo -e "1) Global Version$global_note"
    echo -e "2) Universe Version (Asia-Pacific - $green Default $normal)"
end

read -P "Selection [$v_default]: " v_choice
if test -z "$v_choice"; set v_choice "$v_default"; end

set installer_url "$universe_url"
if test "$v_choice" = "1"; and test "$global_available" = true
    set installer_url "$global_url"
    echo "Selected: Global Version"
else if test "$v_choice" = "1"
    echo -e "$yellow⚠️  Global Version is not reachable right now - using Universe Version instead.$normal"
    echo "   (The Universe installer also lets you choose the Global/English version.)"
else
    echo "Selected: Universe Version"
end

# --- Step 2: GPU Detection & Override ---
set detected_gpu "none"
if type -q nvidia-smi; if nvidia-smi > /dev/null 2>&1; set detected_gpu "nvidia"; end; end
if test "$detected_gpu" = "none"
    if lspci | grep -Ei "VGA|3D" | grep -iq "AMD"; set detected_gpu "amd"
    else if lspci | grep -Ei "VGA|3D" | grep -iq "Intel"; set detected_gpu "intel"; end
end

echo -e "\n$yellow--- Step 2: GPU Selection ---$normal"
echo "Detected Hardware: $green$detected_gpu$normal"
set g_def "4"; switch $detected_gpu; case "nvidia"; set g_def "1"; case "amd"; set g_def "2"; case "intel"; set g_def "3"; end
echo "1) Nvidia  2) AMD  3) Intel  4) Generic"
read -P "Select Driver Stack [$g_def]: " g_choice; if test -z "$g_choice"; set g_choice "$g_def"; end

set gpu_flags; set add_flags ""; set g_type "generic"; set c_file "containerfile.amd"
switch $g_choice
    case 1; set gpu_flags "--nvidia"; set g_type "nvidia"; set c_file "containerfile.nvidia"
    case 2; set add_flags "--device /dev/dri:/dev/dri"; set g_type "amd"; set c_file "containerfile.amd"
    case 3; set add_flags "--device /dev/dri:/dev/dri"; set g_type "intel"; set c_file "containerfile.intel"
end

# --nvidia mounts the host's Nvidia driver into the container; without a
# working host driver this fails or hangs.
if test "$g_type" = "nvidia"; and test "$detected_gpu" != "nvidia"
    echo -e "$red⚠️  Nvidia selected, but no working Nvidia driver was found (nvidia-smi failed).$normal"
    echo -e "   Install/fix the host driver (e.g. nvidia-utils) and reboot, or choose 4) Generic."
    read -P "Continue anyway? [y/N]: " nv_confirm
    if not string match -qi "y*" -- "$nv_confirm"; exit 1; end
end

# --- Debug mode: ANYSLICER_DEBUG=1 ./install.fish -> verbose distrobox output in install.log ---
set dbx_verbose
if set -q ANYSLICER_DEBUG; and test "$ANYSLICER_DEBUG" != 0
    set dbx_verbose --verbose
    echo -e "$yellow🐞 Debug mode: distrobox runs with --verbose$normal"
end

# Fully qualified image name: avoids podman short-name resolution
set image "docker.io/library/ubuntu:24.04"

# --- Pre-Check: Podman responds ---
echo -e "\n$blue🔎 Checking podman...$normal"
timeout 60 podman info > /dev/null 2>&1
switch $status
    case 0
        echo -e "$green   podman OK$normal"
    case 124
        echo -e "$red❌ podman did not respond within 60 seconds.$normal"
        echo "   Try: 'podman info' and 'podman ps -a' in a terminal, or reboot and run the installer again."
        exit 1
    case '*'
        echo -e "$red❌ podman is not working:$normal"
        podman info 2>&1 | tail -n 5
        exit 1
end

# --- Pre-Pull: download the base image with visible progress ---
echo -e "\n$blue⬇️  Downloading base image $image...$normal"
timeout 1800 podman pull $image
switch $status
    case 0
        echo -e "$green   Image ready$normal"
    case 124
        echo -e "$red❌ Image download did not finish within 30 minutes (network / registry problem?).$normal"
        exit 1
    case '*'
        echo -e "$red❌ Image download failed. Check your internet connection and run: podman pull $image$normal"
        exit 1
end

# --- Step 3: Installation Loop with DNS Retry ---
set use_custom_dns false; set install_success false
while test "$install_success" = false
    if distrobox list | grep -q "anycubic-slicer"; distrobox rm -f anycubic-slicer; end
    set current_add_flags "$add_flags"
    if test "$use_custom_dns" = true
        echo -e "$yellow🔧 DNS issues detected. Retrying with explicit DNS...$normal"
        set current_add_flags "$current_add_flags --dns 1.1.1.1 --dns 8.8.8.8"
    end

    echo -e "\n$blue📦 Creating Distrobox container ($g_type)...$normal"
    # Only pass --additional-flags when there are flags: distrobox-create loops
    # forever (100% CPU, no output) on an empty value. This was the Nvidia
    # "freeze" from issue #1 (Nvidia/Generic had no extra flags).
    set create_args --name anycubic-slicer --image $image --no-entry $gpu_flags --yes
    set current_add_flags (string trim -- "$current_add_flags")
    if test -n "$current_add_flags"
        set -a create_args --additional-flags "$current_add_flags"
    end
    distrobox create $dbx_verbose $create_args; or begin
        echo -e "$red❌ Container creation failed.$normal"; exit 1
    end

    echo -e "\n$yellow⏳ First container start + installing basic packages. This can take several minutes...$normal"
    if test "$g_type" = "nvidia"
        echo -e "$yellow   (Nvidia: the first start links the host driver into the container and may show no output for a while — this is not a freeze.)$normal"
    end

    # Quiet apt (no progress bars) in the container, also for Anycubic's installer -> readable install.log
    distrobox enter $dbx_verbose anycubic-slicer -- bash -c "
        echo 'quiet \"1\"; Dpkg::Progress-Fancy \"0\"; APT::Color \"0\";' | sudo tee /etc/apt/apt.conf.d/99anyslicer-quiet > /dev/null && \
        sudo apt update && \
        sudo apt install -y curl ca-certificates lsb-release locales libfuse2* sudo libgl1 libglx-mesa0 libegl1 libgl1-mesa-dri && \
        sudo locale-gen en_US.UTF-8 && \
        curl -fsSL $installer_url -o /tmp/installer.sh && \
        sed -i '1s/^\xEF\xBB\xBF//' /tmp/installer.sh && \
        /bin/bash /tmp/installer.sh
    "
    if test $status -eq 0; set install_success true
    else
        if test "$use_custom_dns" = false; set use_custom_dns true
        else; echo -e "$red❌ Installation failed.$normal"; exit 1; end
    end
end

# --- Step 4: Export & Auto-Stop ---
distrobox enter anycubic-slicer -- distrobox-export --app AnycubicSlicerNext
set d_file (find ~/.local/share/applications -name "*anycubic*.desktop" | head -n 1)
if test -n "$d_file"
    sed -i 's|/run/host||' $d_file
    set exec_cmd (grep "Exec=" $d_file | cut -d'=' -f2-)
    sed -i "s|Exec=.*|Exec=sh -c \"$exec_cmd; distrobox stop anycubic-slicer --yes\"|" $d_file
    update-desktop-database ~/.local/share/applications
    echo -e "$green✅ Done! Container stops automatically on exit.$normal"
end
