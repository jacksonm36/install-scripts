#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This installer must be run as root."
  fi
}

genpw() {
  local len="${1:-24}"
  local out=""
  while [[ "${#out}" -lt "$len" ]]; do
    if command -v openssl >/dev/null 2>&1; then
      out+="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "$len" || true)"
    else
      out+="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len" || true)"
    fi
  done
  printf '%s' "${out:0:len}"
}

escape_sed_repl() {
  # Escape replacement chars for sed: \, &, and our delimiter |
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

set_env_kv() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local escaped
  escaped="$(escape_sed_repl "$value")"
  if grep -qE "^${key}=" "$env_file"; then
    sed -i -E "s|^${key}=.*|${key}=${escaped}|" "$env_file"
  else
    printf '\n%s=%s\n' "$key" "$value" >>"$env_file"
  fi
}

require_root

# Generate a random password for MariaDB user 'snipeit'
RANDOM_PASSWORD="$(genpw 24)"
echo "Generated MySQL Password (snipeit user): $RANDOM_PASSWORD"

# Update the system and install required packages
apt-get update -y

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
  apt-get update -y
fi

# Install packages (PHP 8.2 is available in Debian 12+ and Ubuntu with PPA)
apt-get install -y \
  curl git unzip nginx mariadb-server redis-server \
  php8.2 php8.2-cli php8.2-fpm php8.2-mysql php8.2-curl php8.2-mbstring php8.2-xml php8.2-zip php8.2-gd php8.2-bcmath php8.2-ldap php8.2-tokenizer php8.2-redis

# Install Composer (PHP dependency manager)
if ! command -v composer >/dev/null 2>&1; then
  info "Installing Composer"
  EXPECTED_SIG="$(php -r "copy('https://composer.github.io/installer.sig', 'php://stdout');")"
  php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  ACTUAL_SIG="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
  if [[ -z "$EXPECTED_SIG" ]] || [[ "$EXPECTED_SIG" != "$ACTUAL_SIG" ]]; then
    rm -f composer-setup.php
    die "Composer installer signature mismatch."
  fi
  php composer-setup.php --install-dir=/usr/local/bin --filename=composer
  rm -f composer-setup.php
fi

# Enable and start services needed for installation
systemctl enable --now mariadb
systemctl enable --now redis-server
systemctl enable --now php8.2-fpm

# Wait for MariaDB to accept connections
for i in {1..30}; do
  if mysqladmin ping -u root --silent >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
mysqladmin ping -u root --silent >/dev/null 2>&1 || die "MariaDB did not start in time."

# Clone the latest Snipe-IT repository
if [[ -d /var/www/snipe-it/.git ]]; then
  info "Snipe-IT already cloned at /var/www/snipe-it; leaving as-is"
else
  rm -rf /var/www/snipe-it
  git clone https://github.com/snipe/snipe-it /var/www/snipe-it
fi
cd /var/www/snipe-it

# Install PHP dependencies
composer install --no-dev --prefer-dist --no-interaction --optimize-autoloader

# Set permissions
chown -R www-data:www-data /var/www/snipe-it
chmod -R 755 /var/www/snipe-it
chmod -R 775 /var/www/snipe-it/storage /var/www/snipe-it/bootstrap/cache

# Configure MySQL
echo "Creating MySQL database and user for Snipe-IT..."
mysql -u root -e "CREATE DATABASE IF NOT EXISTS snipeit;"
mysql -u root -e "CREATE USER IF NOT EXISTS 'snipeit'@'localhost' IDENTIFIED BY '${RANDOM_PASSWORD}';"
mysql -u root -e "ALTER USER 'snipeit'@'localhost' IDENTIFIED BY '${RANDOM_PASSWORD}';"
mysql -u root -e "GRANT ALL PRIVILEGES ON snipeit.* TO 'snipeit'@'localhost';"
mysql -u root -e "FLUSH PRIVILEGES;"

# Configure .env file
cp -n /var/www/snipe-it/.env.example /var/www/snipe-it/.env
set_env_kv /var/www/snipe-it/.env DB_DATABASE "snipeit"
set_env_kv /var/www/snipe-it/.env DB_USERNAME "snipeit"
set_env_kv /var/www/snipe-it/.env DB_PASSWORD "$RANDOM_PASSWORD"

# Configure Redis in .env file
set_env_kv /var/www/snipe-it/.env REDIS_HOST "127.0.0.1"
set_env_kv /var/www/snipe-it/.env REDIS_PORT "6379"
set_env_kv /var/www/snipe-it/.env REDIS_PASSWORD "null"
set_env_kv /var/www/snipe-it/.env CACHE_DRIVER "redis"
set_env_kv /var/www/snipe-it/.env SESSION_DRIVER "redis"

# Generate application key
sudo -u www-data php artisan key:generate --force

# Run migrations
sudo -u www-data php artisan migrate --force

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
ln -sf /etc/nginx/sites-available/snipe-it /etc/nginx/sites-enabled/snipe-it
rm -f /etc/nginx/sites-enabled/default

# Test Nginx configuration and restart
nginx -t
systemctl restart nginx

# Set up cron job for Snipe-IT queue worker
(crontab -l 2>/dev/null; echo "* * * * * /usr/bin/php /var/www/snipe-it/artisan schedule:run >> /dev/null 2>&1") | crontab -

# Ensure services stay enabled
systemctl enable nginx mariadb redis-server php8.2-fpm

echo "Snipe-IT installation completed successfully!"
echo "MySQL Password: $RANDOM_PASSWORD"