#!/bin/bash
set -e

echo "[+] Starting full service setup..."

##################################
# ICMP (Ping)
##################################
echo "[+] Ensuring ICMP is allowed..."
# Do NOT block ping — default Ubuntu allows it
# systemctl -w net.ipv4.icmp_echo_ignore_all=0

##################################
# SSH (22/tcp)
##################################
echo "[+] Setting up SSH..."

apt update -y
apt install -y openssh-server

systemctl enable ssh
systemctl restart ssh

# Create SSH user
id ssh-user &>/dev/null || useradd -m -s /bin/bash ssh-user
mkdir -p /home/ssh-user/.ssh
chmod 700 /home/ssh-user/.ssh

# ADD SCORING ENGINE SSH KEY HERE
cat > /home/ssh-user/.ssh/authorized_keys <<EOF
ssh-rsa REPLACE_WITH_SCORING_ENGINE_PUBLIC_KEY
EOF

chmod 600 /home/ssh-user/.ssh/authorized_keys
chown -R ssh-user:ssh-user /home/ssh-user/.ssh

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

apt install -y bind9
systemctl enable bind9

cat > /etc/bind/named.conf.local <<EOF
zone "test.local" {
    type master;
    file "/etc/bind/db.test.local";
};
EOF

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

systemctl restart bind9

##################################
# Firewall (minimal, safe)
##################################
echo "[+] Configuring firewall..."

apt install -y ufw
ufw allow 22
ufw allow 21
ufw allow 80
ufw allow 3306
ufw allow 53
ufw allow proto icmp
ufw --force enable

##################################
# DONE
##################################
echo "[✓] ALL SERVICES CONFIGURED FOR SCORING"
echo "[✓] Reboot-safe, scoring-engine ready"