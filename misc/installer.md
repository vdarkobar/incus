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
