#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

##################################
# Blue-team oriented service setup for Debian
# Secure by default, with optional knobs for exposure.
##################################

log() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
die() { echo "[x] $*" >&2; exit 1; }

# Require root so we do not mix sudo/non-sudo behavior.
[[ "${EUID}" -eq 0 ]] || die "Run as root (sudo ./script.sh)."

##################################
# Configuration knobs (edit these)
##################################

# Management networks allowed to reach SSH. If you do not know, leave 0.0.0.0/0 to avoid locking yourself out.
# Better: set to your admin IP/CIDR like "203.0.113.10/32" or your VPN subnet.
SSH_ALLOWED_CIDRS=("0.0.0.0/0")

# Expose services externally?
ENABLE_HTTP=1
ENABLE_DNS=1

# Strong recommendation: keep these off public networks.
ENABLE_FTP=0            # Default off (use SFTP instead)
ENABLE_REMOTE_DB=0      # Default off (local only)

# If you enable remote DB, restrict the DB user host (example: "10.10.10.%")
DB_ALLOWED_HOST="${DB_ALLOWED_HOST:-localhost}"

# Provide DB password via env var DB_PASS=... if you need deterministic setup.
DB_PASS="${DB_PASS:-}"

# SSH user and authorized key
SSH_USER="ssh-user"
SSH_KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDsptjW30R0+NX0eU8jggplU3VfJ9rGZM7zXYjSyLyvYnZdILaSTe9kmF6d3VK9mgPo8o6cz1Me1G77oMDqoKk4xV0CWEqE7Hpl8sWsL/Em6D4/fZSBAX3MzuNW1s7cZd7shWMffNDZNiAv+x/cVkhTDh7zqNR88h9E1EkqHRa+8r2Wu4xNCfeHo1q/9bMjUxxRdUTOt3QKjSE8Hyb3Gaa8Lny0UymABx9Zg1XC3X1GOazly++iFLDeKV4IW54DBqjzhqLgMC3rGBTODPC66mG+O4FwNWUJFAdwili0BRClB5c7b4AJVEtYzOG9sBh9cMcos7JB9CeAj+1vPFz+XraT'

##################################
# Base packages
##################################
log "Updating packages and installing base tools..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg lsb-release \
  ufw fail2ban unattended-upgrades

##################################
# ICMP (Ping)
##################################
log "Ensuring ICMP echo replies are enabled (ping works)..."

# Persist via sysctl.d (cleaner than editing /etc/sysctl.conf directly).
cat > /etc/sysctl.d/99-icmp.conf <<'EOF'
# Allow ping replies (ICMP echo). 0 = reply, 1 = ignore.
net.ipv4.icmp_echo_ignore_all=0
EOF

# Apply immediately.
sysctl --system >/dev/null

##################################
# SSH (22/tcp)
##################################
log "Installing and hardening SSH..."

apt-get install -y --no-install-recommends openssh-server

# Create user if missing.
if ! id "${SSH_USER}" &>/dev/null; then
  useradd -m -s /bin/bash "${SSH_USER}"
  passwd -l "${SSH_USER}" >/dev/null 2>&1 || true   # lock password so it cannot be used for password login
fi

# Ensure .ssh directory and permissions.
install -d -m 700 -o "${SSH_USER}" -g "${SSH_USER}" "/home/${SSH_USER}/.ssh"
touch "/home/${SSH_USER}/.ssh/authorized_keys"
chown "${SSH_USER}:${SSH_USER}" "/home/${SSH_USER}/.ssh/authorized_keys"
chmod 600 "/home/${SSH_USER}/.ssh/authorized_keys"

# Idempotently add key (do not overwrite existing keys).
if ! grep -qxF "${SSH_KEY}" "/home/${SSH_USER}/.ssh/authorized_keys"; then
  echo "${SSH_KEY}" >> "/home/${SSH_USER}/.ssh/authorized_keys"
fi

# Use an sshd config drop-in (Debian supports sshd_config.d on modern OpenSSH).
# This avoids mangling the main file and is easy to revert.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
# Blue-team hardening
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no

# Force key-based auth only
AuthenticationMethods publickey

# Reduce attack surface
X11Forwarding no
AllowTcpForwarding no
PermitTunnel no
GatewayPorts no

# Tighten session handling
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxAuthTries 4

# Logging
LogLevel VERBOSE

# Only allow this user to SSH in (remove this if you need more accounts)
AllowUsers ${SSH_USER}

# Important:
# Do NOT re-enable legacy "ssh-rsa" SHA1 signatures. OpenSSH disables them for good reasons.
EOF

# Validate config before restart.
sshd -t

systemctl enable --now ssh

##################################
# HTTP (80/tcp)
##################################
if [[ "${ENABLE_HTTP}" -eq 1 ]]; then
  log "Installing and hardening Apache (HTTP)..."
  apt-get install -y --no-install-recommends apache2

  # Basic hardening: reduce info leakage and add minimal security headers.
  a2enmod headers >/dev/null 2>&1 || true

  cat > /etc/apache2/conf-available/99-hardening.conf <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off

<IfModule mod_headers.c>
  Header always set X-Content-Type-Options "nosniff"
  Header always set X-Frame-Options "SAMEORIGIN"
  Header always set Referrer-Policy "strict-origin-when-cross-origin"
</IfModule>
EOF

  a2enconf 99-hardening >/dev/null 2>&1 || true

  echo "Hello World!" > /var/www/html/index.html

  systemctl enable --now apache2
else
  warn "HTTP disabled by configuration (ENABLE_HTTP=0)."
fi

##################################
# DNS (53/tcp/udp) via bind9
##################################
if [[ "${ENABLE_DNS}" -eq 1 ]]; then
  log "Installing and configuring bind9 (DNS)..."
  apt-get install -y --no-install-recommends bind9 dnsutils

  # Harden bind9: no recursion if exposed, which prevents being used as an open resolver.
  # Authoritative-only for this simple lab zone.
  cat > /etc/bind/named.conf.options <<'EOF'
options {
  directory "/var/cache/bind";

  recursion no;
  allow-query { any; };
  allow-transfer { none; };

  listen-on { any; };
  listen-on-v6 { none; };

  dnssec-validation auto;
  auth-nxdomain no;
};
EOF

  # Local zone config
  cat > /etc/bind/named.conf.local <<'EOF'
zone "test.local" {
  type master;
  file "/etc/bind/db.test.local";
};
EOF

  cat > /etc/bind/db.test.local <<'EOF'
$TTL 604800
@   IN  SOA test.local. root.test.local. (
        2026013001 ; serial
        604800     ; refresh
        86400      ; retry
        2419200    ; expire
        604800 )   ; negative cache TTL

@       IN  NS  test.local.
test.local. IN  A   10.10.10.10
EOF

  # Validate bind config before restart.
  named-checkconf
  named-checkzone test.local /etc/bind/db.test.local

  # On Debian, the unit can be bind9 and/or named depending on aliases. :contentReference[oaicite:6]{index=6}
  if systemctl list-unit-files | grep -q '^bind9\.service'; then
    systemctl enable --now bind9
  else
    systemctl enable --now named
  fi
else
  warn "DNS disabled by configuration (ENABLE_DNS=0)."
fi

##################################
# MariaDB (3306/tcp)
##################################
log "Installing MariaDB..."

apt-get install -y --no-install-recommends mariadb-server

systemctl enable --now mariadb

# Decide DB exposure.
if [[ "${ENABLE_REMOTE_DB}" -eq 1 ]]; then
  log "Enabling remote MariaDB listener (restricted by firewall and DB user host)..."
  sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
else
  log "Keeping MariaDB local-only (bind to 127.0.0.1)..."
  sed -i 's/^bind-address.*/bind-address = 127.0.0.1/' /etc/mysql/mariadb.conf.d/50-server.cnf
fi

systemctl restart mariadb

# Create a safer password if not provided.
if [[ -z "${DB_PASS}" ]]; then
  DB_PASS="$(openssl rand -base64 24)"
  umask 077
  echo "DB user password (store safely): ${DB_PASS}" > /root/mariadb_scoring_password.txt
  warn "Generated DB password saved to /root/mariadb_scoring_password.txt (600 perms)."
fi

# Create DB and least-privilege user (SELECT is usually enough for “check a value” scoring).
mysql <<EOF
CREATE DATABASE IF NOT EXISTS cyberforce;
USE cyberforce;

CREATE TABLE IF NOT EXISTS supersecret (
  data INT
);

DELETE FROM supersecret;
INSERT INTO supersecret VALUES (7);

CREATE USER IF NOT EXISTS 'scoring-sql'@'${DB_ALLOWED_HOST}' IDENTIFIED BY '${DB_PASS}';
GRANT SELECT ON cyberforce.* TO 'scoring-sql'@'${DB_ALLOWED_HOST}';
FLUSH PRIVILEGES;
EOF

##################################
# FTP (vsftpd)
##################################
if [[ "${ENABLE_FTP}" -eq 1 ]]; then
  warn "FTP is enabled. Blue-team note: prefer SFTP over FTP."
  log "Installing vsftpd in a safer mode (no anonymous)..."

  apt-get install -y --no-install-recommends vsftpd
  cp -a /etc/vsftpd.conf "/etc/vsftpd.conf.bak.$(date +%s)" || true

  cat > /etc/vsftpd.conf <<'EOF'
listen=YES
listen_ipv6=NO

# Safer defaults: disable anonymous FTP
anonymous_enable=NO

# Local users allowed (if you create one for FTP), and restrict them
local_enable=YES
write_enable=NO

# Basic hardening
chroot_local_user=YES
allow_writeable_chroot=NO
seccomp_sandbox=YES

xferlog_enable=YES
use_localtime=YES
EOF

  systemctl enable --now vsftpd
else
  log "FTP disabled (ENABLE_FTP=0). Use SFTP via SSH if you need file transfer."
fi

##################################
# Firewall (UFW)
##################################
log "Configuring UFW firewall (deny inbound by default)..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH: allow from management CIDRs, rate-limited.
for cidr in "${SSH_ALLOWED_CIDRS[@]}"; do
  ufw limit from "${cidr}" to any port 22 proto tcp
done

# HTTP
if [[ "${ENABLE_HTTP}" -eq 1 ]]; then
  ufw allow 80/tcp
fi

# DNS
if [[ "${ENABLE_DNS}" -eq 1 ]]; then
  ufw allow 53/udp
  ufw allow 53/tcp
fi

# DB: only if remote enabled
if [[ "${ENABLE_REMOTE_DB}" -eq 1 ]]; then
  # If you need this, restrict it hard (example: allow from your scoring subnet only).
  # Replace 0.0.0.0/0 with a real CIDR.
  ufw allow from 0.0.0.0/0 to any port 3306 proto tcp
fi

# FTP: only if enabled
if [[ "${ENABLE_FTP}" -eq 1 ]]; then
  ufw allow 21/tcp
fi

# ICMP: do NOT use "ufw allow proto icmp" (not supported in CLI). :contentReference[oaicite:7]{index=7}
# We already enabled ping replies via sysctl. UFW typically allows relevant ICMP in before.rules.
# If you later tighten ICMP, edit /etc/ufw/before.rules with explicit ICMP allowances.

ufw --force enable

##################################
# Fail2ban and unattended upgrades
##################################
log "Enabling fail2ban and unattended upgrades..."
systemctl enable --now fail2ban
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

log "DONE: services configured (blue-team defaults)."

