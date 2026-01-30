#!/bin/bash

systemctl stop ssh vsftpd mariadb apache2 bind9
systemctl disable ssh vsftpd mariadb apache2 bind9

userdel -r ssh-user 2>/dev/null

rm -f /srv/ftp/iloveftp.txt
rm -f /var/www/html/index.html
rm -f /etc/bind/db.test.local

mysql -u root -p <<EOF
DROP DATABASE IF EXISTS cyberforce;
DROP USER IF EXISTS 'scoring-sql'@'%';
FLUSH PRIVILEGES;
EOF