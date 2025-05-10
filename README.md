## Incus installer script, Debian  
  
Create ZFS Pool and Incus Dataset, example:  
```bash
sudo zpool create -f \
  -o ashift=12 \
  -o autoexpand=on \
  -O atime=off \
  -O compression=lz4 \
  tank raidz \
  /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1 \
  /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi2 \
  /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi3
```
```bash
sudo zpool add -f tank cache /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi4
sudo zpool add -f tank spare /dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi5
```
```bash
sudo zfs create tank/incus -o mountpoint=/mnt/incus
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
```bas
incus admin init
```  

Create a Bridge Interface on the host, edit your network configuration file:
```bash
sudo nano /etc/network/interfaces
```

Replace or add the following configuration:
```bash
# The loopback network interface
auto lo
iface lo inet loopback

# The primary network interface
allow-hotplug ens18
iface ens18 inet manual

# Bridge interface for Incus containers/VMs
auto br0
iface br0 inet dhcp
    bridge_ports ens18
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
