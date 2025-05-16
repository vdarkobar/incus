#!/bin/bash

# ------------------------------------------------------------------------------
# ZFS 
# ------------------------------------------------------------------------------

# Check if lsb-release package is installed, if not install it without prompting
if ! dpkg -l | grep -q lsb-release; then
    echo "Installing lsb-release package..."
    apt-get update -qq > /dev/null
    apt-get install -y lsb-release -qq > /dev/null
    
    # Verify installation was successful
    if ! dpkg -l | grep -q lsb-release; then
        echo "Error: Failed to install lsb-release package."
        exit 1
    fi
fi

# Try to get Debian version with error handling
debian_version=$(lsb_release -cs 2>/dev/null)

# Check if the command succeeded and if we got a value
if [ $? -ne 0 ] || [ -z "$debian_version" ]; then
    echo "Error: Failed to determine Debian version."
    echo "This might not be a Debian-based system or lsb_release is not working properly."
    exit 1
fi

# First, check your Debian version
debian_version=$(lsb_release -cs)

# Add the backports repository based on Debian version
sudo tee /etc/apt/sources.list.d/${debian_version}-backports.list > /dev/null << EOF
deb http://deb.debian.org/debian ${debian_version}-backports main contrib
deb-src http://deb.debian.org/debian ${debian_version}-backports main contrib
EOF

# Create the ZFS preferences file with the correct version
sudo tee /etc/apt/preferences.d/90_zfs > /dev/null << EOF
Package: src:zfs-linux
Pin: release n=${debian_version}-backports
Pin-Priority: 990
EOF

# Wait a moment for apt sources to update
sleep 2

# Install the packages:
sudo apt update
# Get current kernel version and install appropriate headers
kernel_version=$(uname -r)
echo "Current kernel: $kernel_version"
sudo apt install -y dpkg-dev linux-headers-$kernel_version
# Install ZFS packages
sudo apt install -y zfs-dkms zfsutils-linux

# Complete auto-bring-up
# ZFS pools and datasets (and shares) will be active on every reboot
sudo systemctl enable \
  zfs-import-scan.service \
  zfs-mount.service \
  zfs-share.service \
  zfs-zed.service \
  zfs.target

# Sets ZFS ARC max to 20% of total RAM on Debian 12, capped at 16 GiB.

# Desired ARC percentage and max cap (16 GiB)
PERCENTAGE=20
MAX_ARC_BYTES=17179869184

# Get total RAM in KB from /proc/meminfo
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')

# Fallback to free command if /proc/meminfo unavailable
if [ -z "$TOTAL_RAM_KB" ]; then
    echo "Warning: Could not read MemTotal from /proc/meminfo. Using free command."
    if command -v free &> /dev/null; then
        TOTAL_RAM_KB=$(free | grep Mem: | awk '{print $2}')
    else
        echo "Error: Could not determine total RAM size."
        exit 1
    fi
fi

# Convert RAM to bytes
TOTAL_RAM_BYTES=$((TOTAL_RAM_KB * 1024))

# Calculate ARC max as 20% of total RAM
ARC_LIMIT=$((TOTAL_RAM_BYTES * PERCENTAGE / 100))

# Cap at 16 GiB
if [ $ARC_LIMIT -gt $MAX_ARC_BYTES ]; then
    ARC_LIMIT=$MAX_ARC_BYTES
fi

# Convert ARC limit to GB (1 GB = 10^9 bytes) with three decimal places
ARC_LIMIT_WHOLE=$((ARC_LIMIT / 1000000000))
ARC_LIMIT_FRAC=$(( (ARC_LIMIT % 1000000000) / 1000000 ))
ARC_LIMIT_GB=$(printf "%d.%03d" $ARC_LIMIT_WHOLE $ARC_LIMIT_FRAC)

# Set ARC max immediately
echo $ARC_LIMIT | sudo tee /sys/module/zfs/parameters/zfs_arc_max > /dev/null

# Check if /etc/modprobe.d/zfs.conf exists, create or update
CONFIG_FILE="/etc/modprobe.d/zfs.conf"
NEW_SETTING="options zfs zfs_arc_max=$ARC_LIMIT"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "$NEW_SETTING" | sudo tee "$CONFIG_FILE" > /dev/null
else
    if grep -q "zfs_arc_max" "$CONFIG_FILE"; then
        sudo sed -i "s/.*zfs_arc_max.*/$NEW_SETTING/" "$CONFIG_FILE"
    else
        echo "$NEW_SETTING" | sudo tee -a "$CONFIG_FILE" > /dev/null
    fi
fi

# Confirm change in GB
echo "ZFS ARC max set to $ARC_LIMIT_GB GB"

# Note: For ZFS root filesystem, run: sudo update-initramfs -u and reboot

# ------------------------------------------------------------------------------
# KVM 
# ------------------------------------------------------------------------------

# Check if your server's CPU supports virtualization
# If the output is 0, enable virtualization in your BIOS/UEFI settings (VT-x for Intel, 
# AMD-V for AMD) and reboot.
echo "Checking CPU virtualization support..."
virt_support=$(grep -E -c '(vmx|svm)' /proc/cpuinfo)
echo "Virtualization support: $virt_support"
if [ "$virt_support" -eq 0 ]; then
  echo "WARNING: Virtualization not enabled or not supported by your CPU."
  echo "Please enable virtualization in BIOS/UEFI settings if available."
fi

# Installing KVM
# sudo apt update
sudo apt install -y --no-install-recommends \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    bridge-utils \
    virtinst

# Give your user permission to use KVM & libvirt
sudo adduser $(id -un) kvm
sudo adduser $(id -un) libvirt

# Ensures libvirt daemon runs and persists on boot
sudo systemctl start libvirtd
sudo systemctl enable libvirtd

# ------------------------------------------------------------------------------
# INCUS 
# ------------------------------------------------------------------------------

# Prerequisites 
sudo apt install -y ca-certificates gnupg2 wget

# Create a folder to store the Incus keys:
sudo mkdir -p /etc/apt/keyrings/

# Download the keys to the folder we created
sudo wget https://pkgs.zabbly.com/key.asc -O /etc/apt/keyrings/zabbly.asc

# Add the repository for Incus using the keys
sudo tee /etc/apt/sources.list.d/zabbly-incus-stable.sources > /dev/null << EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF

# Update the repositories
sudo apt update

# Install incus
sudo apt install -y incus incus-ui-canonical

# To support the GUI for Incus Virtual Machines, install the viewer
# Only needed if you'll connect to graphical VM consoles
if [ -z "$HEADLESS" ] || [ "$HEADLESS" != "true" ]; then
  echo "Installing virt-viewer for VM console access"
  sudo apt install -y virt-viewer
else
  echo "Skipping virt-viewer installation (headless mode)"
fi

# Put your user into the incus admin group
sudo usermod -aG incus-admin $(id -un)
newgrp incus-admin
echo "Added $(id -un) to incus-admin group"

echo "Setup complete! You should reboot your system before continuing:"
echo "sudo reboot now"

exit

# click create new certificate, set password, download two files, transfer to incus instance, run command to trust the cert, import to browser.
