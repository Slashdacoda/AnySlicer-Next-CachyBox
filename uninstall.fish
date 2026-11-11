#!/usr/bin/fish

set blue (set_color blue)
set red (set_color red)
set yellow (set_color yellow)
set normal (set_color normal)

echo -e "$blue--------------------------------------------------------"
echo -e "🗑️  Anycubic Slicer Next Uninstaller"
echo -e "--------------------------------------------------------$normal"

# 1. Remove the app export (menu entries and binaries)
if distrobox list | grep -q "anycubic-slicer"
    echo -e "$yellow--- Step 1: Unexporting Application ---$normal"
    distrobox enter anycubic-slicer -- distrobox-export --app AnycubicSlicerNext --delete
end

# 2. Remove the Distrobox container
if distrobox list | grep -q "anycubic-slicer"
    echo -e "$yellow--- Step 2: Removing Distrobox Container ---$normal"
    distrobox rm -f anycubic-slicer
else
    echo -e "$blue Info: No container 'anycubic-slicer' found.$normal"
end

# 3. Remove Podman Images related to Anycubic
echo -e "$yellow--- Step 3: Removing Podman Images ---$normal"
set images (podman images | grep "anycubic" | awk '{print $3}')
if test -n "$images"
    for img in $images
        podman rmi -f $img
    end
    echo "Images removed."
else
    echo "No Anycubic-related images found."
end

# 4. Manual cleanup of desktop files and icons (just in case)
echo -e "$yellow--- Step 4: Final Cleanup ---$normal"
rm -f ~/.local/share/applications/*anycubic*.desktop
rm -f ~/.local/bin/anycubic-slicer*
update-desktop-database ~/.local/share/applications

# 5. Optional: Config files
echo -e "$red"
read -P "Do you want to delete all configuration and slicer settings in ~/.config? (y/N): " cleanup_config
echo -e "$normal"

if test "$cleanup_config" = "y"
    rm -rf ~/.config/AnycubicSlicerNext
    rm -rf ~/.config/anycubic-slicer-next
    echo "Configuration files deleted."
end

echo -e "$blue--------------------------------------------------------"
echo -e "✅ Deinstallation complete!"
echo -e "--------------------------------------------------------$normal"
