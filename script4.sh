#!/usr/bin/env bash
# Debian 13 (Trixie) VM Security Setup Script
# Rewritten for idempotency, error handling, and non-interactive automation

set -euo pipefail
IFS=$'\n\t'

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Prompt for non-root username
while true; do
    read -rp "Enter username for new sudo user: " USERNAME
    if [[ -z "$USERNAME" ]]; then
        log_error "Username cannot be empty."
    elif [[ "$USERNAME" =~ ^root$ ]]; then
        log_error "Username 'root' is reserved."
    elif ! [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_error "Invalid username. Use lowercase letters, digits, dashes, or underscores."
    elif id "$USERNAME" &>/dev/null; then
        log_error "User '$USERNAME' already exists."
    else
        log_info "Selected username: $USERNAME"
        break
    fi
done

# Prompt for password
while true; do
    read -rsp "Enter password for '$USERNAME': " PASS1; echo
    read -rsp "Confirm password: " PASS2; echo
    if [[ "$PASS1" != "$PASS2" ]]; then
        log_error "Passwords do not match."
    elif (( ${#PASS1} < 8 )); then
        log_error "Password must be at least 8 characters."
    elif ! [[ "$PASS1" =~ [0-9] ]] || ! [[ "$PASS1" =~ [^a-zA-Z0-9] ]]; then
        log_error "Password must include at least one number and one special character."
    else
        log_info "Password validated."
        break
    fi
done

# Optional: Configure locale
read -rp "Configure locale to en_US.UTF-8? (y/N): " LOCALE_CHOICE
LOCALE_CHOICE=${LOCALE_CHOICE:-N}

# Optional: SSH public key
read -rp "Add SSH public key for '$USERNAME'? (y/N): " SSH_CHOICE
SSH_CHOICE=${SSH_CHOICE:-N}
if [[ "$SSH_CHOICE" =~ ^[Yy]$ ]]; then
    while true; do
        read -rp "Paste SSH public key: " PUBKEY
        if [[ -z "$PUBKEY" ]]; then
            log_error "SSH key cannot be empty."
        elif [[ "$PUBKEY" =~ ^ssh-(rsa|dss|ecdsa|ed25519)[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]]+.+)?$ ]]; then
            log_info "SSH key format OK."
            break
        else
            log_error "Invalid SSH key format."
        fi
    done
fi

# Set non-interactive frontend
export DEBIAN_FRONTEND=noninteractive

# Update and install packages
log_info "Updating package lists..."
apt-get update -y

REQUIRED=(sudo ufw wget curl nano gnupg2 argon2 fail2ban python3-systemd \
           lsb-release gnupg-agent libpam-tmpdir bash-completion \
           ca-certificates openssh-server unattended-upgrades)

log_info "Installing packages: ${REQUIRED[*]}"
apt-get install -y "${REQUIRED[@]}"

# Configure locale if requested
if [[ "$LOCALE_CHOICE" =~ ^[Yy]$ ]]; then
    log_info "Configuring locale..."
    grep -qxF 'LANG=en_US.UTF-8' /etc/environment || echo 'LANG=en_US.UTF-8' >> /etc/environment
    grep -qxF 'LC_ALL=en_US.UTF-8' /etc/environment || echo 'LC_ALL=en_US.UTF-8' >> /etc/environment
fi

# Prepare hosts file idempotently
HOSTNAME=$(hostname)
IP_ADDR=$(hostname -I | awk '{print $1}')

# Determine domain name from /etc/resolv.conf
DOMAIN=$(awk -F' ' '/^domain/ {print $2; exit}' /etc/resolv.conf || true)
if [[ -z "$DOMAIN" ]]; then
    DOMAIN=$(sed -n 's/^domain //p' /etc/resolv.conf || true)
    if [[ -z "$DOMAIN" ]]; then
        DOMAIN=$(awk -F' ' '/^search/ {print $2; exit}' /etc/resolv.conf || true)
        if [[ -z "$DOMAIN" ]]; then
            DOMAIN=$(sed -n 's/^search //p' /etc/resolv.conf || true)
            if [[ -z "$DOMAIN" ]]; then
                log_error "Domain name not found; using 'local' fallback."
                DOMAIN="local"
            fi
        fi
    fi
fi

NEW_LINE="$IP_ADDR $HOSTNAME $HOSTNAME.$DOMAIN"
log_info "Updating /etc/hosts: $NEW_LINE"
# Backup and rebuild hosts
cp /etc/hosts /etc/hosts.bak.$(date +%F)
awk -v line="$NEW_LINE" -v host="$HOSTNAME" \
    '!($0 ~ host) {print} END{print line}' /etc/hosts.bak.$(date +%F) > /etc/hosts

# Enable unattended-upgrades non-interactively
log_info "Enabling unattended-upgrades..."
cat >/etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# Uncomment desired options in 50unattended-upgrades
cfg=/etc/apt/apt.conf.d/50unattended-upgrades
cp "$cfg" "$cfg.bak.$(date +%F)"
sed -ri \
    -e 's|^//Unattended-Upgrade::Remove-Unused-Kernel-Packages|Unattended-Upgrade::Remove-Unused-Kernel-Packages|' \
    -e 's|^//Unattended-Upgrade::Remove-New-Unused-Dependencies|Unattended-Upgrade::Remove-New-Unused-Dependencies|' \
    -e 's|^//Unattended-Upgrade::Remove-Unused-Dependencies|Unattended-Upgrade::Remove-Unused-Dependencies|' \
    -e 's|^//Unattended-Upgrade::Automatic-Reboot |Unattended-Upgrade::Automatic-Reboot |' \
    -e 's|^//Unattended-Upgrade::Automatic-Reboot-Time|Unattended-Upgrade::Automatic-Reboot-Time|' \
    "$cfg"

# Configure Fail2Ban
log_info "Configuring Fail2Ban..."
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sed -ri 's|backend = auto|backend = systemd|' /etc/fail2ban/jail.local
# Ensure sshd jail is enabled
grep -q "\[sshd\]" /etc/fail2ban/jail.local && \
    sed -i '/\[sshd\]/,/^$/ s|#?enabled *= *no|enabled = true|' /etc/fail2ban/jail.local
systemctl enable --now fail2ban

# Secure shared memory
fstab=/etc/fstab
LINE="none /run/shm tmpfs defaults,ro 0 0"
grep -qxF "$LINE" "$fstab" || echo "$LINE" >> "$fstab"

# Sysctl hardening via sysctl.d
log_info "Applying sysctl settings..."
cat >/etc/sysctl.d/99-security-hardening.conf <<EOF
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter     = 1
net.ipv4.tcp_syncookies        = 1
net.ipv4.ip_forward            = 0
net.ipv6.conf.all.forwarding   = 0
net.ipv4.conf.all.accept_redirects = 0
net-ipv6.conf.all.accept_redirects = 0
net-ipv4.conf.all.accept-source-route = 0
net-ipv6.conf.all.accept-source-route = 0
net.ipv4.conf.all.log_martians = 1
EOF
sysctl --system

# SSH hardening
SSHD_CFG=/etc/ssh/sshd_config
cp "$SSHD_CFG" "$SSHD_CFG.bak.$(date +%F)"
apply_or_append() {
    local pattern="$1" replacement="$2"
    if grep -qE "^$pattern" "$SSHD_CFG"; then
        sed -ri "s|^$pattern.*|$replacement|" "$SSHD_CFG"
    else
        echo "$replacement" >> "$SSHD_CFG"
    fi
}
log_info "Hardening SSH configuration..."
apply_or_append "^Protocol"           "Protocol 2"
apply_or_append "^LogLevel"           "LogLevel VERBOSE"
apply_or_append "^PermitRootLogin"    "PermitRootLogin no"
apply_or_append "^PasswordAuthentication" "PasswordAuthentication no"
apply_or_append "^ChallengeResponseAuthentication" "ChallengeResponseAuthentication no"
apply_or_append "^MaxAuthTries"       "MaxAuthTries 3"
apply_or_append "^MaxSessions"        "MaxSessions 2"
apply_or_append "^IgnoreRhosts"       "IgnoreRhosts yes"
apply_or_append "^StrictModes"        "StrictModes yes"
apply_or_append "^Ciphers"            "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
apply_or_append "^KexAlgorithms"      "KexAlgorithms curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256"
apply_or_append "^AllowUsers"         "AllowUsers $USERNAME"
sshd -t
# Enable SSH service (handles both ssh and sshd unit names)
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null

# Firewall: UFW
log_info "Configuring UFW firewall..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw --force enable

# Create user and set password
log_info "Creating sudo user '$USERNAME'..."
useradd -m -s /bin/bash -G sudo "$USERNAME"
echo "$USERNAME:$PASS1" | chpasswd
passwd -l root

# Setup SSH key for user if provided
if [[ "$SSH_CHOICE" =~ ^[Yy]$ ]]; then
    log_info "Installing SSH key for $USERNAME"
    mkdir -p /home/$USERNAME/.ssh
    echo "$PUBKEY" > /home/$USERNAME/.ssh/authorized_keys
    chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh
    chmod 700 /home/$USERNAME/.ssh
    chmod 600 /home/$USERNAME/.ssh/authorized_keys
fi

log_info "Security setup for Debian 13 VM is complete."
