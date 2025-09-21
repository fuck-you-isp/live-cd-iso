#!/bin/bash

# A script to create a custom Debian Live ISO that runs a script on boot.
# Ensure you have squashfs-tools and xorriso installed:
# sudo apt-get update && sudo apt-get install -y squashfs-tools xorriso

set -e # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
ISO_URL="https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-13.1.0-amd64-standard.iso"
ISO_FILENAME=$(basename "$ISO_URL")
WORK_DIR=$(pwd)
ISO_EXTRACT_DIR="$WORK_DIR/iso_extract"
SQUASHFS_EXTRACT_DIR="$WORK_DIR/squashfs_extract"
CUSTOM_ISO_NAME="custom-debian.iso"

# --- 1. Check for required tools ---
echo "--- Checking for required tools (squashfs-tools, xorriso) ---"
for tool in unsquashfs mksquashfs xorriso wget; do
    if ! command -v $tool &> /dev/null; then
        echo "Error: $tool is not installed. Please make sure squashfs-tools, xorriso, and wget are installed."
        exit 1
    fi
done

# --- 2. Clean up previous builds ---
echo "--- Cleaning up previous builds ---"
# Use lazy unmount to avoid "target is busy" errors
sudo umount -l "$SQUASHFS_EXTRACT_DIR/proc" 2>/dev/null || true
sudo umount -l "$SQUASHFS_EXTRACT_DIR/sys" 2>/dev/null || true
sudo umount -l "$SQUASHFS_EXTRACT_DIR/dev" 2>/dev/null || true
sudo rm -rf "$ISO_EXTRACT_DIR" "$SQUASHFS_EXTRACT_DIR" "$CUSTOM_ISO_NAME"
echo "Cleanup complete."

# --- 3. Download Base ISO ---
if [ ! -f "$ISO_FILENAME" ]; then
    echo "--- Downloading Debian Live ISO ---"
    wget --show-progress "$ISO_URL"
else
    echo "--- Debian Live ISO already downloaded ---"
fi

# --- 4. Extract the ISO contents ---
echo "--- Extracting the ISO contents ---"
mkdir -p "$ISO_EXTRACT_DIR"
xorriso -osirrox on -indev "$ISO_FILENAME" -extract / "$ISO_EXTRACT_DIR"
# Make files writable so we can edit them
sudo chmod -R u+w "$ISO_EXTRACT_DIR"

# --- 5. Extract the SquashFS filesystem ---
echo "--- Extracting the SquashFS filesystem ---"
SQUASHFS_FILE=$(find "$ISO_EXTRACT_DIR" -type f -name "*.squashfs" | head -n 1)
if [ -z "$SQUASHFS_FILE" ]; then
    echo "Error: Could not find SquashFS file in the ISO."
    exit 1
fi
echo "Found filesystem: $SQUASHFS_FILE"
mkdir -p "$SQUASHFS_EXTRACT_DIR"
sudo unsquashfs -d "$SQUASHFS_EXTRACT_DIR" "$SQUASHFS_FILE"

# --- 6. Customizing boot menus ---
echo "--- Customizing boot menus (Forceful default boot) ---"
# For all boot configs, remove silencing parameters to show logs and set overlay size.
find "$ISO_EXTRACT_DIR" \( -name "grub.cfg" -o -name "isolinux.cfg" -o -name "live.cfg" -o -name "txt.cfg" \) -exec sudo sed -i \
    -e 's/ quiet//g' \
    -e 's/ splash//g' \
    -e '/^\s*\(linux\|append\)/ s/$/ overlay-size=16G/' \
    {} +

# Force default boot for UEFI (GRUB)
if [ -f "$ISO_EXTRACT_DIR/boot/grub/grub.cfg" ]; then
    sudo sed -i 's/^set timeout=.*/set timeout=10/' "$ISO_EXTRACT_DIR/boot/grub/grub.cfg"
    sudo sed -i 's/^set default=.*/set default="0"/' "$ISO_EXTRACT_DIR/boot/grub/grub.cfg"
fi

# Force default boot for BIOS (ISOLINUX)
if [ -f "$ISO_EXTRACT_DIR/isolinux/isolinux.cfg" ]; then
    # Timeout is in tenths of a second for ISOLINUX
    sudo sed -i 's/^timeout .*/timeout 100/' "$ISO_EXTRACT_DIR/isolinux/isolinux.cfg"
    
    # --- THIS IS THE CORRECTED LOGIC TO FORCE THE DEFAULT BOOT OPTION ---
    # Find the live config file that contains the menu entries.
    LIVE_CFG_FILE="$ISO_EXTRACT_DIR/isolinux/live.cfg"
    if [ -f "$LIVE_CFG_FILE" ]; then
        # Add 'menu default' to the first 'label' entry, which is the "Normal mode".
        # This tells the graphical menu which item to select by default.
        sudo sed -i '0,/^\s*label/s/^\(\s*label.*\)/\1\n  menu default/' "$LIVE_CFG_FILE"
    fi
fi
echo "Boot menus updated for verbose boot, 10s default timeout, and 16GB overlay size."

# --- 7. Prepare and copy custom files to chroot ---
echo "--- Preparing and copying custom files to chroot ---"
sudo cp custom-script.sh "$SQUASHFS_EXTRACT_DIR/usr/local/bin/"
sudo chmod +x "$SQUASHFS_EXTRACT_DIR/usr/local/bin/custom-script.sh"
sudo cp custom-script.service "$SQUASHFS_EXTRACT_DIR/etc/systemd/system/"
sudo cp fyisp.service "$SQUASHFS_EXTRACT_DIR/etc/systemd/system/"

# --- 8. Customize filesystem inside chroot ---
echo "--- Customizing filesystem inside chroot ---"
# Set up DNS and mount necessary filesystems for the chroot environment
echo "nameserver 1.1.1.1" | sudo tee "$SQUASHFS_EXTRACT_DIR/etc/resolv.conf" > /dev/null
sudo mount --bind /dev "$SQUASHFS_EXTRACT_DIR/dev"
sudo mount --bind /sys "$SQUASHFS_EXTRACT_DIR/sys"
sudo mount -t proc /proc "$SQUASHFS_EXTRACT_DIR/proc"

# Execute commands inside the chroot
sudo chroot "$SQUASHFS_EXTRACT_DIR" /bin/bash -c "
    # Update package lists
    apt-get update

    # Install necessary tools
    apt-get install -y figlet iproute2 wget curl

    # --- DOCKER INSTALLATION ---
    echo '>>> Installing Docker...'
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
      \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    echo '>>> Docker installation complete.'

    # Enable our custom services
    systemctl enable custom-script.service
    systemctl enable fyisp.service

    # Disable the login prompt service
    systemctl disable getty@tty1.service
"

# Clean up mounts and DNS file
sudo umount -l "$SQUASHFS_EXTRACT_DIR/proc"
sudo umount -l "$SQUASHFS_EXTRACT_DIR/sys"
sudo umount -l "$SQUASHFS_EXTRACT_DIR/dev"
sudo rm "$SQUASHFS_EXTRACT_DIR/etc/resolv.conf"

# --- 9. Repackage the SquashFS filesystem ---
echo "--- Repackaging the SquashFS filesystem ---"
sudo rm "$SQUASHFS_FILE"
sudo mksquashfs "$SQUASHFS_EXTRACT_DIR" "$SQUASHFS_FILE" -comp xz -noappend -b 1048576

# --- 10. Create the new custom ISO ---
echo "--- Creating the new custom ISO: $CUSTOM_ISO_NAME ---"

# This robust method extracts the MBR from the original ISO and uses it
# to build the new one, along with explicit boot file paths.
echo "--- Extracting Master Boot Record from original ISO ---"
MBR_TEMPLATE="$WORK_DIR/mbr_template.bin"
dd if="$ISO_FILENAME" bs=432 count=1 of="$MBR_TEMPLATE"

echo "--- Building new hybrid ISO ---"
cd "$ISO_EXTRACT_DIR"
sudo xorriso -as mkisofs \
  -o "$WORK_DIR/$CUSTOM_ISO_NAME" \
  -V "CUSTOM DEBIAN" \
  -isohybrid-mbr "$MBR_TEMPLATE" \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot -isohybrid-gpt-basdat \
  -r -J \
  .
cd "$WORK_DIR"
# Clean up the temporary MBR file
rm "$MBR_TEMPLATE"


echo "--- Custom ISO created successfully: $CUSTOM_ISO_NAME ---"
echo "To test it, run:"
echo "qemu-system-x86_64 -m 4G -smp 4 -cdrom $CUSTOM_ISO_NAME -net nic -net user,hostfwd=tcp::8080-:80"


