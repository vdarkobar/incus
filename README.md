## Incus 

### Installer script, Debian 12
  
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/vdarkobar/incus/main/script1.sh)"
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
  
(*example*) Create ZFS Pool and Incus Dataset:  
```bash
sudo zpool create -f \
  -o ashift=12 \
  -o autoexpand=on \
  -o autotrim=on \            # SSD
  -O atime=off \
  -O compression=lz4 \
  local \
  raidz \
  /dev/disk/by-id/xxx1 \
  /dev/disk/by-id/xxx2 \
  /dev/disk/by-id/xxx3
# or:
  local \
  mirror \
    /dev/disk/by-id/xxx1 \
    /dev/disk/by-id/xxx2 \
  mirror \
    /dev/disk/by-id/xxx3 \
    /dev/disk/by-id/xxx4 
```
```bash
sudo zpool add -f local cache /dev/disk/by-id/xxx4
sudo zpool add -f local spare /dev/disk/by-id/xxx5
```
```bash
sudo zfs create local/incus
```  

<br/>

Initialize Incus (point Incus to ZFS Dataset during init phase - **no, to create ZFS pool**)
```bash
incus admin init
```  

<br/>

Create **bridge interface** on the ***host*** machine (*instance gets IP from the physical network, not internal subnet*) 
```bash
sudo nano /etc/network/interfaces
```

Replace or add the following configuration (*edit port names*):
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

Remove the conflicting eth0 configuration:
```bash
incus profile device remove default eth0
```

Add the new bridged network configuration * :
```bash
incus profile device add default eth0 nic nictype=bridged parent=br0 name=eth0
```  

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

<br/>

Add the Docker repository:
```bash
incus remote add docker https://docker.io --protocol=oci
```
example:
```bash
incus launch docker:nginx:latest web
#
incus launch docker:jgraph/drawio draw
```
Upgrade:
```bash
incus stop web
incus rebuild docker:nginx:latest web
incus start web
```

<br/>

### Incus Server Backup/Restore  
Script stores each backup as a timestamped tarball under the chosen ZFS dataset’s incus-backups/ directory (at its mountpoint), and creates a matching ZFS snapshot for easy rollback.
  
```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/vdarkobar/incus/main/script2.sh)"
```

<br/>
