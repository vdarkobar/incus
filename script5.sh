#!/bin/bash

# ZFS Pool Creation Helper Script
# This script helps with creating ZFS pools by providing various utilities
# such as checking ZFS installation, listing disks, and assisting with pool creation.

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

# Function to check if ZFS is installed
check_zfs_installed() {
    print_msg "$BLUE" "Checking if ZFS is installed..."
    
    if command -v zpool &> /dev/null && command -v zfs &> /dev/null; then
        print_msg "$GREEN" "✓ ZFS is installed."
        return 0
    else
        print_msg "$RED" "✗ ZFS is not installed."
        
        # Suggest installation method based on detected OS
        if [ -f /etc/debian_version ]; then
            print_msg "$YELLOW" "To install ZFS on Debian/Ubuntu, run:"
            echo "sudo apt update && sudo apt install zfsutils-linux"
        elif [ -f /etc/redhat-release ]; then
            print_msg "$YELLOW" "To install ZFS on RHEL/CentOS/Fedora, run:"
            echo "sudo dnf install epel-release"
            echo "sudo dnf install zfs"
        elif [ -f /etc/arch-release ]; then
            print_msg "$YELLOW" "To install ZFS on Arch Linux, run:"
            echo "sudo pacman -S zfs-dkms zfs-utils"
        else
            print_msg "$YELLOW" "Please install ZFS according to your distribution's documentation."
        fi
        
        return 1
    fi
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

# Function to list all disks by ID
list_disks_by_id() {
    print_msg "$BLUE" "Listing all disks by ID..."
    
    if [ -d /dev/disk/by-id ]; then
        local disk_ids=(/dev/disk/by-id/*)
        
        if [ ${#disk_ids[@]} -eq 0 ]; then
            print_msg "$YELLOW" "No disks found by ID."
            return 1
        fi
        
        print_msg "$GREEN" "Found ${#disk_ids[@]} disk IDs:"
        
        printf "%-60s %-20s %-10s %-20s\n" "DISK ID" "DEVICE" "SIZE" "MODEL"
        echo "----------------------------------------------------------------------------------------------------"
        
        for disk_id in "${disk_ids[@]}"; do
            # Skip partitions and CD-ROM/DVD devices
            if [[ "$disk_id" == *"-part"* ]] || [[ "$disk_id" == *"cd"* ]] || [[ "$disk_id" == *"dvd"* ]]; then
                continue
            fi
            
            local real_device=$(readlink -f "$disk_id")
            local disk_name=$(basename "$real_device")
            
            # Get disk size and model
            if [[ -b "$real_device" ]]; then
                local size=$(lsblk -bno SIZE "$real_device" 2>/dev/null | head -n1)
                local size_human=$(numfmt --to=iec-i --suffix=B --format="%.2f" "$size" 2>/dev/null || echo "Unknown")
                local model=$(lsblk -no MODEL "$real_device" 2>/dev/null | head -n1)
                
                # Shorten disk_id for display
                local short_id=$(basename "$disk_id")
                
                printf "%-60s %-20s %-10s %-20s\n" "$short_id" "$real_device" "$size_human" "$model"
            fi
        done
    else
        print_msg "$RED" "Cannot list disks by ID - directory /dev/disk/by-id not found."
        print_msg "$YELLOW" "Falling back to listing all block devices:"
        
        printf "%-20s %-10s %-20s %-30s\n" "DEVICE" "SIZE" "MODEL" "MOUNTPOINT"
        echo "--------------------------------------------------------------------------------"
        
        lsblk -o NAME,SIZE,MODEL,MOUNTPOINT | grep -v "loop"
        
        return 1
    fi
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
    sudo fdisk -l "/dev/$disk_name" 2>/dev/null || print_msg "$YELLOW" "Cannot get partition info (requires sudo)."
    
    echo -e "\nSMART INFO (if available):"
    if command -v smartctl &> /dev/null; then
        sudo smartctl -a "/dev/$disk_name" 2>/dev/null || print_msg "$YELLOW" "Cannot get SMART info (requires sudo or smartmontools)."
    else
        print_msg "$YELLOW" "smartmontools not installed. Install with: sudo apt install smartmontools"
    fi
}

# Function to check if disks are in use
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
    if zpool list -H -o name | grep -q "^$pool_name$"; then
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
        for disk in $selected_disks_input; do
            full_path="/dev/disk/by-id/$disk"
            if [ -L "$full_path" ]; then
                selected_disks+=("$full_path")
            else
                print_msg "$RED" "Disk ID '$disk' not found. Please verify the ID."
                return 1
            fi
        done
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
    
    # Check minimum disk requirements based on pool type
    case $pool_type in
        "mirror")
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
    
    # Step 4: Additional options
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
        
        print_msg "$YELLOW" "Additional custom options (e.g., '-O recordsize=128K'):"
        read -r custom_options
        if [ -n "$custom_options" ]; then
            options="$options $custom_options"
        fi
    else
        # Set some sensible defaults
        options="-o ashift=12 -O compression=lz4 -O atime=off"
    fi
    
    # Step 5: Review and confirm
    print_msg "$BLUE" "Pool Creation Summary:"
    echo "Pool name: $pool_name"
    echo "Pool type: ${pool_type:-stripe}"
    echo "Selected disks: ${selected_disks[*]}"
    echo "Options: $options"
    
    print_msg "$YELLOW" "Create the pool with these settings? (y/n)"
    read -r confirm
    
    if [[ $confirm =~ ^[Yy]$ ]]; then
        # Construct the zpool create command
        cmd="sudo zpool create $options $pool_name"
        if [ -n "$pool_type" ]; then
            cmd="$cmd $pool_type"
        fi
        
        for disk in "${selected_disks[@]}"; do
            cmd="$cmd $disk"
        done
        
        print_msg "$BLUE" "Executing: $cmd"
        
        # Execute the command
        if eval "$cmd"; then
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
            if zpool list -H -o name | grep -q "^$pool_name$"; then
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
    
    if ! zpool list -H -o name | grep -q "^$pool_name$"; then
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
    
    print_msg "$BLUE" "Executing: sudo zpool destroy $force_option $pool_name"
    
    if sudo zpool destroy $force_option "$pool_name"; then
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
            
            if ! zpool list -H -o name | grep -q "^$pool_name$"; then
                print_msg "$RED" "Pool '$pool_name' not found."
                return 1
            fi
            
            print_msg "$YELLOW" "Force export? (y/n)"
            read -r force_choice
            
            local force_option=""
            if [[ $force_choice =~ ^[Yy]$ ]]; then
                force_option="-f"
            fi
            
            print_msg "$BLUE" "Executing: sudo zpool export $force_option $pool_name"
            
            if sudo zpool export $force_option "$pool_name"; then
                print_msg "$GREEN" "Successfully exported ZFS pool '$pool_name'."
            else
                print_msg "$RED" "Failed to export ZFS pool. See error above."
                return 1
            fi
            ;;
            
        2)
            # Import pool
            print_msg "$BLUE" "Scanning for importable pools..."
            
            if ! sudo zpool import; then
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
            
            local rename_option=""
            if [[ $rename_choice =~ ^[Yy]$ ]]; then
                print_msg "$YELLOW" "Enter new pool name:"
                read -r new_name
                if [ -n "$new_name" ]; then
                    rename_option="-n $new_name"
                fi
            fi
            
            print_msg "$BLUE" "Executing: sudo zpool import $rename_option $pool_name"
            
            if sudo zpool import $rename_option "$pool_name"; then
                print_msg "$GREEN" "Successfully imported ZFS pool."
            else
                print_msg "$RED" "Failed to import ZFS pool. See error above."
                return 1
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
    
    if ! zpool list -H -o name | grep -q "^$pool_name$"; then
        print_msg "$RED" "Pool '$pool_name' not found."
        return 1
    fi
    
    print_msg "$BLUE" "Executing: sudo zpool scrub $pool_name"
    
    if sudo zpool scrub "$pool_name"; then
        print_msg "$GREEN" "Scrub started on pool '$pool_name'."
        print_msg "$GREEN" "You can check the status with 'zpool status $pool_name'."
    else
        print_msg "$RED" "Failed to start scrub. See error above."
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
        echo "5) Create a ZFS pool"
        echo "6) Show ZFS pool status"
        echo "7) Destroy a ZFS pool"
        echo "8) Export/Import a ZFS pool"
        echo "9) Scrub a ZFS pool"
        echo "0) Exit"
        echo
        print_msg "$YELLOW" "Enter your choice [0-9]:"
        read -r choice
        
        case $choice in
            1) check_zfs_installed ;;
            2) check_zfs_version ;;
            3) list_disks_by_id ;;
            4) show_disk_info ;;
            5) create_zfs_pool ;;
            6) show_pool_status ;;
            7) destroy_pool ;;
            8) export_import_pool ;;
            9) scrub_pool ;;
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
