#!/usr/bin/fish

set blue (set_color blue)
set green (set_color green)
set red (set_color red)
set yellow (set_color yellow)
set normal (set_color normal)

echo -e "$blue--------------------------------------------------------"
echo -e "🗑️  Anycubic Slicer Next Uninstaller"
echo -e "--------------------------------------------------------$normal"

# Distrobox must run rootless as the normal user (same as the installer)
if test (id -u) -eq 0
    echo -e "$red❌ Do not run this uninstaller with sudo or as root.$normal"
    echo -e "   Run it as your normal user:  ./uninstall.fish"
    exit 1
end

# --- Logging: mirror all output into uninstall.log next to this script ---
# Same approach as install.fish: re-run inside `script` (keeps a real terminal
# for prompts), fall back to tee, then strip color/control codes.
set script_path (realpath (status filename))
set log_file (dirname $script_path)/uninstall.log
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
    LC_ALL=C sed -i -E 's/\x1b\][^\x07\x1b]*(\x07|\x1b\\\\)//g; s/\x1bP[^\x1b]*\x1b\\\\//g; s/\x1b\[[0-9;?<=>]*[@-~]//g; s/\x1b[=>78]//g; s/\r//g' $log_file 2>/dev/null
    echo -e "📝 Full log saved to: $log_file"
    exit $rc
end

set container_exists false
if distrobox list 2>/dev/null | grep -q "anycubic-slicer"
    set container_exists true
end

# 1. Remove the app export (menu entries and binaries)
echo -e "$yellow--- Step 1: Unexporting Application ---$normal"
if test "$container_exists" = true
    distrobox enter anycubic-slicer -- distrobox-export --app AnycubicSlicerNext --delete
else
    echo -e "$blue Info: No container 'anycubic-slicer' found for unexporting.$normal"
end

# 2. Remove the Distrobox container
echo -e "$yellow--- Step 2: Removing Distrobox Container ---$normal"
if test "$container_exists" = true
    distrobox rm -f anycubic-slicer
    and echo -e "$green Container 'anycubic-slicer' removed.$normal"
else
    echo -e "$blue Info: Container 'anycubic-slicer' does not exist.$normal"
end

# 3. Remove Podman Images related to Anycubic (custom local builds)
echo -e "$yellow--- Step 3: Removing Podman Images ---$normal"
set images (podman images --format '{{.Repository}} {{.ID}}' 2>/dev/null | grep -i "anycubic" | awk '{print $2}')
if test (count $images) -gt 0
    podman rmi -f $images
    echo -e "$green Images removed.$normal"
else
    echo "No Anycubic-related images found."
end

# 4. Manual cleanup of desktop files and binaries (safety net)
# Note: in fish, an unmatched wildcard in a command is an error, but in `set`
# it just yields an empty list - so collect the matches first.
echo -e "$yellow--- Step 4: Final Cleanup ---$normal"
set candidates ~/.local/share/applications/*anycubic*.desktop \
    ~/.local/share/applications/*AnycubicSlicerNext*.desktop \
    ~/.local/bin/anycubic-slicer* \
    ~/.local/bin/AnycubicSlicerNext
# Keep only paths that really exist (plain paths without wildcard are always listed)
set leftovers
for f in $candidates
    if test -e $f; or test -L $f; and not contains -- $f $leftovers
        set -a leftovers $f
    end
end
if test (count $leftovers) -gt 0
    rm -f $leftovers
    echo "Removed leftover files:"
    printf '  %s\n' $leftovers
else
    echo "No leftover desktop files or binaries found."
end
if type -q update-desktop-database
    update-desktop-database ~/.local/share/applications
end

# 5. Optional: Config files
echo -e "\n$red⚠️  CAUTION: Configuration Cleanup$normal"
echo -e "Your slicer profiles and settings are stored in $blue~/.config/AnycubicSlicerNext$normal"
read -P "Do you want to delete all your profiles and settings? (y/N): " cleanup_config

if string match -qi "y" -- "$cleanup_config"
    rm -rf ~/.config/AnycubicSlicerNext
    rm -rf ~/.config/anycubic-slicer-next
    echo -e "$green Configuration directories deleted.$normal"
else
    echo -e "$blue Configuration directories kept.$normal"
end

echo -e "$blue--------------------------------------------------------"
echo -e "✅ Uninstallation complete!"
echo -e "--------------------------------------------------------$normal"
