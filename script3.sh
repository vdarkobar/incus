#!/bin/bash

#################################################
# Incus Container Setup Script                  #
# Creates a non-root user and configures locale #
#################################################

# Colors removed as requested

# Welcome banner
echo "====================================="
echo "Incus Container Configuration Script"
echo "====================================="
echo

#######################################
# Get container name                  #
#######################################

# Get container name
while true; do
    echo
    echo -n "[INFO] Enter Incus container name: "
    read -r CONTAINER_NAME
    
    # Check if container exists
    if ! incus info "$CONTAINER_NAME" &>/dev/null; then
        echo "[ERROR] Container '$CONTAINER_NAME' does not exist."
    else
        echo "[INFO] Container found: $CONTAINER_NAME"
        break
    fi
done

#######################################
# Gathering non-root user information #
#######################################

while true; do
    echo
    echo -n "[INFO] Enter username for a non-root user: "
    read -r username
    if [ "$username" == "root" ]; then
        echo "[ERROR] Username 'root' is not allowed."
    elif [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        # Check if user already exists in the container
        if incus exec "$CONTAINER_NAME" -- id "$username" &>/dev/null; then
            echo "[ERROR] User '$username' already exists in the container."
        else
            echo "[INFO] Selected Username: $username"
            break
        fi
    else
        echo "[ERROR] Invalid username. Use lowercase letters, digits, dashes, or underscores."
    fi
done

while true; do
    echo
    echo -n "[INFO] Enter password for user '$username': "
    read -s password
    echo
    echo -n "[INFO] Re-enter password for verification: "
    read -s password2
    echo
    if [ "$password" != "$password2" ]; then
        echo "[ERROR] Passwords do not match. Please try again."
    elif [ ${#password} -lt 8 ]; then
        echo "[ERROR] Password must be at least 8 characters long."
    elif ! [[ "$password" =~ [0-9] ]] || ! [[ "$password" =~ [^a-zA-Z0-9] ]]; then
        echo "[ERROR] Password must contain at least one number and one special character."
    else
        echo "[INFO] Password set successfully."
        break
    fi
done

#######################################
# Ask for SSH key (optional)          #
#######################################

echo
echo -n "[INFO] Would you like to add an SSH public key for user '$username'? (recommended for security) (y/n): "
read -r setup_ssh

ssh_key_added=false
if [[ "$setup_ssh" =~ ^[Yy]$ ]]; then
    # Ask for public key
    while true; do
        echo
        echo -n "[INFO] Please enter your public SSH key: "
        read -r public_key

        # Check if the input was empty
        if [ -z "$public_key" ]; then
            echo "[ERROR] No input received, please enter a public key."
        else
            # Validate the public key format
            if [[ "$public_key" =~ ^ssh-(rsa|dss|ecdsa|ed25519)[[:space:]][A-Za-z0-9+/]+[=]{0,2} ]]; then
                ssh_key_added=true
                break
            else
                echo "[ERROR] Invalid SSH key format. Please enter a valid SSH public key."
            fi
        fi
    done
    echo "[INFO] SSH public key will be added during configuration."
else
    echo "[INFO] Skipping SSH public key setup."
fi

#######################################
# Configure locale (optional)         #
#######################################

echo
echo -n "[INFO] Configure system locale? (y/n): "
read -r configure_locale

#######################################
# Container Configuration             #
#######################################

# Update package lists and install required packages
echo
echo "[INFO] Configuring container and creating user..."
echo "[INFO] Updating package lists and installing required packages..."

incus exec "$CONTAINER_NAME" -- bash -c "
# Update the package repositories
if ! apt update; then
    echo '[ERROR] Failed to update package repositories. Exiting.'
    exit 1
fi

# Install sudo
if ! apt install -y sudo; then
    echo '[ERROR] Failed to install sudo. Exiting.'
    exit 1
fi

# Install template packages
if ! apt install -y \
    ufw \
    wget \
    curl \
    nano \
    gnupg2 \
    argon2 \
    fail2ban \
    lsb-release \
    gnupg-agent \
    openssh-server \
    libpam-tmpdir \
    bash-completion \
    ca-certificates \
    python3-systemd \
    unattended-upgrades; then
    echo '[ERROR] Failed to install packages. Exiting.'
    exit 1
fi
"

# Configure locale if requested
if [[ "$configure_locale" =~ ^[Yy]$ ]]; then
    echo "[INFO] Configuring locale settings..."
    incus exec "$CONTAINER_NAME" -- bash -c "echo 'LANG=en_US.UTF-8' >> /etc/environment"
    incus exec "$CONTAINER_NAME" -- bash -c "echo 'LC_ALL=en_US.UTF-8' >> /etc/environment"
    echo "[INFO] Locale configuration completed successfully."
fi

######################
# Prepare hosts file #
######################

echo
echo "[INFO] Configuring hosts file for container..."

# Get the domain name from /etc/resolv.conf on the host
DOMAIN_LOCAL=$(awk -F' ' '/^domain/ {print $2; exit}' /etc/resolv.conf)
if [[ -z "$DOMAIN_LOCAL" ]]; then
    # Try using sed
    DOMAIN_LOCAL=$(sed -n 's/^domain //p' /etc/resolv.conf)
    if [[ -z "$DOMAIN_LOCAL" ]]; then
        # Backup: Check the 'search' line
        DOMAIN_LOCAL=$(awk -F' ' '/^search/ {print $2; exit}' /etc/resolv.conf)
        if [[ -z "$DOMAIN_LOCAL" ]]; then
            DOMAIN_LOCAL=$(sed -n 's/^search //p' /etc/resolv.conf)
            if [[ -z "$DOMAIN_LOCAL" ]]; then
                echo "[ERROR] Domain name not found using available methods."
                echo "[INFO] Using 'local' as fallback domain."
                DOMAIN_LOCAL="local"
            fi
        fi
    fi
fi

echo "[INFO] Using domain: $DOMAIN_LOCAL"

# Get container IP address and hostname
CONTAINER_IP=$(incus exec "$CONTAINER_NAME" -- hostname -I | awk '{print $1}')
CONTAINER_HOSTNAME=$(incus exec "$CONTAINER_NAME" -- hostname)

# Construct the new line for /etc/hosts
new_line="$CONTAINER_IP $CONTAINER_HOSTNAME $CONTAINER_HOSTNAME.$DOMAIN_LOCAL"

echo "[INFO] Updating hosts file with: $new_line"

# Update hosts file inside the container
incus exec "$CONTAINER_NAME" -- bash -c "
# Create a temporary file with the desired contents
{
    echo '$new_line'
    echo '============================================'
    # Replace the line containing the current hostname with the new line
    awk -v hostname='$CONTAINER_HOSTNAME' -v new_line='$new_line' '!(\$0 ~ hostname) || \$0 == new_line' /etc/hosts
} > /tmp/hosts.tmp

# Move the temporary file to /etc/hosts
mv /tmp/hosts.tmp /etc/hosts
"

echo "[INFO] Container hosts file has been updated."

############################################
# Automatically enable unattended-upgrades #
############################################
echo
echo "[INFO] Configuring unattended-upgrades..."

# Enable and configure unattended-upgrades inside the container
incus exec "$CONTAINER_NAME" -- bash -c "
# Enable unattended-upgrades
if echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections && dpkg-reconfigure -f noninteractive unattended-upgrades; then
    echo '[INFO] Unattended-upgrades enabled successfully.'
else
    echo '[ERROR] Failed to enable unattended-upgrades. Exiting.'
    exit 1
fi

# Define the file path
FILEPATH='/etc/apt/apt.conf.d/50unattended-upgrades'

# Check if the file exists before attempting to modify it
if [ ! -f \"\$FILEPATH\" ]; then
    echo '[ERROR] \$FILEPATH does not exist. Exiting.'
    exit 1
fi

# Uncomment the necessary lines
if sed -i 's|//Unattended-Upgrade::Remove-Unused-Kernel-Packages \"true\";|Unattended-Upgrade::Remove-Unused-Kernel-Packages \"true\";|g' \$FILEPATH \
   && sed -i 's|//Unattended-Upgrade::Remove-New-Unused-Dependencies \"true\";|Unattended-Upgrade::Remove-New-Unused-Dependencies \"true\";|g' \$FILEPATH \
   && sed -i 's|//Unattended-Upgrade::Remove-Unused-Dependencies \"false\";|Unattended-Upgrade::Remove-Unused-Dependencies \"true\";|g' \$FILEPATH \
   && sed -i 's|//Unattended-Upgrade::Automatic-Reboot \"false\";|Unattended-Upgrade::Automatic-Reboot \"true\";|g' \$FILEPATH \
   && sed -i 's|//Unattended-Upgrade::Automatic-Reboot-Time \"02:00\";|Unattended-Upgrade::Automatic-Reboot-Time \"02:00\";|g' \$FILEPATH; then
    echo '[INFO] unattended-upgrades configuration updated successfully.'
else
    echo '[ERROR] Failed to update configuration. Please check your permissions and file paths. Exiting.'
    exit 1
fi
"

echo "[INFO] Unattended-upgrades configured successfully."

#######################
# Setting up Fail2Ban #
#######################
echo
echo "[INFO] Setting up Fail2Ban..."

# Configure Fail2Ban inside the container
incus exec "$CONTAINER_NAME" -- bash -c "
# Check if Fail2Ban is installed
if ! command -v fail2ban-server >/dev/null 2>&1; then
    echo '[ERROR] Fail2Ban is not installed. Please check the package installation. Exiting.'
    exit 1
fi

# Create jail.local if it doesn't exist
if [ ! -f '/etc/fail2ban/jail.local' ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
fi

# Fixing Debian bug by setting backend to systemd
if ! sed -i 's|backend = auto|backend = systemd|g' /etc/fail2ban/jail.local; then
    echo '[ERROR] Failed to set backend to systemd in jail.local. Exiting.'
    exit 1
fi

# Create paths-debian.conf or append to it
echo '[INFO] Ensuring systemd backend is configured for Fail2Ban...'
if [ -f '/etc/fail2ban/paths-debian.conf' ]; then
    # If file exists but doesn't have sshd_backend entry, add it
    if ! grep -q 'sshd_backend' '/etc/fail2ban/paths-debian.conf'; then
        echo 'sshd_backend = systemd' >> /etc/fail2ban/paths-debian.conf
    fi
else
    # Create the file if it doesn't exist
    echo 'sshd_backend = systemd' > /etc/fail2ban/paths-debian.conf
fi

echo '[INFO] Configuring Fail2Ban for SSH protection...'

# Set the path to the sshd configuration file
config_file='/etc/fail2ban/jail.local'

# Use awk to add \"enabled = true\" below the second [sshd] line (first is a comment)
if ! awk '/\\[sshd\\]/ && ++n == 2 {print; print \"enabled = true\"; next}1' \"\$config_file\" > temp_file || ! mv temp_file \"\$config_file\"; then
    echo '[ERROR] Failed to enable SSH protection. Exiting.'
    exit 1
fi

# Change bantime to 15m
if ! sed -i 's|bantime  = 10m|bantime  = 15m|g' /etc/fail2ban/jail.local; then
    echo '[ERROR] Failed to set bantime to 15m. Exiting.'
    exit 1
fi

# Change maxretry to 3
if ! sed -i 's|maxretry = 5|maxretry = 3|g' /etc/fail2ban/jail.local; then
    echo '[ERROR] Failed to set maxretry to 3. Exiting.'
    exit 1
fi

echo '[INFO] Fail2Ban setup completed.'

##########################
# Securing Shared Memory #
##########################
echo '[INFO] Securing Shared Memory...'

# Define the line to append
LINE=\"none /run/shm tmpfs defaults,ro 0 0\"

# Check if the line already exists
if ! grep -q \"^none /run/shm\" /etc/fstab; then
    # Append the line to the end of the file
    if ! echo \"\$LINE\" >> /etc/fstab; then
        echo '[ERROR] Failed to secure shared memory. Exiting.'
        exit 1
    fi
    echo '[INFO] Shared memory secured successfully.'
else
    echo '[INFO] Shared memory is already secured.'
fi
"

echo "[INFO] Security configurations completed."

###############################
# Setting up system variables #
###############################
echo
echo "[INFO] Setting up system variables..."

# Configure sysctl parameters for security
incus exec "$CONTAINER_NAME" -- bash -c "
# Create a new sysctl configuration file
mkdir -p /etc/sysctl.d/
cat > /etc/sysctl.d/99-security-hardening.conf << 'EOF'
# IP Spoofing protection
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter = 1

# Block SYN attacks
net.ipv4.tcp_syncookies = 1

# Controls IP packet forwarding
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log Martians
net.ipv4.conf.all.log_martians = 1
EOF

# Apply the new settings
if ! systemctl restart systemd-sysctl.service; then
    echo '[ERROR] Failed to reload sysctl configuration. Exiting.'
    exit 1
fi

# Verify settings were applied
echo '[INFO] Verifying sysctl settings...'
sysctl net.ipv4.conf.default.rp_filter net.ipv4.conf.all.rp_filter
"

echo "[INFO] System variables configured successfully."

##################
# Setting up UFW #
##################
echo
echo "[INFO] Setting up UFW..."

# Configure UFW inside the container
incus exec "$CONTAINER_NAME" -- bash -c "
# Check if UFW is installed
if ! command -v ufw >/dev/null 2>&1; then
    echo '[ERROR] UFW is not installed. Please check the package installation. Exiting.'
    exit 1
fi

# Limit SSH to Port 22/tcp
if ! ufw limit 22/tcp comment 'SSH'; then
    echo '[ERROR] Failed to limit SSH access. Exiting.'
    exit 1
fi

# Set global rules
if ! ufw default deny incoming || ! ufw default allow outgoing; then
    echo '[ERROR] Failed to set global rules. Exiting.'
    exit 1
fi

# Enable UFW without prompt
if ! ufw --force enable; then
    echo '[ERROR] Failed to enable UFW. Exiting.'
    exit 1
fi

# Reload UFW to apply changes
if ! ufw reload; then
    echo '[ERROR] Failed to reload UFW. Exiting.'
    exit 1
fi

echo '[INFO] UFW setup completed.'
"

echo "[INFO] UFW firewall configured successfully."

####################################
# Setting up SSH security          #
####################################
echo
echo "[INFO] Configuring SSH security..."

incus exec "$CONTAINER_NAME" -- bash -c "
# Define the file path
FILEPATH='/etc/ssh/sshd_config'

# Check if SSH config exists
if [ ! -f \"\$FILEPATH\" ]; then
    echo '[ERROR] SSH configuration file not found. Exiting.'
    exit 1
fi

echo '[INFO] Setting up SSH variables...'

# Applying multiple sed operations to configure SSH securely
if ! (sed -i 's|KbdInteractiveAuthentication no|#KbdInteractiveAuthentication no|g' \$FILEPATH \
    && sed -i 's|#LogLevel INFO|LogLevel VERBOSE|g' \$FILEPATH \
    && sed -i 's|#PermitRootLogin prohibit-password|PermitRootLogin no|g' \$FILEPATH \
    && sed -i 's|#StrictModes yes|StrictModes yes|g' \$FILEPATH \
    && sed -i 's|#MaxAuthTries 6|MaxAuthTries 3|g' \$FILEPATH \
    && sed -i 's|#MaxSessions 10|MaxSessions 2|g' \$FILEPATH \
    && sed -i 's|#IgnoreRhosts yes|IgnoreRhosts yes|g' \$FILEPATH \
    && sed -i 's|#PermitEmptyPasswords no|PermitEmptyPasswords no|g' \$FILEPATH \
    && sed -i 's|#GSSAPIAuthentication no|GSSAPIAuthentication no|g' \$FILEPATH \
    && sed -i '/# Ciphers and keying/a Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr' \$FILEPATH \
    && sed -i '/chacha20-poly1305/a KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256' \$FILEPATH \
    && sed -i '/curve25519-sha256/a Protocol 2' \$FILEPATH); then
    echo '[ERROR] Failed to configure SSH variables. Exiting.'
    exit 1
fi

# Only disable password authentication if SSH key was added
if [ \"$ssh_key_added\" = \"true\" ]; then
    echo '[INFO] Disabling password authentication (SSH key provided)...'
    if ! sed -i 's|#PasswordAuthentication yes|PasswordAuthentication no|g' \$FILEPATH; then
        echo '[WARNING] Failed to disable password authentication.'
    fi
    
    if ! sed -i 's|UsePAM yes|UsePAM no|g' \$FILEPATH; then
        echo '[WARNING] Failed to disable PAM authentication.'
    fi
else
    echo '[INFO] Keeping password authentication enabled (no SSH key provided)...'
    # Ensure password authentication is explicitly enabled
    if ! sed -i 's|#PasswordAuthentication yes|PasswordAuthentication yes|g' \$FILEPATH; then
        echo '[WARNING] Failed to explicitly enable password authentication.'
    fi
fi

echo '[INFO] Disabling ChallengeResponseAuthentication...'

# Define the line to append
LINE='ChallengeResponseAuthentication no'

# Check if the line already exists to avoid duplications
if grep -q \"^\$LINE\" \"\$FILEPATH\"; then
    echo '[INFO] ChallengeResponseAuthentication is already set to no.'
else
    # Append the line to the end of the file
    if ! echo \"\$LINE\" >> \$FILEPATH; then
        echo '[ERROR] Failed to disable ChallengeResponseAuthentication. Exiting.'
        exit 1
    fi
fi

echo '[INFO] Allowing SSH only for user \"$username\"...'

# Check if 'AllowUsers' is already set for the user to avoid duplications
if grep -q \"^AllowUsers.*$username\" \"\$FILEPATH\"; then
    echo '[INFO] SSH access is already restricted to user \"$username\".'
else
    # Append the username to /etc/ssh/sshd_config
    if ! echo \"AllowUsers $username\" >> \$FILEPATH; then
        echo '[ERROR] Failed to restrict SSH access to user \"$username\". Exiting.'
        exit 1
    fi
fi

# Ensure SSH service is enabled and started
if systemctl is-enabled ssh >/dev/null 2>&1 || systemctl is-enabled sshd >/dev/null 2>&1; then
    echo '[INFO] Restarting SSH service...'
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
else
    echo '[INFO] Enabling and starting SSH service...'
    systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true
    systemctl start ssh 2>/dev/null || systemctl start sshd 2>/dev/null || true
fi

echo '[INFO] SSH security configuration completed.'
"

#######################################
# Create user and configure sudo      #
#######################################
echo
echo "[INFO] Creating user and configuring sudo access..."

# Create user and configure sudo access
incus exec "$CONTAINER_NAME" -- bash -c "
adduser --gecos ',,,,' --disabled-password $username && \
usermod -aG sudo $username && \
echo '$username:$password' | chpasswd && \
passwd -l root
"

# Verify user creation
if incus exec "$CONTAINER_NAME" -- id "$username" &>/dev/null; then
    echo "[INFO] User '$username' created successfully."
else
    echo "[ERROR] Failed to create user '$username'."
    exit 1
fi

# Set up SSH for the created user if requested
if [ "$ssh_key_added" = true ]; then
    echo "[INFO] Setting up SSH access for user '$username'..."
    incus exec "$CONTAINER_NAME" -- bash -c "
    # Ensure .ssh directory exists
    mkdir -p /home/$username/.ssh
    touch /home/$username/.ssh/authorized_keys
    echo '$public_key' >> /home/$username/.ssh/authorized_keys
    chown -R $username:$username /home/$username/.ssh
    chmod 700 /home/$username/.ssh
    chmod 600 /home/$username/.ssh/authorized_keys
    "
    echo "[INFO] SSH public key added successfully."
fi

echo
echo "[INFO] Container configuration completed successfully."
echo "[INFO] You can now access the container as:"
echo "    incus exec $CONTAINER_NAME -- su - $username"
if [ "$ssh_key_added" = true ]; then
    echo "[INFO] Or via SSH if the container has network access:"
    echo "    ssh $username@$CONTAINER_IP"
fi
echo
echo "====================================="
echo "        Configuration Complete       "
echo "====================================="
