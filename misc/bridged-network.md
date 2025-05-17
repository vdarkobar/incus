<p align="left">
  <a href="https://github.com/vdarkobar/incus/tree/main">back</a>
  <br>
</p> 

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
