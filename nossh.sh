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

/usr/sbin/ufw default deny incoming
/usr/sbin/ufw default allow outgoing

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