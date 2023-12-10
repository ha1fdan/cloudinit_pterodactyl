#/bin/bash

ip_address=$(hostname -I | awk '{print $1}')
public_ip_address=$(curl -s ifconfig.me)

total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
total_ram_mb=$((total_ram_kb / 1024))
remaining_ram=$((total_ram_mb - (total_ram_mb * 10 / 100)))

total_disk_kb=$(df -k --output=size / | sed -n '2p')
total_disk_mb=$((total_disk_kb / 1024))
remaining_disk=$((total_disk_mb - (total_disk_mb * 15 / 100)))

### Create Password
passwd=$(date +%s | sha256sum | base64 | head -c 8)
echo $passwd
echo $passwd > password.txt

### Install Deps
apt update -y
apt upgrade -y
apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list
curl -sS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash
apt update -y
apt -y install php8.1 php8.1-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} mariadb-server nginx tar unzip git redis-server sudo
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

### Install Panel
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
mysql -u root -p -e "CREATE USER 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '$passwd'; CREATE DATABASE panel; GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
cp .env.example .env

### Setup Panel & User
composer install --no-dev --optimize-autoloader
php artisan key:generate --force
php artisan p:environment:setup --new-salt=1 --author=admin@example.com --url=$public_ip_address --
php artisan p:environment:database
php artisan migrate --seed --force
php artisan p:user:make --email=admin@example.com --username=admin --name-first=admin --name-last=admin --password=$passwd --admin=1
chown -R www-data:www-data /var/www/pterodactyl/*

### Panel other
(crontab -l ; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -
cat <<EOL > "/etc/systemd/system/pteroq.service"
# Pterodactyl Queue Worker File
# ----------------------------------

[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOL

systemctl daemon-reload
systemctl enable --now redis-server
systemctl enable --now pteroq.service

### Nginx (Webserver)
rm /etc/nginx/sites-enabled/default
cat <<EOL > /etc/nginx/sites-available/pterodactyl.conf
server {
    listen 80;
    server_name _;

    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL
ln -s /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
systemctl restart nginx

### Install Wings (Game server deamon)
curl -sSL https://get.docker.com/ | CHANNEL=stable bash
systemctl enable --now docker
mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_$([[ "$(uname -m)" == "x86_64" ]] && echo "amd64" || echo "arm64")"
chmod u+x /usr/local/bin/wings

### Panel and wings combine setup (final)
php artisan p:location:make --short=default --long=default
php artisan p:node:make --name=default --description=default --locationId=1 --fqdn=$ip_address --public=1 --scheme=http --proxy=0 --maintenance=0 --maxMemory=$remaining_ram --overallocateMemory=0 --maxDisk=$remaining_disk --overallocateDisk=0 --uploadSize=100 --daemonListeningPort=8080 --daemonSFTPPort=2022 --daemonBase="/var/lib/pterodactyl/volumes"
