#!/bin/bash

# Generate a random password for MySQL
RANDOM_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+-=' | head -c 16)
echo "Generated MySQL Password: $RANDOM_PASSWORD"

# Update the system and install required packages
apt-get update

# Detect OS for package availability
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_DISTRO="${ID,,}"
else
  OS_DISTRO="unknown"
fi

# On Ubuntu, add the PHP PPA first if needed
if [ "$OS_DISTRO" = "ubuntu" ]; then
  apt-get install -y software-properties-common
  add-apt-repository ppa:ondrej/php -y
  apt-get update
fi

# Install packages (PHP 8.2 is available in Debian 12+ and Ubuntu with PPA)
apt-get install -y curl git unzip nginx mariadb-server redis-server php8.2 php8.2-fpm php8.2-mysql php8.2-curl php8.2-mbstring php8.2-xml php8.2-zip php8.2-gd php8.2-bcmath php8.2-ldap php8.2-tokenizer php8.2-redis

# Install Composer (PHP dependency manager)
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer

# Clone the latest Snipe-IT repository
git clone https://github.com/snipe/snipe-it /var/www/snipe-it
cd /var/www/snipe-it

# Install PHP dependencies
composer install --no-dev --prefer-source

# Set permissions
chown -R www-data:www-data /var/www/snipe-it
chmod -R 755 /var/www/snipe-it
chmod -R 775 /var/www/snipe-it/storage /var/www/snipe-it/bootstrap/cache

# Configure MySQL
echo "Creating MySQL database and user for Snipe-IT..."
mysql -u root -e "CREATE DATABASE snipeit;"
mysql -u root -e "CREATE USER 'snipeit'@'localhost' IDENTIFIED BY '$RANDOM_PASSWORD';"
mysql -u root -e "GRANT ALL PRIVILEGES ON snipeit.* TO 'snipeit'@'localhost';"
mysql -u root -e "FLUSH PRIVILEGES;"

# Configure .env file
cp /var/www/snipe-it/.env.example /var/www/snipe-it/.env
sed -i "s/DB_DATABASE=homestead/DB_DATABASE=snipeit/" /var/www/snipe-it/.env
sed -i "s/DB_USERNAME=homestead/DB_USERNAME=snipeit/" /var/www/snipe-it/.env
sed -i "s/DB_PASSWORD=secret/DB_PASSWORD=$RANDOM_PASSWORD/" /var/www/snipe-it/.env

# Configure Redis in .env file
sed -i "s/REDIS_HOST=127.0.0.1/REDIS_HOST=127.0.0.1/" /var/www/snipe-it/.env
sed -i "s/REDIS_PASSWORD=null/REDIS_PASSWORD=null/" /var/www/snipe-it/.env
sed -i "s/REDIS_PORT=6379/REDIS_PORT=6379/" /var/www/snipe-it/.env
sed -i "s/CACHE_DRIVER=file/CACHE_DRIVER=redis/" /var/www/snipe-it/.env
sed -i "s/SESSION_DRIVER=file/SESSION_DRIVER=redis/" /var/www/snipe-it/.env

# Generate application key
php artisan key:generate

# Run migrations
php artisan migrate --force

# Configure Nginx
cat > /etc/nginx/sites-available/snipe-it <<EOL
server {
    listen 80;
    server_name _;
    root /var/www/snipe-it/public;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    error_log /var/log/nginx/snipe-it_error.log;
    access_log /var/log/nginx/snipe-it_access.log;
}
EOL

# Enable the Nginx configuration
ln -s /etc/nginx/sites-available/snipe-it /etc/nginx/sites-enabled/
unlink /etc/nginx/sites-enabled/default

# Test Nginx configuration and restart
nginx -t
systemctl restart nginx

# Set up cron job for Snipe-IT queue worker
(crontab -l 2>/dev/null; echo "* * * * * /usr/bin/php /var/www/snipe-it/artisan schedule:run >> /dev/null 2>&1") | crontab -

# Enable and start services
systemctl enable nginx
systemctl enable mariadb
systemctl enable redis-server
systemctl enable php8.2-fpm

systemctl start nginx
systemctl start mariadb
systemctl start redis-server
systemctl start php8.2-fpm

echo "Snipe-IT installation completed successfully!"
echo "MySQL Password: $RANDOM_PASSWORD"