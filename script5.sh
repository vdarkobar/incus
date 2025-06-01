#!/bin/bash

# ZFS Pool Creation Helper Script
# This script helps with creating ZFS pools by providing various utilities
# such as checking ZFS installation, listing disks, and assisting with pool creation.
# 
# Designed to work on Proxmox VE and other systems - automatically detects if running
# as root and uses sudo only when necessary.

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_msg() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to run commands with or without sudo based on current user
run_cmd() {
    if [ "$EUID" -eq 0 ]; then
        # Running as root, no need for sudo
        "$@"
    else
        # Not running as root, use sudo
        sudo "$@"
    fi
}

# Function to check if ZFS is installed
check_zfs_installed() {
    print_msg "$BLUE" "Checking if ZFS is installed..."
    
    if command -v zpool &> /dev/null && command -v zfs &> /dev/null; then
        print_msg "$GREEN" "✓ ZFS is installed."
        return 0
    else
        print_msg "$RED" "✗ ZFS is not installed."
        
        # Offer to install ZFS
        print_msg "$YELLOW" "Would you like to install ZFS now? (y/n)"
        read -r install_choice
        
        if [[ $install_choice =~ ^[Yy]$ ]]; then
            install_zfs
        else
            # Suggest installation method based on detected OS
            if [ -f /etc/debian_version ]; then
                print_msg "$YELLOW" "To install ZFS on Debian/Ubuntu manually, run:"
                echo "apt update && apt install zfsutils-linux"
            elif [ -f /etc/redhat-release ]; then
                print_msg "$YELLOW" "To install ZFS on RHEL/CentOS/Fedora manually, run:"
                echo "dnf install epel-release"
                echo "dnf install zfs"
            elif [ -f /etc/arch-release ]; then
                print_msg "$YELLOW" "To install ZFS on Arch Linux manually, run:"
                echo "pacman -S zfs-dkms zfs-utils"
            else
                print_msg "$YELLOW" "Please install ZFS according to your distribution's documentation."
            fi
        fi
        
        return 1
    fi
}

# Function to install ZFS (comprehensive installation for Debian-based systems)
install_zfs() {
    print_msg "$BLUE" "Installing ZFS on Debian-based system..."
    print_msg "$BLUE" "======================================="
    
    # Check if this is a Debian-based system
    if [ ! -f /etc/debian_version ]; then
        print_msg "$RED" "This installation method is designed for Debian-based systems only."
        print_msg "$YELLOW" "Please install ZFS manually according to your distribution's documentation."
        return 1
    fi
    
    # Check if lsb-release package is installed, if not install it without prompting
    print_msg "$BLUE" "Checking for lsb-release package..."
    if ! dpkg -l | grep -q lsb-release; then
        print_msg "$YELLOW" "Installing lsb-release package..."
        run_cmd apt-get update -qq > /dev/null
        run_cmd apt-get install -y lsb-release -qq > /dev/null
        
        # Verify installation was successful
        if ! dpkg -l | grep -q lsb-release; then
            print_msg "$RED" "Error: Failed to install lsb-release package."
            return 1
        fi
        print_msg "$GREEN" "✓ lsb-release installed successfully."
    else
        print_msg "$GREEN" "✓ lsb-release already installed."
    fi
    
    # Try to get Debian version with error handling
    print_msg "$BLUE" "Detecting Debian version..."
    debian_version=$(lsb_release -cs 2>/dev/null)
    
    # Check if the command succeeded and if we got a value
    if [ $? -ne 0 ] || [ -z "$debian_version" ]; then
        print_msg "$RED" "Error: Failed to determine Debian version."
        print_msg "$RED" "This might not be a Debian-based system or lsb_release is not working properly."
        return 1
    fi
    
    print_msg "$GREEN" "✓ Detected Debian version: $debian_version"
    
    # Add the backports repository based on Debian version
    print_msg "$BLUE" "Adding backports repository..."
    run_cmd tee /etc/apt/sources.list.d/${debian_version}-backports.list > /dev/null << EOF
deb http://deb.debian.org/debian ${debian_version}-backports main contrib
deb-src http://deb.debian.org/debian ${debian_version}-backports main contrib
EOF
    
    if [ $? -eq 0 ]; then
        print_msg "$GREEN" "✓ Backports repository added."
    else
        print_msg "$RED" "✗ Failed to add backports repository."
        return 1
    fi
    
    # Create the ZFS preferences file with the correct version
    print_msg "$BLUE" "Creating ZFS package preferences..."
    run_cmd tee /etc/apt/preferences.d/90_zfs > /dev/null << EOF
Package: src:zfs-linux
Pin: release n=${debian_version}-backports
Pin-Priority: 990
EOF
    
    if [ $? -eq 0 ]; then
        print_msg "$GREEN" "✓ ZFS preferences configured."
    else
        print_msg "$RED" "✗ Failed to create ZFS preferences."
        return 1
    fi
    
    # Wait a moment for apt sources to update
    print_msg "$BLUE" "Waiting for repository updates..."
    sleep 2
    
    # Update package lists
    print_msg "$BLUE" "Updating package lists..."
    if run_cmd apt update; then
        print_msg "$GREEN" "✓ Package lists updated."
    else
        print_msg "$RED" "✗ Failed to update package lists."
        return 1
    fi
    
    # Get current kernel version and install appropriate headers
    kernel_version=$(uname -r)
    print_msg "$BLUE" "Installing kernel headers for: $kernel_version"
    if run_cmd apt install -y dpkg-dev linux-headers-$kernel_version; then
        print_msg "$GREEN" "✓ Kernel headers installed."
    else
        print_msg "$RED" "✗ Failed to install kernel headers."
        return 1
    fi
    
    # Install ZFS packages
    print_msg "$BLUE" "Installing ZFS packages (this may take a while)..."
    if run_cmd apt install -y zfs-dkms zfsutils-linux; then
        print_msg "$GREEN" "✓ ZFS packages installed successfully."
    else
        print_msg "$RED" "✗ Failed to install ZFS packages."
        return 1
    fi
    
    # Enable ZFS services for auto-start
    print_msg "$BLUE" "Enabling ZFS services for automatic startup..."
    if run_cmd systemctl enable zfs-import-scan.service zfs-mount.service zfs-share.service zfs-zed.service zfs.target; then
        print_msg "$GREEN" "✓ ZFS services enabled."
    else
        print_msg "$YELLOW" "⚠ Warning: Some ZFS services may not have been enabled properly."
    fi
    
    # Configure ZFS ARC (Adaptive Replacement Cache)
    print_msg "$BLUE" "Configuring ZFS ARC (Adaptive Replacement Cache)..."
    configure_zfs_arc
    
    # Final verification
    print_msg "$BLUE" "Verifying ZFS installation..."
    if command -v zpool &> /dev/null && command -v zfs &> /dev/null; then
        print_msg "$GREEN" "🎉 ZFS installation completed successfully!"
        print_msg "$YELLOW" "Note: For optimal performance, consider rebooting the system."
        print_msg "$YELLOW" "You can now create ZFS pools using this script."
        return 0
    else
        print_msg "$RED" "✗ ZFS installation verification failed."
        return 1
    fi
}

# Function to configure ZFS ARC settings
configure_zfs_arc() {
    print_msg "$BLUE" "Configuring ZFS ARC to 20% of RAM (max 16 GiB)..."
    
    # Desired ARC percentage and max cap (16 GiB)
    local PERCENTAGE=20
    local MAX_ARC_BYTES=17179869184
    
    # Get total RAM in KB from /proc/meminfo
    local TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    
    # Fallback to free command if /proc/meminfo unavailable
    if [ -z "$TOTAL_RAM_KB" ]; then
        print_msg "$YELLOW" "Warning: Could not read MemTotal from /proc/meminfo. Using free command."
        if command -v free &> /dev/null; then
            TOTAL_RAM_KB=$(free | grep Mem: | awk '{print $2}')
        else
            print_msg "$RED" "Error: Could not determine total RAM size."
            return 1
        fi
    fi
    
    # Convert RAM to bytes
    local TOTAL_RAM_BYTES=$((TOTAL_RAM_KB * 1024))
    
    # Calculate ARC max as 20% of total RAM
    local ARC_LIMIT=$((TOTAL_RAM_BYTES * PERCENTAGE / 100))
    
    # Cap at 16 GiB
    if [ $ARC_LIMIT -gt $MAX_ARC_BYTES ]; then
        ARC_LIMIT=$MAX_ARC_BYTES
    fi
    
    # Convert ARC limit to GB (1 GB = 10^9 bytes) with three decimal places
    local ARC_LIMIT_WHOLE=$((ARC_LIMIT / 1000000000))
    local ARC_LIMIT_FRAC=$(( (ARC_LIMIT % 1000000000) / 1000000 ))
    local ARC_LIMIT_GB=$(printf "%d.%03d" $ARC_LIMIT_WHOLE $ARC_LIMIT_FRAC)
    
    # Set ARC max immediately
    if echo $ARC_LIMIT | run_cmd tee /sys/module/zfs/parameters/zfs_arc_max > /dev/null; then
        print_msg "$GREEN" "✓ ZFS ARC runtime setting applied."
    else
        print_msg "$YELLOW" "⚠ Warning: Could not set runtime ARC limit (ZFS may not be loaded yet)."
    fi
    
    # Check if /etc/modprobe.d/zfs.conf exists, create or update
    local CONFIG_FILE="/etc/modprobe.d/zfs.conf"
    local NEW_SETTING="options zfs zfs_arc_max=$ARC_LIMIT"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        if echo "$NEW_SETTING" | run_cmd tee "$CONFIG_FILE" > /dev/null; then
            print_msg "$GREEN" "✓ ZFS configuration file created."
        else
            print_msg "$RED" "✗ Failed to create ZFS configuration file."
            return 1
        fi
    else
        if grep -q "zfs_arc_max" "$CONFIG_FILE"; then
            if run_cmd sed -i "s/.*zfs_arc_max.*/$NEW_SETTING/" "$CONFIG_FILE"; then
                print_msg "$GREEN" "✓ ZFS ARC setting updated in configuration."
            else
                print_msg "$RED" "✗ Failed to update ZFS configuration."
                return 1
            fi
        else
            if echo "$NEW_SETTING" | run_cmd tee -a "$CONFIG_FILE" > /dev/null; then
                print_msg "$GREEN" "✓ ZFS ARC setting added to configuration."
            else
                print_msg "$RED" "✗ Failed to add ZFS ARC setting."
                return 1
            fi
        fi
    fi
    
    print_msg "$GREEN" "✓ ZFS ARC max configured to $ARC_LIMIT_GB GB"
    print_msg "$YELLOW" "Note: ARC settings will be fully applied after reboot."
}

# Function to check ZFS version
check_zfs_version() {
    print_msg "$BLUE" "Checking ZFS version..."
    
    if command -v zpool &> /dev/null; then
        local zpool_version=$(zpool version)
        local zfs_version=$(zfs version 2>/dev/null || echo "N/A")
        
        print_msg "$GREEN" "ZFS Pool version: ${zpool_version}"
        print_msg "$GREEN" "ZFS Filesystem version: ${zfs_version}"
        
        # Additional version info from module
        if [ -f /proc/kallsyms ]; then
            local module_version=$(modinfo zfs 2>/dev/null | grep -E "^version:" | awk '{print $2}')
            if [ -n "$module_version" ]; then
                print_msg "$GREEN" "ZFS kernel module version: ${module_version}"
            fi
        fi
    else
        print_msg "$RED" "Cannot check ZFS version - ZFS not installed."
        return 1
    fi
}

# Enhanced function to list all disks by ID (eliminates duplicates)
list_disks_by_id() {
    local disk_ids=()
    local required_cmds=(find realpath lsblk)
    
    print_msg "$BLUE" "Listing all disks by ID..."
    
    # Check for required commands
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: $cmd not found" >&2
            return 1
        fi
    done
    
    # Function to format disk info
    format_disk_info() {
        local disk_id="$1"
        local canonical="$2"
        local size model
        
        # Verify the canonical path is actually a block device first
        if [[ ! -b "$canonical" ]]; then
            return 1  # Skip invalid block devices silently
        fi
        
        # Get disk details with better error handling and explicit stderr redirection
        if { read -r size model; } 2>/dev/null < <(lsblk -d -n -o SIZE,MODEL "$canonical" 2>/dev/null); then
            # Trim whitespace and handle empty model
            size="${size// /}"
            model="${model// /}"
            [[ -z "$model" ]] && model="Unknown"
            echo "$disk_id ($canonical, $size, $model)"
        else
            # Fallback: try to get just the size if model fails
            if size=$(lsblk -d -n -o SIZE "$canonical" 2>/dev/null); then
                size="${size// /}"
                echo "$disk_id ($canonical, $size, Unknown)"
            else
                echo "$disk_id ($canonical)"
            fi
        fi
    }
    
    # Exclusion patterns
    local exclude_patterns=(-part[0-9]+$ lvm-pv-uuid cdrom dvd)
    
    # Check if pattern should be excluded
    should_exclude() {
        local disk_id="$1"
        for pattern in "${exclude_patterns[@]}"; do
            [[ "$disk_id" =~ $pattern ]] && return 0
        done
        return 1
    }
    
    # Try primary method: /dev/disk/by-id
    if [[ -d /dev/disk/by-id ]] && [[ -n "$(find /dev/disk/by-id -maxdepth 1 -type l -print -quit 2>/dev/null)" ]]; then
        local seen_devices=()
        
        while IFS= read -r disk_id; do
            # Skip if matches exclusion patterns
            should_exclude "$(basename "$disk_id")" && continue
            
            # Get canonical path
            canonical=$(realpath "$disk_id" 2>/dev/null) || continue
            [[ -b "$canonical" ]] || continue  # Ensure it's a block device
            
            # Skip if we've already processed this canonical device
            local already_seen=false
            for seen in "${seen_devices[@]}"; do
                if [[ "$seen" == "$canonical" ]]; then
                    already_seen=true
                    break
                fi
            done
            [[ "$already_seen" == true ]] && continue
            
            # Add formatted disk info (only if successful)
            if formatted_info=$(format_disk_info "$disk_id" "$canonical"); then
                disk_ids+=("$formatted_info")
                seen_devices+=("$canonical")
            fi
        done < <(find /dev/disk/by-id -maxdepth 1 -type l 2>/dev/null | sort)
    else
        # Fallback method: lsblk
        echo "Warning: /dev/disk/by-id not found or empty, falling back to lsblk" >&2
        
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            
            # Parse lsblk output
            read -r name size model <<< "$line"
            [[ -n "$name" ]] || continue
            
            # Format output consistently with primary method
            model="${model:-Unknown}"
            disk_ids+=("/dev/$name (/dev/$name, $size, $model)")
        done < <(lsblk -d -o NAME,SIZE,MODEL -n 2>/dev/null | grep -vE '^(loop|sr|ram)' | sort)
    fi
    
    # Check if any disks were found
    if [[ ${#disk_ids[@]} -eq 0 ]]; then
        print_msg "$RED" "No disks found."
        return 1
    fi
    
    # Display results in table format
    print_msg "$GREEN" "Found ${#disk_ids[@]} unique disks:"
    printf "%-60s %-20s %-10s %-20s\n" "DISK ID" "DEVICE" "SIZE" "MODEL"
    echo "----------------------------------------------------------------------------------------------------"
    
    for disk_info in "${disk_ids[@]}"; do
        # Parse the formatted disk info
        if [[ "$disk_info" =~ ^(.+)\ \(([^,]+),\ ([^,]+),\ (.+)\)$ ]]; then
            local short_id=$(basename "${BASH_REMATCH[1]}")
            local device="${BASH_REMATCH[2]}"
            local size="${BASH_REMATCH[3]}"
            local model="${BASH_REMATCH[4]}"
            
            printf "%-60s %-20s %-10s %-20s\n" "$short_id" "$device" "$size" "$model"
        fi
    done
}

# Enhanced disk usage checking function
get_disk_usage() {
    local disk=$1
    local usage=()

    # Extract the canonical device path from the disk string if it's formatted
    local canonical_path
    if [[ "$disk" =~ \(([^,]+), ]]; then
        canonical_path="${BASH_REMATCH[1]}"
    else
        canonical_path="$disk"
    fi

    # Check if disk is part of a ZFS pool
    if command -v zpool &> /dev/null; then
        local zpool_status=$(zpool status -P 2>/dev/null)
        if echo "$zpool_status" | grep -q "$canonical_path"; then
            local pool=$(echo "$zpool_status" | awk -v d="$canonical_path" '$0 ~ d {print prev}' prev=$0 | grep '^pool:' | cut -d' ' -f2)
            usage+=("ZFS pool '$pool'")
        fi
    fi

    # Check if disk or its partitions are mounted
    if lsblk -o MOUNTPOINT -r "$canonical_path" 2>/dev/null | grep -q .; then
        usage+=("mounted")
    fi

    # Check if disk is part of a RAID array
    if grep -q "$canonical_path" /proc/mdstat 2>/dev/null; then
        usage+=("RAID array")
    fi

    # Check if disk is an LVM physical volume
    if command -v pvs &> /dev/null && pvs --noheadings -o pv_name 2>/dev/null | grep -q "$canonical_path"; then
        usage+=("LVM physical volume")
    fi

    # Check if disk has a filesystem
    if blkid "$canonical_path" >/dev/null 2>&1; then
        usage+=("has filesystem")
    fi

    echo "${usage[@]}"
}

# Function to zap (wipe) a disk
zap_disk() {
    local disk=$1
    
    # Extract the canonical device path from the disk string
    local canonical_path
    if [[ "$disk" =~ \(([^,]+), ]]; then
        canonical_path="${BASH_REMATCH[1]}"
    else
        canonical_path="$disk"
    fi
    
    print_msg "$YELLOW" "Zapping disk $canonical_path..."

    # Remove ZFS labels if present
    run_cmd zpool labelclear -f "$canonical_path" 2>/dev/null

    # Wipe filesystem signatures
    run_cmd wipefs -a "$canonical_path" 2>/dev/null

    # Zero out the beginning of the disk
    run_cmd dd if=/dev/zero of="$canonical_path" bs=1M count=1 2>/dev/null

    print_msg "$GREEN" "Disk $canonical_path zapped successfully."
}

# Function to list and zap disks
zap_disks() {
    print_msg "$BLUE" "Disk Zapping Utility"
    print_msg "$BLUE" "-------------------"
    
    # Get list of disks using the enhanced listing function
    local disk_ids=()
    local required_cmds=(find realpath lsblk)
    
    # Check for required commands
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: $cmd not found" >&2
            return 1
        fi
    done
    
    # Simplified disk collection for zapping interface
    if [[ -d /dev/disk/by-id ]] && [[ -n "$(find /dev/disk/by-id -maxdepth 1 -type l -print -quit 2>/dev/null)" ]]; then
        local seen_devices=()
        local exclude_patterns=(-part[0-9]+$ lvm-pv-uuid cdrom dvd)
        
        should_exclude() {
            local disk_id="$1"
            for pattern in "${exclude_patterns[@]}"; do
                [[ "$disk_id" =~ $pattern ]] && return 0
            done
            return 1
        }
        
        while IFS= read -r disk_id; do
            should_exclude "$(basename "$disk_id")" && continue
            canonical=$(realpath "$disk_id" 2>/dev/null) || continue
            [[ -b "$canonical" ]] || continue
            
            # Skip duplicates
            local already_seen=false
            for seen in "${seen_devices[@]}"; do
                if [[ "$seen" == "$canonical" ]]; then
                    already_seen=true
                    break
                fi
            done
            [[ "$already_seen" == true ]] && continue
            
            # Get disk info
            if { read -r size model; } 2>/dev/null < <(lsblk -d -n -o SIZE,MODEL "$canonical" 2>/dev/null); then
                size="${size// /}"
                model="${model// /}"
                [[ -z "$model" ]] && model="Unknown"
                disk_ids+=("$disk_id ($canonical, $size, $model)")
                seen_devices+=("$canonical")
            fi
        done < <(find /dev/disk/by-id -maxdepth 1 -type l 2>/dev/null | sort)
    fi
    
    if [ ${#disk_ids[@]} -eq 0 ]; then
        print_msg "$RED" "No disks found."
        return 1
    fi

    print_msg "$BLUE" "Available disks:"
    for i in "${!disk_ids[@]}"; do
        disk=${disk_ids[$i]}
        usage=$(get_disk_usage "$disk")
        status=$( [ -z "$usage" ] && echo "Not in use" || echo "In use: $usage" )
        printf "%2d) %s - %s\n" "$i" "$disk" "$status"
    done

    print_msg "$BLUE" "Enter disk numbers to zap (space-separated, or 'q' to quit):"
    read -r selection
    if [ "$selection" = "q" ]; then
        print_msg "$GREEN" "Operation cancelled."
        return
    fi

    for num in $selection; do
        if [[ $num =~ ^[0-9]+$ ]] && [ $num -lt ${#disk_ids[@]} ]; then
            disk=${disk_ids[$num]}
            usage=$(get_disk_usage "$disk")
            if [ -z "$usage" ]; then
                zap_disk "$disk"
            else
                print_msg "$RED" "Disk $disk is in use: $usage"
                if echo "$usage" | grep -q "mounted"; then
                    print_msg "$RED" "Warning: Zapping a mounted disk can lead to system instability."
                fi
                if echo "$usage" | grep -q "ZFS pool"; then
                    print_msg "$RED" "Warning: Zapping a disk in an imported ZFS pool can corrupt the pool."
                fi
                print_msg "$YELLOW" "Are you sure you want to zap $disk? This will destroy all data on it. (y/N)"
                read -r confirm
                if [ "$confirm" = "y" ]; then
                    zap_disk "$disk"
                else
                    print_msg "$YELLOW" "Skipping $disk"
                fi
            fi
        else
            print_msg "$RED" "Invalid selection: $num"
        fi
    done
}

# Function to show detailed information about a specific disk
show_disk_info() {
    print_msg "$BLUE" "Enter the device name to get detailed information (e.g., sda):"
    read -r disk_name
    
    if [[ ! -b "/dev/$disk_name" ]]; then
        print_msg "$RED" "Device /dev/$disk_name not found or not a block device."
        return 1
    fi
    
    print_msg "$GREEN" "Detailed information for /dev/$disk_name:"
    echo "---------------------------------------------------------"
    
    # Get disk information using various tools
    echo "BASIC INFO:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL "/dev/$disk_name"
    
    echo -e "\nPARTITION TABLE:"
    run_cmd fdisk -l "/dev/$disk_name" 2>/dev/null || print_msg "$YELLOW" "Cannot get partition info (requires root privileges)."
    
    echo -e "\nSMART INFO (if available):"
    if command -v smartctl &> /dev/null; then
        run_cmd smartctl -a "/dev/$disk_name" 2>/dev/null || print_msg "$YELLOW" "Cannot get SMART info (requires root privileges or smartmontools)."
    else
        print_msg "$YELLOW" "smartmontools not installed. Install with: apt install smartmontools"
    fi
}

# Enhanced disk usage checking (legacy compatibility)
check_disk_usage() {
    local disk=$1
    
    # Check if disk is mounted
    if mount | grep -q "$disk"; then
        print_msg "$RED" "Warning: $disk is currently mounted."
        return 1
    fi
    
    # Check if disk is part of a ZFS pool
    if command -v zpool &> /dev/null; then
        if zpool status 2>/dev/null | grep -q "$disk"; then
            print_msg "$RED" "Warning: $disk is already part of a ZFS pool."
            return 1
        fi
    fi
    
    # Check if disk is used by MD RAID
    if command -v mdadm &> /dev/null; then
        if mdadm --detail --scan 2>/dev/null | grep -q "$disk"; then
            print_msg "$RED" "Warning: $disk is part of an MD RAID array."
            return 1
        fi
    fi
    
    # Check if disk is used by LVM
    if command -v pvs &> /dev/null; then
        if pvs 2>/dev/null | grep -q "$disk"; then
            print_msg "$RED" "Warning: $disk is a physical volume in LVM."
            return 1
        fi
    fi
    
    return 0
}

# Function to create a ZFS pool
create_zfs_pool() {
    if ! check_zfs_installed; then
        return 1
    fi
    
    print_msg "$BLUE" "ZFS Pool Creation Wizard"
    print_msg "$BLUE" "------------------------"
    
    # Step 1: Pool name
    print_msg "$YELLOW" "Enter the name for your ZFS pool:"
    read -r pool_name
    
    if [ -z "$pool_name" ]; then
        print_msg "$RED" "Pool name cannot be empty."
        return 1
    fi
    
    # Check if pool already exists
    if zpool list -H -o name 2>/dev/null | grep -q "^$pool_name$"; then
        print_msg "$RED" "A pool named '$pool_name' already exists."
        return 1
    fi
    
    # Step 2: Pool type
    print_msg "$YELLOW" "Select pool type:"
    echo "1) stripe (no redundancy, maximum space)"
    echo "2) mirror (n-way mirroring)"
    echo "3) raidz (similar to RAID5, single parity)"
    echo "4) raidz2 (similar to RAID6, double parity)"
    echo "5) raidz3 (triple parity)"
    read -r pool_type_num
    
    case $pool_type_num in
        1) pool_type="" ;;
        2) pool_type="mirror" ;;
        3) pool_type="raidz" ;;
        4) pool_type="raidz2" ;;
        5) pool_type="raidz3" ;;
        *) print_msg "$RED" "Invalid selection. Exiting."; return 1 ;;
    esac
    
    # Step 3: Select disks
    print_msg "$YELLOW" "Do you want to use disk IDs (more reliable) or device names?"
    echo "1) Disk IDs (e.g., /dev/disk/by-id/ata-...)"
    echo "2) Device names (e.g., /dev/sda)"
    read -r disk_selection_type
    
    if [ "$disk_selection_type" -eq 1 ]; then
        list_disks_by_id
        print_msg "$YELLOW" "Enter the disk IDs to use, separated by spaces (e.g., 'ata-Disk1 ata-Disk2'):"
        read -r selected_disks_input
        
        # Convert short IDs to full paths
        selected_disks=()
        invalid_disks=()
        for disk in $selected_disks_input; do
            full_path="/dev/disk/by-id/$disk"
            if [ -L "$full_path" ]; then
                selected_disks+=("$full_path")
            else
                invalid_disks+=("$disk")
            fi
        done
        
        # Handle invalid disk IDs
        if [ ${#invalid_disks[@]} -gt 0 ]; then
            print_msg "$RED" "The following disk IDs were not found:"
            for invalid_disk in "${invalid_disks[@]}"; do
                echo "  - $invalid_disk"
            done
            print_msg "$YELLOW" "Available disk IDs are:"
            # Show available disk IDs (excluding CD-ROMs and partitions)
            find /dev/disk/by-id -maxdepth 1 -type l 2>/dev/null | sort | while read -r disk_path; do
                disk_basename=$(basename "$disk_path")
                if [[ ! "$disk_basename" =~ -part[0-9]+$ ]] && [[ ! "$disk_basename" =~ cdrom|dvd ]] && [[ -b "$(readlink -f "$disk_path")" ]]; then
                    echo "  - $disk_basename"
                fi
            done
            print_msg "$YELLOW" "Please re-run the pool creation and use the correct disk IDs."
            return 1
        fi
    else
        print_msg "$YELLOW" "Available disks:"
        lsblk -d -o NAME,SIZE,MODEL | grep -v "loop"
        print_msg "$YELLOW" "Enter the device names to use, separated by spaces (e.g., 'sda sdb'):"
        read -r selected_disks_input
        
        # Convert device names to full paths
        selected_disks=()
        for disk in $selected_disks_input; do
            full_path="/dev/$disk"
            if [ -b "$full_path" ]; then
                selected_disks+=("$full_path")
            else
                print_msg "$RED" "Device '$disk' not found. Please verify the device name."
                return 1
            fi
        done
    fi
    
    # Validate disk selection
    if [ ${#selected_disks[@]} -eq 0 ]; then
        print_msg "$RED" "No valid disks selected."
        return 1
    fi
    
    # Step 3.5: Configure mirror vdevs (if mirror type selected)
    mirror_vdevs=()
    local disks_per_mirror=2  # Default value
    if [ "$pool_type" = "mirror" ] && [ ${#selected_disks[@]} -gt 2 ]; then
        print_msg "$BLUE" "Mirror Pool Configuration"
        print_msg "$BLUE" "========================"
        print_msg "$YELLOW" "You selected ${#selected_disks[@]} disks for mirroring. How do you want to configure them?"
        echo "1) Single mirror vdev with all ${#selected_disks[@]} disks (all disks mirror each other)"
        echo "2) Multiple mirror vdevs (configure pairs/groups)"
        read -r mirror_config_choice
        
        case $mirror_config_choice in
            1)
                print_msg "$GREEN" "Creating single ${#selected_disks[@]}-way mirror vdev."
                # Keep existing behavior - single mirror with all disks
                ;;
            2)
                print_msg "$BLUE" "Configuring multiple mirror vdevs..."
                
                # Ask for disks per mirror vdev
                print_msg "$YELLOW" "How many disks per mirror vdev? (typically 2 or 3):"
                read -r disks_per_mirror
                
                while ! [[ $disks_per_mirror =~ ^[0-9]+$ ]] || [ $disks_per_mirror -lt 2 ]; do
                    print_msg "$RED" "Please enter a valid number (2 or higher):"
                    read -r disks_per_mirror
                done
                
                # Check if we can evenly divide the disks
                local total_disks=${#selected_disks[@]}
                local num_vdevs=$((total_disks / disks_per_mirror))
                local remaining_disks=$((total_disks % disks_per_mirror))
                
                if [ $remaining_disks -ne 0 ]; then
                    print_msg "$YELLOW" "Warning: $total_disks disks cannot be evenly divided into groups of $disks_per_mirror."
                    print_msg "$YELLOW" "This would create $num_vdevs complete mirror vdevs with $remaining_disks disk(s) left over."
                    print_msg "$YELLOW" "Options:"
                    echo "1) Proceed anyway (leftover disks will form a smaller mirror)"
                    echo "2) Choose a different number of disks per mirror"
                    echo "3) Remove some disks from selection"
                    read -r leftover_choice
                    
                    case $leftover_choice in
                        1)
                            print_msg "$GREEN" "Proceeding with uneven distribution."
                            ;;
                        2)
                            print_msg "$YELLOW" "How many disks per mirror vdev?"
                            read -r disks_per_mirror
                            while ! [[ $disks_per_mirror =~ ^[0-9]+$ ]] || [ $disks_per_mirror -lt 2 ]; do
                                print_msg "$RED" "Please enter a valid number (2 or higher):"
                                read -r disks_per_mirror
                            done
                            ;;
                        3)
                            print_msg "$YELLOW" "Please re-run pool creation and select a different number of disks."
                            return 1
                            ;;
                    esac
                fi
                
                # Create mirror vdev groups
                local disk_index=0
                local vdev_count=0
                
                while [ $disk_index -lt ${#selected_disks[@]} ]; do
                    local vdev_disks=()
                    local disks_in_this_vdev=0
                    
                    # Add disks to this vdev
                    while [ $disks_in_this_vdev -lt $disks_per_mirror ] && [ $disk_index -lt ${#selected_disks[@]} ]; do
                        vdev_disks+=("${selected_disks[$disk_index]}")
                        disk_index=$((disk_index + 1))
                        disks_in_this_vdev=$((disks_in_this_vdev + 1))
                    done
                    
                    # If we have remaining disks that don't fill a complete vdev, add them anyway
                    if [ $disk_index -eq ${#selected_disks[@]} ] && [ $disks_in_this_vdev -gt 0 ]; then
                        mirror_vdevs+=("${vdev_disks[@]}")
                        vdev_count=$((vdev_count + 1))
                        print_msg "$GREEN" "Mirror vdev $vdev_count: ${vdev_disks[*]}"
                        break
                    elif [ $disks_in_this_vdev -eq $disks_per_mirror ]; then
                        mirror_vdevs+=("${vdev_disks[@]}")
                        vdev_count=$((vdev_count + 1))
                        print_msg "$GREEN" "Mirror vdev $vdev_count: ${vdev_disks[*]}"
                    fi
                done
                
                # Update pool_type to indicate multiple vdevs
                pool_type="multi_mirror"
                ;;
            *)
                print_msg "$RED" "Invalid selection. Using single mirror vdev."
                ;;
        esac
    fi
    
    # Check minimum disk requirements based on pool type
    case $pool_type in
        "mirror"|"multi_mirror")
            if [ ${#selected_disks[@]} -lt 2 ]; then
                print_msg "$RED" "Mirror requires at least 2 disks."
                return 1
            fi
            ;;
        "raidz")
            if [ ${#selected_disks[@]} -lt 3 ]; then
                print_msg "$RED" "RAIDZ requires at least 3 disks."
                return 1
            fi
            ;;
        "raidz2")
            if [ ${#selected_disks[@]} -lt 4 ]; then
                print_msg "$RED" "RAIDZ2 requires at least 4 disks."
                return 1
            fi
            ;;
        "raidz3")
            if [ ${#selected_disks[@]} -lt 5 ]; then
                print_msg "$RED" "RAIDZ3 requires at least 5 disks."
                return 1
            fi
            ;;
    esac
    
    # Check if any of the selected disks are in use
    for disk in "${selected_disks[@]}"; do
        real_device=$(readlink -f "$disk" || echo "$disk")
        if ! check_disk_usage "$real_device"; then
            print_msg "$YELLOW" "Do you want to continue anyway? (y/n)"
            read -r continue_choice
            if [[ ! $continue_choice =~ ^[Yy]$ ]]; then
                print_msg "$RED" "Pool creation aborted."
                return 1
            fi
            break
        fi
    done
    
    # Step 4: Additional devices (cache, log, spare)
    print_msg "$YELLOW" "Do you want to add additional devices? (y/n)"
    read -r add_additional_choice
    
    cache_devices=()
    log_devices=()
    spare_devices=()
    
    # Function to check if a device is already selected
    is_device_selected() {
        local device_path="$1"
        local device_basename=$(basename "$device_path")
        
        # Check against data disks
        for selected in "${selected_disks[@]}"; do
            if [[ "$selected" == "$device_path" ]] || [[ "$(basename "$selected")" == "$device_basename" ]]; then
                return 0
            fi
        done
        
        # Check against cache devices
        for selected in "${cache_devices[@]}"; do
            if [[ "$selected" == "$device_path" ]] || [[ "$(basename "$selected")" == "$device_basename" ]]; then
                return 0
            fi
        done
        
        # Check against log devices
        for selected in "${log_devices[@]}"; do
            if [[ "$selected" == "$device_path" ]] || [[ "$(basename "$selected")" == "$device_basename" ]]; then
                return 0
            fi
        done
        
        return 1
    }
    
    # Function to show available devices
    show_available_devices() {
        local device_type="$1"
        print_msg "$BLUE" "Available disks for $device_type (excluding already assigned devices):"
        
        if [ "$disk_selection_type" -eq 1 ]; then
            local found_any=false
            while IFS= read -r disk_path; do
                local disk_basename=$(basename "$disk_path")
                if [[ ! "$disk_basename" =~ -part[0-9]+$ ]] && [[ ! "$disk_basename" =~ cdrom|dvd ]] && [[ -b "$(readlink -f "$disk_path" 2>/dev/null)" ]]; then
                    if ! is_device_selected "$disk_path"; then
                        echo "  - $disk_basename"
                        found_any=true
                    fi
                fi
            done < <(find /dev/disk/by-id -maxdepth 1 -type l 2>/dev/null | sort)
            
            if [ "$found_any" = false ]; then
                print_msg "$YELLOW" "  No available devices remaining."
            fi
        else
            local found_any=false
            while IFS= read -r line; do
                if [[ -n "$line" ]] && [[ "$line" != *"NAME"* ]]; then
                    read -r name size model <<< "$line"
                    if [[ -n "$name" ]]; then
                        local device_path="/dev/$name"
                        if ! is_device_selected "$device_path"; then
                            echo "  - $name ($size, $model)"
                            found_any=true
                        fi
                    fi
                fi
            done < <(lsblk -d -o NAME,SIZE,MODEL | grep -v "loop")
            
            if [ "$found_any" = false ]; then
                print_msg "$YELLOW" "  No available devices remaining."
            fi
        fi
    }
    
    if [[ $add_additional_choice =~ ^[Yy]$ ]]; then
        # Cache devices (L2ARC)
        print_msg "$YELLOW" "Add cache devices (L2ARC) for read acceleration? (y/n)"
        read -r add_cache_choice
        
        if [[ $add_cache_choice =~ ^[Yy]$ ]]; then
            show_available_devices "cache"
            
            print_msg "$YELLOW" "Enter cache device IDs/names (space-separated, or press Enter for none):"
            read -r cache_input
            
            if [ -n "$cache_input" ]; then
                for device in $cache_input; do
                    if [ "$disk_selection_type" -eq 1 ]; then
                        full_path="/dev/disk/by-id/$device"
                        if [ -L "$full_path" ]; then
                            cache_devices+=("$full_path")
                        else
                            print_msg "$RED" "Cache device '$device' not found."
                            return 1
                        fi
                    else
                        full_path="/dev/$device"
                        if [ -b "$full_path" ]; then
                            cache_devices+=("$full_path")
                        else
                            print_msg "$RED" "Cache device '$device' not found."
                            return 1
                        fi
                    fi
                done
                print_msg "$GREEN" "Added ${#cache_devices[@]} cache device(s)."
            fi
        fi
        
        # Log devices (SLOG/ZIL)
        print_msg "$YELLOW" "Add log devices (SLOG/ZIL) for write acceleration? (y/n)"
        read -r add_log_choice
        
        if [[ $add_log_choice =~ ^[Yy]$ ]]; then
            show_available_devices "log"
            
            print_msg "$BLUE" "Log devices can be single or mirrored for redundancy."
            print_msg "$YELLOW" "How many log devices do you want? (Enter a number: 1 for single, 2+ for mirror):"
            read -r log_count
            
            # Validate that log_count is a number
            while ! [[ $log_count =~ ^[0-9]+$ ]] || [ $log_count -eq 0 ]; do
                print_msg "$RED" "Please enter a valid number (1 or higher):"
                read -r log_count
            done
            
            print_msg "$YELLOW" "Enter $log_count log device ID(s)/name(s) (space-separated):"
            read -r log_input
            
            # Validate that we got the right number of devices
            log_device_array=($log_input)
            while [ ${#log_device_array[@]} -ne $log_count ]; do
                print_msg "$RED" "Expected $log_count devices but got ${#log_device_array[@]}. Please try again:"
                read -r log_input
                log_device_array=($log_input)
            done
            
            # Process the log devices
            for device in "${log_device_array[@]}"; do
                if [ "$disk_selection_type" -eq 1 ]; then
                    full_path="/dev/disk/by-id/$device"
                    if [ -L "$full_path" ]; then
                        log_devices+=("$full_path")
                    else
                        print_msg "$RED" "Log device '$device' not found."
                        return 1
                    fi
                else
                    full_path="/dev/$device"
                    if [ -b "$full_path" ]; then
                        log_devices+=("$full_path")
                    else
                        print_msg "$RED" "Log device '$device' not found."
                        return 1
                    fi
                fi
            done
            print_msg "$GREEN" "Added ${#log_devices[@]} log device(s)."
        fi
        
        # Spare devices
        print_msg "$YELLOW" "Add hot spare devices? (y/n)"
        read -r add_spare_choice
        
        if [[ $add_spare_choice =~ ^[Yy]$ ]]; then
            show_available_devices "spare"
            
            print_msg "$YELLOW" "Enter spare device IDs/names (space-separated, or press Enter for none):"
            read -r spare_input
            
            if [ -n "$spare_input" ]; then
                for device in $spare_input; do
                    if [ "$disk_selection_type" -eq 1 ]; then
                        full_path="/dev/disk/by-id/$device"
                        if [ -L "$full_path" ]; then
                            spare_devices+=("$full_path")
                        else
                            print_msg "$RED" "Spare device '$device' not found."
                            return 1
                        fi
                    else
                        full_path="/dev/$device"
                        if [ -b "$full_path" ]; then
                            spare_devices+=("$full_path")
                        else
                            print_msg "$RED" "Spare device '$device' not found."
                            return 1
                        fi
                    fi
                done
                print_msg "$GREEN" "Added ${#spare_devices[@]} spare device(s)."
            fi
        fi
    fi
    
    # Step 5: Additional options
    print_msg "$YELLOW" "Do you want to specify additional pool options? (y/n)"
    read -r add_options_choice
    
    options=""
    if [[ $add_options_choice =~ ^[Yy]$ ]]; then
        print_msg "$YELLOW" "Enter ashift value (usually 9 for 512B sectors, 12 for 4K sectors, or 13 for 8K sectors):"
        read -r ashift
        if [ -n "$ashift" ]; then
            options="$options -o ashift=$ashift"
        fi
        
        print_msg "$YELLOW" "Enable compression? (y/n)"
        read -r compression_choice
        if [[ $compression_choice =~ ^[Yy]$ ]]; then
            options="$options -O compression=lz4"
        fi

        print_msg "$YELLOW" "Enable autotrim? (y/n)"
        read -r autotrim_choice
        if [[ $autotrim_choice =~ ^[Yy]$ ]]; then
            options="$options -o autotrim=on"
        fi

        print_msg "$YELLOW" "Enable autoexpand? (y/n)"
        read -r autoexpand_choice
        if [[ $autoexpand_choice =~ ^[Yy]$ ]]; then
            options="$options -o autoexpand=on"
        fi

        print_msg "$YELLOW" "Enable atime? (y/n, 'n' is recommended for better performance)"
        read -r atime_choice
        if [[ ! $atime_choice =~ ^[Yy]$ ]]; then
            options="$options -O atime=off"
        fi
        
        print_msg "$YELLOW" "Additional custom options (e.g., '-O recordsize=128K', or press Enter for none):"
        read -r custom_options
        if [ -n "$custom_options" ] && [[ ! "$custom_options" =~ ^[Nn][Oo]?$ ]]; then
            options="$options $custom_options"
        fi
    else
        # Set some sensible defaults
        options="-o ashift=12 -O compression=lz4 -O atime=off"
    fi
    
    # Step 6: Review and confirm
    print_msg "$BLUE" "Pool Creation Summary:"
    echo "Pool name: $pool_name"
    if [ "$pool_type" = "multi_mirror" ]; then
        echo "Pool type: Multiple mirror vdevs"
        local vdev_num=1
        local disk_index=0
        while [ $disk_index -lt ${#selected_disks[@]} ]; do
            local vdev_disks=()
            local disks_in_vdev=0
            local max_disks=$disks_per_mirror
            
            # Handle last vdev which might have fewer disks
            local remaining_disks=$((${#selected_disks[@]} - disk_index))
            if [ $remaining_disks -lt $disks_per_mirror ]; then
                max_disks=$remaining_disks
            fi
            
            while [ $disks_in_vdev -lt $max_disks ] && [ $disk_index -lt ${#selected_disks[@]} ]; do
                vdev_disks+=("${selected_disks[$disk_index]}")
                disk_index=$((disk_index + 1))
                disks_in_vdev=$((disks_in_vdev + 1))
            done
            
            echo "  Mirror vdev $vdev_num: ${vdev_disks[*]}"
            vdev_num=$((vdev_num + 1))
        done
    else
        echo "Pool type: ${pool_type:-stripe}"
        echo "Selected disks: ${selected_disks[*]}"
    fi
    if [ ${#cache_devices[@]} -gt 0 ]; then
        echo "Cache devices: ${cache_devices[*]}"
    fi
    if [ ${#log_devices[@]} -gt 0 ]; then
        echo "Log devices: ${log_devices[*]}"
    fi
    if [ ${#spare_devices[@]} -gt 0 ]; then
        echo "Spare devices: ${spare_devices[*]}"
    fi
    echo "Options: $options"
    
    print_msg "$YELLOW" "Create the pool with these settings? (y/n)"
    read -r confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        # Construct the zpool create command
        local cmd_parts=("zpool" "create" "$pool_name")
        
        # Add options
        if [ -n "$options" ]; then
            # Split options and add them
            read -ra option_array <<< "$options"
            cmd_parts+=("${option_array[@]}")
        fi
        
        # Add pool topology based on type
        if [ "$pool_type" = "multi_mirror" ]; then
            # Multiple mirror vdevs
            local disk_index=0
            while [ $disk_index -lt ${#selected_disks[@]} ]; do
                cmd_parts+=("mirror")
                local disks_in_vdev=0
                local max_disks=$disks_per_mirror
                
                # Handle last vdev which might have fewer disks
                local remaining_disks=$((${#selected_disks[@]} - disk_index))
                if [ $remaining_disks -lt $disks_per_mirror ]; then
                    max_disks=$remaining_disks
                fi
                
                while [ $disks_in_vdev -lt $max_disks ] && [ $disk_index -lt ${#selected_disks[@]} ]; do
                    cmd_parts+=("${selected_disks[$disk_index]}")
                    disk_index=$((disk_index + 1))
                    disks_in_vdev=$((disks_in_vdev + 1))
                done
            done
        else
            # Single vdev (stripe, mirror, raidz, etc.)
            if [ -n "$pool_type" ]; then
                cmd_parts+=("$pool_type")
            fi
            cmd_parts+=("${selected_disks[@]}")
        fi
        
        # Add cache devices
        if [ ${#cache_devices[@]} -gt 0 ]; then
            cmd_parts+=("cache")
            cmd_parts+=("${cache_devices[@]}")
        fi
        
        # Add log devices
        if [ ${#log_devices[@]} -gt 0 ]; then
            cmd_parts+=("log")
            if [ ${#log_devices[@]} -gt 1 ]; then
                # Multiple log devices = mirror
                cmd_parts+=("mirror")
            fi
            cmd_parts+=("${log_devices[@]}")
        fi
        
        # Add spare devices
        if [ ${#spare_devices[@]} -gt 0 ]; then
            cmd_parts+=("spare")
            cmd_parts+=("${spare_devices[@]}")
        fi
        
        print_msg "$BLUE" "Executing: run_cmd ${cmd_parts[*]}"
        
        # Execute the command
        if run_cmd "${cmd_parts[@]}"; then
            print_msg "$GREEN" "Successfully created ZFS pool '$pool_name'."
            echo "Pool status:"
            zpool status "$pool_name"
        else
            print_msg "$RED" "Failed to create ZFS pool. See error above."
            return 1
        fi
    else
        print_msg "$YELLOW" "Pool creation cancelled."
        return 1
    fi
}

# Function to display ZFS pool status
show_pool_status() {
    if ! check_zfs_installed; then
        return 1
    fi
    
    print_msg "$BLUE" "ZFS Pool Status"
    print_msg "$BLUE" "---------------"
    
    # List all pools
    if zpool list 2>/dev/null; then
        print_msg "$YELLOW" "Enter pool name to see detailed status (or press Enter to see all):"
        read -r pool_name
        
        if [ -z "$pool_name" ]; then
            zpool status
        else
            if zpool list -H -o name 2>/dev/null | grep -q "^$pool_name$"; then
                zpool status "$pool_name"
                echo
                zfs list -r "$pool_name"
            else
                print_msg "$RED" "Pool '$pool_name' not found."
            fi
        fi
    else
        print_msg "$YELLOW" "No ZFS pools found."
    fi
}

# Function to destroy a ZFS pool
destroy_pool() {
    if ! check_zfs_installed; then
        return 1
    fi
    
    print_msg "$BLUE" "ZFS Pool Destruction"
    print_msg "$BLUE" "------------------"
    
    # List all pools
    zpool list
    
    print_msg "$YELLOW" "Enter the name of the pool to destroy:"
    read -r pool_name
    
    if [ -z "$pool_name" ]; then
        print_msg "$RED" "No pool name specified."
        return 1
    fi
    
    if ! zpool list -H -o name 2>/dev/null | grep -q "^$pool_name$"; then
        print_msg "$RED" "Pool '$pool_name' not found."
        return 1
    fi
    
    print_msg "$RED" "WARNING: This will destroy the pool '$pool_name' and all data it contains!"
    print_msg "$RED" "Type the pool name again to confirm:"
    read -r confirm_name
    
    if [ "$pool_name" != "$confirm_name" ]; then
        print_msg "$YELLOW" "Pool names do not match. Operation cancelled."
        return 1
    fi
    
    print_msg "$YELLOW" "Force destruction? (y/n)"
    read -r force_choice
    
    local force_option=""
    if [[ $force_choice =~ ^[Yy]$ ]]; then
        force_option="-f"
    fi
    
    print_msg "$BLUE" "Executing: run_cmd zpool destroy $force_option $pool_name"
    
    if run_cmd zpool destroy $force_option "$pool_name"; then
        print_msg "$GREEN" "Successfully destroyed ZFS pool '$pool_name'."
    else
        print_msg "$RED" "Failed to destroy ZFS pool. See error above."
        return 1
    fi
}

# Function to export and import a ZFS pool
export_import_pool() {
    if ! check_zfs_installed; then
        return 1
    fi
    
    print_msg "$BLUE" "ZFS Pool Export/Import"
    print_msg "$BLUE" "---------------------"
    
    echo "1) Export a pool"
    echo "2) Import a pool"
    read -r export_import_choice
    
    case $export_import_choice in
        1)
            # Export pool
            zpool list
            
            print_msg "$YELLOW" "Enter the name of the pool to export:"
            read -r pool_name
            
            if [ -z "$pool_name" ]; then
                print_msg "$RED" "No pool name specified."
                return 1
            fi
            
            if ! zpool list -H -o name 2>/dev/null | grep -q "^$pool_name$"; then
                print_msg "$RED" "Pool '$pool_name' not found."
                return 1
            fi
            
            print_msg "$YELLOW" "Force export? (y/n)"
            read -r force_choice
            
            local force_option=""
            if [[ $force_choice =~ ^[Yy]$ ]]; then
                force_option="-f"
            fi
            
            print_msg "$BLUE" "Executing: run_cmd zpool export $force_option $pool_name"
            
            if run_cmd zpool export $force_option "$pool_name"; then
                print_msg "$GREEN" "Successfully exported ZFS pool '$pool_name'."
            else
                print_msg "$RED" "Failed to export ZFS pool. See error above."
                return 1
            fi
            ;;
            
        2)
            # Import pool
            print_msg "$BLUE" "Scanning for importable pools..."
            
            if ! run_cmd zpool import; then
                print_msg "$RED" "No importable pools found or error scanning."
                return 1
            fi
            
            print_msg "$YELLOW" "Enter the name of the pool to import:"
            read -r pool_name
            
            if [ -z "$pool_name" ]; then
                print_msg "$RED" "No pool name specified."
                return 1
            fi
            
            print_msg "$YELLOW" "Import with a different name? (y/n)"
            read -r rename_choice
            
            if [[ $rename_choice =~ ^[Yy]$ ]]; then
                print_msg "$YELLOW" "Enter new pool name:"
                read -r new_name
                if [ -n "$new_name" ]; then
                    print_msg "$BLUE" "Executing: run_cmd zpool import $pool_name $new_name"
                    
                    if run_cmd zpool import "$pool_name" "$new_name"; then
                        print_msg "$GREEN" "Successfully imported ZFS pool as '$new_name'."
                    else
                        print_msg "$RED" "Failed to import ZFS pool. See error above."
                        return 1
                    fi
                else
                    print_msg "$RED" "No new pool name provided."
                    return 1
                fi
            else
                print_msg "$BLUE" "Executing: run_cmd zpool import $pool_name"
                
                if run_cmd zpool import "$pool_name"; then
                    print_msg "$GREEN" "Successfully imported ZFS pool '$pool_name'."
                else
                    print_msg "$RED" "Failed to import ZFS pool. See error above."
                    return 1
                fi
            fi
            ;;
            
        *)
            print_msg "$RED" "Invalid selection."
            return 1
            ;;
    esac
}

# Function to scrub a ZFS pool
scrub_pool() {
    if ! check_zfs_installed; then
        return 1
    fi
    
    print_msg "$BLUE" "ZFS Pool Scrub"
    print_msg "$BLUE" "--------------"
    
    # List all pools
    zpool list
    
    print_msg "$YELLOW" "Enter the name of the pool to scrub:"
    read -r pool_name
    
    if [ -z "$pool_name" ]; then
        print_msg "$RED" "No pool name specified."
        return 1
    fi
    
    if ! zpool list -H -o name 2>/dev/null | grep -q "^$pool_name$"; then
        print_msg "$RED" "Pool '$pool_name' not found."
        return 1
    fi
    
    print_msg "$BLUE" "Executing: run_cmd zpool scrub $pool_name"
    
    if run_cmd zpool scrub "$pool_name"; then
        print_msg "$GREEN" "Scrub started on pool '$pool_name'."
        print_msg "$GREEN" "You can check the status with 'zpool status $pool_name'."
    else
        print_msg "$RED" "Failed to start scrub. See error above."
        return 1
    fi
}

# Function to add/remove devices to/from existing ZFS pool
manage_pool_devices() {
    if ! check_zfs_installed; then
        return 1
    fi
    
    print_msg "$BLUE" "Manage Devices in Existing ZFS Pool"
    print_msg "$BLUE" "==================================="
    
    # List existing pools
    if ! zpool list 2>/dev/null | grep -q .; then
        print_msg "$RED" "No ZFS pools found."
        return 1
    fi
    
    print_msg "$GREEN" "Existing ZFS pools:"
    zpool list -o name,size,allocated,free,health
    echo
    
    print_msg "$YELLOW" "Enter the name of the pool to modify:"
    read -r pool_name
    
    if [ -z "$pool_name" ]; then
        print_msg "$RED" "No pool name specified."
        return 1
    fi
    
    # Verify pool exists
    if ! zpool list -H -o name 2>/dev/null | grep -q "^$pool_name$"; then
        print_msg "$RED" "Pool '$pool_name' not found."
        return 1
    fi
    
    # Show current pool status
    print_msg "$BLUE" "Current pool status:"
    zpool status "$pool_name"
    echo
    
    # Ask whether to add or remove devices
    print_msg "$YELLOW" "What do you want to do?"
    echo "1) Add devices to pool"
    echo "2) Remove devices from pool"
    read -r action_choice
    
    case $action_choice in
        1) add_devices_action "$pool_name" ;;
        2) remove_devices_action "$pool_name" ;;
        *) print_msg "$RED" "Invalid selection."; return 1 ;;
    esac
}

# Function to handle adding devices
add_devices_action() {
    local pool_name="$1"
    
    # Ask what type of device to add
    print_msg "$YELLOW" "What type of device do you want to add?"
    echo "1) Cache device (L2ARC) - for read acceleration"
    echo "2) Log device (SLOG/ZIL) - for write acceleration" 
    echo "3) Spare device - hot spare for automatic failover"
    echo "4) Data device (vdev expansion) - add more storage"
    read -r device_type_choice
    
    case $device_type_choice in
        1) device_type="cache"; device_description="cache (L2ARC)" ;;
        2) device_type="log"; device_description="log (SLOG/ZIL)" ;;
        3) device_type="spare"; device_description="spare" ;;
        4) device_type="data"; device_description="data vdev" ;;
        *) print_msg "$RED" "Invalid selection."; return 1 ;;
    esac
    
    # Function to check if a device is already in any ZFS pool
    is_device_in_any_pool() {
        local device_path="$1"
        local device_basename=$(basename "$device_path")
        
        # Get all devices from all pools
        local pool_devices
        pool_devices=$(zpool status 2>/dev/null | grep -E "^\s+" | awk '{print $1}' | grep -v "pool:\|state:\|config:\|errors:\|NAME\|mirror-\|raidz")
        
        while IFS= read -r pool_device; do
            [[ -z "$pool_device" ]] && continue
            
            # Check direct match or basename match
            if [[ "$device_path" == "$pool_device" ]] || [[ "$device_basename" == "$(basename "$pool_device")" ]]; then
                return 0
            fi
            
            # Check if pool device is disk-by-id format and build full path to compare
            if [[ "$pool_device" =~ ^(scsi-|ata-|wwn-|nvme-) ]]; then
                local full_pool_path="/dev/disk/by-id/$pool_device"
                if [[ "$device_path" == "$full_pool_path" ]]; then
                    return 0
                fi
            fi
        done <<< "$pool_devices"
        
        return 1
    }
    
    # Function to show available devices for addition (adapted from working pool creation logic)
    show_available_devices_for_addition() {
        print_msg "$BLUE" "Available devices for $device_description (excluding devices already in use):"
        
        local found_any=false
        
        while IFS= read -r disk_path; do
            local disk_basename=$(basename "$disk_path")
            if [[ ! "$disk_basename" =~ -part[0-9]+$ ]] && [[ ! "$disk_basename" =~ cdrom|dvd ]] && [[ -b "$(readlink -f "$disk_path" 2>/dev/null)" ]]; then
                if ! is_device_in_any_pool "$disk_path"; then
                    local canonical_path=$(readlink -f "$disk_path")
                    # Get size and model info
                    local size model
                    if { read -r size model; } 2>/dev/null < <(lsblk -d -n -o SIZE,MODEL "$canonical_path" 2>/dev/null); then
                        size="${size// /}"
                        model="${model// /}"
                        [[ -z "$model" ]] && model="Unknown"
                        printf "  %-60s (%s, %s, %s)\n" "$disk_basename" "$canonical_path" "$size" "$model"
                        found_any=true
                    fi
                fi
            fi
        done < <(find /dev/disk/by-id -maxdepth 1 -type l 2>/dev/null | sort)
        
        if [ "$found_any" = false ]; then
            print_msg "$YELLOW" "  No available devices found."
            return 1
        fi
        
        return 0
    }
    
    # Show available devices
    if ! show_available_devices_for_addition; then
        print_msg "$RED" "No devices available to add. All devices may already be in use."
        return 1
    fi
    
    echo
    
    # Handle different device types for adding
    case $device_type in
        "cache"|"spare")
            print_msg "$YELLOW" "Enter device ID(s) to add as $device_description (space-separated):"
            read -r device_input
            
            if [ -z "$device_input" ]; then
                print_msg "$RED" "No devices specified."
                return 1
            fi
            
            # Build device paths
            devices_to_add=()
            for device in $device_input; do
                full_path="/dev/disk/by-id/$device"
                if [ -L "$full_path" ]; then
                    devices_to_add+=("$full_path")
                else
                    print_msg "$RED" "Device '$device' not found."
                    return 1
                fi
            done
            
            # Confirm and execute
            print_msg "$BLUE" "Adding ${#devices_to_add[@]} $device_description device(s) to pool '$pool_name':"
            for device in "${devices_to_add[@]}"; do
                echo "  - $device"
            done
            
            print_msg "$YELLOW" "Proceed with adding these devices? (y/n)"
            read -r confirm
            
            if [[ $confirm =~ ^[Yy]$ ]]; then
                cmd_parts=("zpool" "add" "$pool_name" "$device_type")
                cmd_parts+=("${devices_to_add[@]}")
                
                print_msg "$BLUE" "Executing: run_cmd ${cmd_parts[*]}"
                
                if run_cmd "${cmd_parts[@]}"; then
                    print_msg "$GREEN" "Successfully added $device_description device(s) to pool '$pool_name'."
                    echo "Updated pool status:"
                    zpool status "$pool_name"
                else
                    print_msg "$RED" "Failed to add devices. See error above."
                    return 1
                fi
            else
                print_msg "$YELLOW" "Operation cancelled."
            fi
            ;;
            
        "log")
            print_msg "$BLUE" "Log devices can be single or mirrored for redundancy."
            print_msg "$YELLOW" "How many log devices do you want to add? (1 for single, 2+ for mirror):"
            read -r log_count
            
            while ! [[ $log_count =~ ^[0-9]+$ ]] || [ $log_count -eq 0 ]; do
                print_msg "$RED" "Please enter a valid number (1 or higher):"
                read -r log_count
            done
            
            print_msg "$YELLOW" "Enter $log_count log device ID(s) (space-separated):"
            read -r device_input
            
            device_array=($device_input)
            while [ ${#device_array[@]} -ne $log_count ]; do
                print_msg "$RED" "Expected $log_count devices but got ${#device_array[@]}. Please try again:"
                read -r device_input
                device_array=($device_input)
            done
            
            # Build device paths
            devices_to_add=()
            for device in "${device_array[@]}"; do
                full_path="/dev/disk/by-id/$device"
                if [ -L "$full_path" ]; then
                    devices_to_add+=("$full_path")
                else
                    print_msg "$RED" "Device '$device' not found."
                    return 1
                fi
            done
            
            # Confirm and execute
            print_msg "$BLUE" "Adding ${#devices_to_add[@]} log device(s) to pool '$pool_name':"
            for device in "${devices_to_add[@]}"; do
                echo "  - $device"
            done
            
            print_msg "$YELLOW" "Proceed with adding these log devices? (y/n)"
            read -r confirm
            
            if [[ $confirm =~ ^[Yy]$ ]]; then
                cmd_parts=("zpool" "add" "$pool_name" "log")
                
                # Add mirror keyword if multiple devices
                if [ ${#devices_to_add[@]} -gt 1 ]; then
                    cmd_parts+=("mirror")
                fi
                
                cmd_parts+=("${devices_to_add[@]}")
                
                print_msg "$BLUE" "Executing: run_cmd ${cmd_parts[*]}"
                
                if run_cmd "${cmd_parts[@]}"; then
                    print_msg "$GREEN" "Successfully added log device(s) to pool '$pool_name'."
                    echo "Updated pool status:"
                    zpool status "$pool_name"
                else
                    print_msg "$RED" "Failed to add log devices. See error above."
                    return 1
                fi
            else
                print_msg "$YELLOW" "Operation cancelled."
            fi
            ;;
            
        "data")
            print_msg "$BLUE" "Adding data devices will expand the pool's storage capacity."
            print_msg "$YELLOW" "What type of vdev do you want to add?"
            echo "1) Single disk (stripe) - no redundancy, maximum space"
            echo "2) Mirror vdev - redundancy with 2+ disks"
            echo "3) RAIDZ vdev - parity protection with 3+ disks"
            echo "4) RAIDZ2 vdev - double parity with 4+ disks"
            echo "5) RAIDZ3 vdev - triple parity with 5+ disks"
            read -r vdev_type_choice
            
            case $vdev_type_choice in
                1) vdev_type=""; vdev_name="stripe"; min_disks=1 ;;
                2) vdev_type="mirror"; vdev_name="mirror"; min_disks=2 ;;
                3) vdev_type="raidz"; vdev_name="raidz"; min_disks=3 ;;
                4) vdev_type="raidz2"; vdev_name="raidz2"; min_disks=4 ;;
                5) vdev_type="raidz3"; vdev_name="raidz3"; min_disks=5 ;;
                *) print_msg "$RED" "Invalid selection."; return 1 ;;
            esac
            
            print_msg "$YELLOW" "Enter device ID(s) for the new $vdev_name vdev (space-separated, minimum $min_disks):"
            read -r device_input
            
            device_array=($device_input)
            if [ ${#device_array[@]} -lt $min_disks ]; then
                print_msg "$RED" "$vdev_name vdev requires at least $min_disks disk(s)."
                return 1
            fi
            
            # Build device paths
            devices_to_add=()
            for device in "${device_array[@]}"; do
                full_path="/dev/disk/by-id/$device"
                if [ -L "$full_path" ]; then
                    devices_to_add+=("$full_path")
                else
                    print_msg "$RED" "Device '$device' not found."
                    return 1
                fi
            done
            
            # Confirm and execute
            print_msg "$BLUE" "Adding $vdev_name vdev with ${#devices_to_add[@]} device(s) to pool '$pool_name':"
            for device in "${devices_to_add[@]}"; do
                echo "  - $device"
            done
            
            print_msg "$YELLOW" "Proceed with adding this vdev? (y/n)"
            read -r confirm
            
            if [[ $confirm =~ ^[Yy]$ ]]; then
                cmd_parts=("zpool" "add" "$pool_name")
                
                # Add vdev type if not stripe
                if [ -n "$vdev_type" ]; then
                    cmd_parts+=("$vdev_type")
                fi
                
                cmd_parts+=("${devices_to_add[@]}")
                
                print_msg "$BLUE" "Executing: run_cmd ${cmd_parts[*]}"
                
                if run_cmd "${cmd_parts[@]}"; then
                    print_msg "$GREEN" "Successfully added $vdev_name vdev to pool '$pool_name'."
                    echo "Updated pool status:"
                    zpool status "$pool_name"
                else
                    print_msg "$RED" "Failed to add vdev. See error above."
                    return 1
                fi
            else
                print_msg "$YELLOW" "Operation cancelled."
            fi
            ;;
    esac
}

# Function to handle removing devices
remove_devices_action() {
    local pool_name="$1"
    
    print_msg "$BLUE" "Device Removal from Pool '$pool_name'"
    print_msg "$BLUE" "======================================"
    
    # Get current pool devices categorized by type
    print_msg "$YELLOW" "Current devices in pool '$pool_name':"
    
    # Parse zpool status to categorize devices and detect vdev structure
    local cache_devices=()
    local log_devices=()
    local spare_devices=()
    local data_devices=()
    local log_vdevs=()  # Track complete log vdevs
    local current_section="data"
    local current_vdev=""
    local current_vdev_devices=()
    
    while IFS= read -r line; do
        # Detect sections by looking for section headers
        if [[ "$line" =~ ^[[:space:]]*cache[[:space:]]*$ ]]; then
            current_section="cache"
            current_vdev=""
            continue
        elif [[ "$line" =~ ^[[:space:]]*logs[[:space:]]*$ ]]; then
            current_section="logs"
            current_vdev=""
            continue
        elif [[ "$line" =~ ^[[:space:]]*spares[[:space:]]*$ ]]; then
            current_section="spares"
            current_vdev=""
            continue
        elif [[ "$line" =~ ^[[:space:]]*pool:[[:space:]] ]]; then
            current_section="data"
            current_vdev=""
            continue
        elif [[ "$line" =~ ^[[:space:]]*config:[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*NAME[[:space:]] ]]; then
            current_section="data"
            current_vdev=""
            continue
        fi
        
        # Detect vdev labels (mirror-X, raidz-X) in logs section
        if [[ "$current_section" == "logs" ]] && [[ "$line" =~ ^[[:space:]]+(mirror-|raidz)[0-9]+ ]]; then
            # Save previous vdev if exists
            if [[ -n "$current_vdev" ]] && [[ ${#current_vdev_devices[@]} -gt 0 ]]; then
                log_vdevs+=("$current_vdev:${current_vdev_devices[*]}")
            fi
            
            current_vdev=$(echo "$line" | awk '{print $1}')
            current_vdev_devices=()
            continue
        fi
        
        # Extract device names
        if [[ "$line" =~ ^[[:space:]]+(scsi-|ata-|wwn-|nvme-|/dev/) ]]; then
            local device=$(echo "$line" | awk '{print $1}')
            [[ -z "$device" ]] && continue
            
            case $current_section in
                "cache") cache_devices+=("$device") ;;
                "logs") 
                    if [[ -n "$current_vdev" ]]; then
                        current_vdev_devices+=("$device")
                    else
                        log_devices+=("$device")  # Single log device
                    fi
                    ;;
                "spares") spare_devices+=("$device") ;;
                "data") data_devices+=("$device") ;;
            esac
        fi
    done < <(zpool status "$pool_name")
    
    # Save the last log vdev if exists
    if [[ -n "$current_vdev" ]] && [[ ${#current_vdev_devices[@]} -gt 0 ]]; then
        log_vdevs+=("$current_vdev:${current_vdev_devices[*]}")
    fi
    
    # Show removable devices by category
    local removable_found=false
    
    if [ ${#cache_devices[@]} -gt 0 ]; then
        print_msg "$GREEN" "Cache devices (safe to remove):"
        for i in "${!cache_devices[@]}"; do
            printf "  c%d) %s\n" "$i" "${cache_devices[$i]}"
        done
        removable_found=true
    fi
    
    # Handle log devices (both individual and vdevs)
    if [ ${#log_devices[@]} -gt 0 ] || [ ${#log_vdevs[@]} -gt 0 ]; then
        print_msg "$GREEN" "Log devices (safe to remove):"
        
        # Show individual log devices
        for i in "${!log_devices[@]}"; do
            printf "  l%d) %s (individual device)\n" "$i" "${log_devices[$i]}"
        done
        
        # Show log vdevs (mirrors/raidz)
        for i in "${!log_vdevs[@]}"; do
            local vdev_info="${log_vdevs[$i]}"
            local vdev_name="${vdev_info%%:*}"
            local vdev_devices="${vdev_info##*:}"
            printf "  v%d) %s (complete vdev: %s)\n" "$i" "$vdev_name" "$vdev_devices"
        done
        
        removable_found=true
    fi
    
    if [ ${#spare_devices[@]} -gt 0 ]; then
        print_msg "$GREEN" "Spare devices (safe to remove):"
        for i in "${!spare_devices[@]}"; do
            printf "  s%d) %s\n" "$i" "${spare_devices[$i]}"
        done
        removable_found=true
    fi
    
    if [ ${#data_devices[@]} -gt 0 ]; then
        print_msg "$YELLOW" "Data devices (removal requires caution - only complete vdevs can be removed):"
        for i in "${!data_devices[@]}"; do
            printf "  d%d) %s\n" "$i" "${data_devices[$i]}"
        done
    fi
    
    if [ "$removable_found" = false ]; then
        print_msg "$YELLOW" "No safely removable devices found (cache/log/spare)."
        print_msg "$YELLOW" "Data device removal requires advanced knowledge and may not be supported."
        return 0
    fi
    
    echo
    print_msg "$BLUE" "IMPORTANT: For mirrored log devices, you must remove the entire vdev (v0, v1, etc.)"
    print_msg "$BLUE" "Individual devices (l0, l1) can only be removed if they're not part of a mirror."
    echo
    print_msg "$YELLOW" "Enter device identifier to remove:"
    print_msg "$YELLOW" "  - 'c0' for cache device"
    print_msg "$YELLOW" "  - 'l0' for individual log device"  
    print_msg "$YELLOW" "  - 'v0' for complete log vdev (mirror/raidz)"
    print_msg "$YELLOW" "  - 's0' for spare device"
    print_msg "$YELLOW" "  - 'q' to quit:"
    read -r device_selection
    
    if [ "$device_selection" = "q" ]; then
        print_msg "$GREEN" "Operation cancelled."
        return 0
    fi
    
    # Parse selection
    local device_to_remove=""
    local removal_type=""
    local device_description=""
    
    if [[ "$device_selection" =~ ^c([0-9]+)$ ]]; then
        local index=${BASH_REMATCH[1]}
        if [ $index -lt ${#cache_devices[@]} ]; then
            device_to_remove="${cache_devices[$index]}"
            removal_type="device"
            device_description="cache device"
        fi
    elif [[ "$device_selection" =~ ^l([0-9]+)$ ]]; then
        local index=${BASH_REMATCH[1]}
        if [ $index -lt ${#log_devices[@]} ]; then
            device_to_remove="${log_devices[$index]}"
            removal_type="device"
            device_description="log device"
        fi
    elif [[ "$device_selection" =~ ^v([0-9]+)$ ]]; then
        local index=${BASH_REMATCH[1]}
        if [ $index -lt ${#log_vdevs[@]} ]; then
            local vdev_info="${log_vdevs[$index]}"
            device_to_remove="${vdev_info%%:*}"  # Get vdev name (mirror-X)
            removal_type="vdev"
            device_description="log vdev"
        fi
    elif [[ "$device_selection" =~ ^s([0-9]+)$ ]]; then
        local index=${BASH_REMATCH[1]}
        if [ $index -lt ${#spare_devices[@]} ]; then
            device_to_remove="${spare_devices[$index]}"
            removal_type="device"
            device_description="spare device"
        fi
    elif [[ "$device_selection" =~ ^d([0-9]+)$ ]]; then
        print_msg "$RED" "Data device removal is complex and potentially dangerous."
        print_msg "$RED" "This requires advanced ZFS knowledge. Please use manual zpool remove commands."
        return 1
    fi
    
    if [ -z "$device_to_remove" ]; then
        print_msg "$RED" "Invalid selection: $device_selection"
        return 1
    fi
    
    # Confirm removal
    if [ "$removal_type" = "vdev" ]; then
        print_msg "$BLUE" "About to remove complete $device_description: $device_to_remove"
        print_msg "$YELLOW" "This will remove the entire mirrored log vdev and all its devices."
        print_msg "$YELLOW" "The pool will fall back to using main storage for the intent log."
    else
        print_msg "$BLUE" "About to remove $device_description: $device_to_remove"
        print_msg "$YELLOW" "This is generally safe for cache/log/spare devices."
    fi
    
    print_msg "$YELLOW" "Are you sure you want to remove this ${removal_type}? (y/n)"
    read -r confirm
    
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        print_msg "$YELLOW" "Operation cancelled."
        return 0
    fi
    
    # Execute removal
    print_msg "$BLUE" "Executing: run_cmd zpool remove $pool_name $device_to_remove"
    
    if run_cmd zpool remove "$pool_name" "$device_to_remove"; then
        print_msg "$GREEN" "Successfully removed $device_description '$device_to_remove' from pool '$pool_name'."
        echo "Updated pool status:"
        zpool status "$pool_name"
        if [ "$removal_type" = "vdev" ]; then
            print_msg "$GREEN" "All devices from the removed vdev are now available for other uses."
        else
            print_msg "$GREEN" "The removed device is now available for other uses."
        fi
    else
        print_msg "$RED" "Failed to remove ${removal_type}. See error above."
        
        if [ "$removal_type" = "device" ] && [[ "$device_description" == *"log"* ]]; then
            print_msg "$YELLOW" "Note: If this log device is part of a mirror, you need to remove the entire vdev."
            print_msg "$YELLOW" "Try using a 'v' selection instead (e.g., 'v0' for the complete log vdev)."
        fi
        
        return 1
    fi
}

# Main menu function
main_menu() {
    while true; do
        clear
        echo "=========================================="
        echo "          ZFS Pool Creation Helper        "
        echo "=========================================="
        echo
        echo "1) Check ZFS installation"
        echo "2) Check ZFS version"
        echo "3) List disks by ID"
        echo "4) Show detailed disk information"
        echo "5) Zap/Wipe disks"
        echo "6) Create a ZFS pool"
        echo "7) Show ZFS pool status"
        echo "8) Destroy a ZFS pool"
        echo "9) Export/Import a ZFS pool"
        echo "10) Scrub a ZFS pool"
        echo "11) Manage pool devices (add/remove)"
        echo "0) Exit"
        echo
        print_msg "$YELLOW" "Enter your choice [0-11]:"
        read -r choice
        
        case $choice in
            1) check_zfs_installed ;;
            2) check_zfs_version ;;
            3) list_disks_by_id ;;
            4) show_disk_info ;;
            5) zap_disks ;;
            6) create_zfs_pool ;;
            7) show_pool_status ;;
            8) destroy_pool ;;
            9) export_import_pool ;;
            10) scrub_pool ;;
            11) manage_pool_devices ;;
            0) echo "Exiting."; exit 0 ;;
            *) print_msg "$RED" "Invalid choice. Please try again." ;;
        esac
        
        echo
        print_msg "$YELLOW" "Press Enter to continue..."
        read -r
    done
}

# Script entry point
main_menu
