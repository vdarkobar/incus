## Incus installer script, Debian  
  
Create ZFS Pool and Incus Dataset, example:  
```bash
sudo zpool create -f \
  -o ashift=12 \
  -o autoexpand=on \
  -O atime=off \
  -O compression=lz4 \
  local \
  raidz \
  /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 \
  /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2 \
  /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3
# or:
  local \
  mirror \
    /dev/disk/by-id/ata-INTEL_SSDSC2KG480G8_BTYG949401V3480BGN \
    /dev/disk/by-id/ata-INTEL_SSDSC2KG480G8_BTYG950309V8480BGN \
  mirror \
    /dev/disk/by-id/ata-INTEL_SSDSC2KG480G8_BTYG950309WQ480BGN \
    /dev/disk/by-id/ata-INTEL_SSDSC2KG480G8_BTYG95030BHC480BGN 
```
```bash
sudo zpool add -f local cache /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi4
sudo zpool add -f local spare /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi5
```
```bash
sudo zfs create local/incus -o mountpoint=/mnt/incus
```  

Point Incus to ZFS Dataset during init phase  

  <br/>

###  *Incus installer script*:
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/vdarkobar/incus/main/script.sh)"
```

<br/>

*ZFS Setup*
- **Debian Version & Backports:** Detects Debian version, adds backports repo for ZFS.  
- **Install ZFS:** Updates package list, installs `zfs-dkms`, `zfsutils-linux`.  
- **Enable ZFS Services:** Ensures ZFS services start on boot.  
- **Configure ZFS ARC:** Sets ARC max to 20% of RAM (capped at 16 GiB). Writes configuration to `/etc/modprobe.d/zfs.conf` for persistence.  

*KVM Setup*
- **Virtualization Check:** Verifies CPU virtualization support (VT-x/AMD-V).  
- **Install KVM & Tools:** Installs `qemu-kvm`, `libvirt`, and related packages.  
- **User Access:** Adds current user to `kvm` and `libvirt` groups.  
- **Enable Libvirt:** Ensures `libvirtd` service runs at boot.  

*Incus Setup*
- **Install Prerequisites:** Installs `gnupg2`, `wget`.  
- **Add Incus Repo:** Downloads Zabbly keys, configures source list.  
- **Install Incus:** Installs `incus`, `incus-ui-canonical`.  
- **GUI Support (Optional):** Installs `virt-viewer` if not headless.
- **User Permissions:** Adds user to `incus-admin` group.  
  
<br/>
  
Initialize Incus
```bash
incus admin init
```  

Create **bridge interface** on the host machine (two network ports, first for host, second for the bridge, instance gets IP from the physical network, not internal subnet) 
```bash
sudo nano /etc/network/interfaces
```

Replace or add the following configuration:
```bash
# This file describes the network interfaces available on your system
# and how to activate them. For more information, see interfaces(5).

source /etc/network/interfaces.d/*

# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface (host connectivity)
allow-hotplug ens18
iface ens18 inet dhcp

# Bridge interface for Incus containers/VMs
auto br0
iface br0 inet dhcp
    bridge_ports ens19
    bridge_stp off
    bridge_fd 0
    bridge_maxwait 0
```

Restart the networking service:
```bash
sudo systemctl restart networking.service
```

Check the current profile configuration:
```bash
incus profile show default
```

remove the conflicting eth0 configuration
```bash
incus profile device remove default eth0
```

Add the new bridged network configuration:
```bash
incus profile device add default eth0 nic nictype=bridged parent=br0 name=eth0
```  

`incus profile device add:`
This is the command to add a device to a profile in Incus.

`default:`
The profile to which you are adding the device.
The "default" profile is applied to all containers unless specified otherwise.

`eth0:`
The name of the device within the profile.
It represents the network interface inside the container.

`nic:`
Stands for Network Interface Card.
Specifies that the device being added is a network interface.

`nictype=bridged:`
Specifies the network interface type.
bridged means that the container will use a network bridge on the host system, allowing the container to be directly exposed to the external network.

`parent=br0:`
The name of the bridge on the host machine.
The container’s eth0 will be linked to this bridge, enabling it to obtain an IP address from the same network as the host.

`name=eth0:`
Sets the network interface name as it will appear inside the container.
The container will see this network interface as eth0.

It adds a network device to the default profile in Incus. The network device is configured as a bridged NIC using the br0 bridge from the host. Inside the container, the interface will be called eth0.  
This configuration allows the container to have an IP address on the same local network as the host (like a physical machine on the same subnet).

<br/>

Enabling IOMMU on Debian
```bash
sudo nano /etc/default/grub
```
```bash
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT="quiet preempt=voluntary intel_iommu=on amd_iommu=on iommu.passthrough=1"
GRUB_CMDLINE_LINUX=""
```
```bash
sudo update-grub && sudo reboot now
```

