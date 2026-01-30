#!/bin/bash
set -e

echo "[+] Starting full service setup..."

##################################
# ICMP (Ping)
##################################
echo "[+] Ensuring ICMP is allowed..."
# Do NOT block ping — default Ubuntu allows it
sudo sh -c 'echo 0 > /proc/sys/net/ipv4/icmp_echo_ignore_all'
# Persist the setting across reboots
if ! grep -q '^net.ipv4.icmp_echo_ignore_all' /etc/sysctl.conf 2>/dev/null; then
  echo 'net.ipv4.icmp_echo_ignore_all=0' >> /etc/sysctl.conf
else
  sed -i 's/^net.ipv4.icmp_echo_ignore_all.*/net.ipv4.icmp_echo_ignore_all=0/' /etc/sysctl.conf
fi

##################################
# SSH (22/tcp)
##################################
apt-get install -y --no-install-recommends openssh-server

# Create user if missing.
if ! id "${SSH_USER}" &>/dev/null; then
  usr/sbin/useradd -m -s /bin/bash "${SSH_USER}"
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
usr/sbin/sshd -t

systemctl enable --now ssh

##################################
# FTP (21/tcp) — Anonymous
##################################
echo "[+] Setting up FTP..."

apt install -y vsftpd
cp /etc/vsftpd.conf /etc/vsftpd.conf.bak

cat > /etc/vsftpd.conf <<EOF
listen=YES
listen_ipv6=NO

anonymous_enable=YES
local_enable=NO
write_enable=NO

anon_root=/srv/ftp
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

dirmessage_enable=NO
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES

secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=ftp
EOF

mkdir -p /srv/ftp
echo "iloveftp" > /srv/ftp/iloveftp.txt
chmod 555 /srv/ftp
chmod 444 /srv/ftp/iloveftp.txt

systemctl enable vsftpd
systemctl restart vsftpd

##################################
# MySQL / MariaDB (3306/tcp)
##################################
echo "[+] Setting up MariaDB..."

apt install -y mariadb-server
systemctl enable mariadb
systemctl start mariadb

mysql <<EOF
CREATE DATABASE IF NOT EXISTS cyberforce;
USE cyberforce;

CREATE TABLE IF NOT EXISTS supersecret (
  data INT
);

DELETE FROM supersecret;
INSERT INTO supersecret VALUES (7);

CREATE USER IF NOT EXISTS 'scoring-sql'@'%' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON cyberforce.* TO 'scoring-sql'@'%';
FLUSH PRIVILEGES;
EOF

# Allow remote connections
sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
systemctl restart mariadb

##################################
# HTTP (80/tcp)
##################################
echo "[+] Setting up HTTP..."

apt install -y apache2
systemctl enable apache2
systemctl start apache2

echo "Hello World!" > /var/www/html/index.html

##################################
# DNS (53/tcp/udp)
##################################
echo "[+] Setting up DNS..."

apt update -y
apt install -y bind9

# Enable and start the correct service
systemctl enable named
systemctl restart named

# Configure the test.local zone
cat > /etc/bind/named.conf.local <<EOF
zone "test.local" {
    type master;
    file "/etc/bind/db.test.local";
};
EOF

# Create the zone file
cat > /etc/bind/db.test.local <<EOF
\$TTL 604800
@   IN  SOA test.local. root.test.local. (
        2
        604800
        86400
        2419200
        604800 )

@       IN  NS  test.local.
test.local. IN A 10.10.10.10
EOF

# Restart to apply config
systemctl restart named

##################################
# Firewall (minimal, safe)
##################################
echo "[+] Configuring firewall..."

apt install -y ufw

/usr/sbin/ufw allow 22
/usr/sbin/ufw allow 21
/usr/sbin/ufw allow 80
/usr/sbin/ufw allow 3306
/usr/sbin/ufw allow 53
/usr/sbin/ufw allow proto icmp
/usr/sbin/ufw --force enable

##################################
# DONE
##################################
echo "[✓] ALL SERVICES CONFIGURED FOR SCORING"
echo "[✓] Reboot-safe, scoring-engine ready"