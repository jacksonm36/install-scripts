#!/bin/bash
set -euo pipefail

###############################################################################
# NEXTCLOUD UNATTENDED AUTOMATED INSTALLER (idempotent, non-interactive)
###############################################################################

# Password generator
genpw() {
  local L=${1:-30}
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 64 | tr -dc A-Za-z0-9 | head -c "$L"
  else
    tr -dc A-Za-z0-9 </dev/urandom | head -c "$L"
  fi
}

# Configuration
DOMAIN="${DOMAIN:-$(hostname -I | awk '{print $1}')}"
NEXTCLOUD_VER="32.0.3"
NEXTCLOUD_DIR="${NEXTCLOUD_DIR:-/var/www/nextcloud}"
DBNAME="${DBNAME:-nextcloud}"
DBUSER="${DBUSER:-ncuser}"
DBPASS="$(genpw 32)"
DBROOTPASS="$(genpw 28)"
WEBUSER="${WEBUSER:-www-data}"
NGINX_SITE="/etc/nginx/sites-available/nextcloud"
SECUREFLAG="/root/.nc_mariadb_secured"
NEXTCLOUD_DOWNLOAD_URL="https://github.com/nextcloud-releases/server/releases/download/v32.0.3/nextcloud-32.0.3.zip"

# Purge previous install
(
  echo ">>> Stopping services ..."
  systemctl stop nginx mariadb mysql php-fpm redis-server >/dev/null 2>&1 || true

  if [[ -d "$NEXTCLOUD_DIR" ]]; then
    echo ">>> Removing old Nextcloud files: $NEXTCLOUD_DIR"
    rm -rf "$NEXTCLOUD_DIR"
  fi
  if [[ -f "$NGINX_SITE" ]]; then
    echo ">>> Removing old Nginx config: $NGINX_SITE"
    rm -f "$NGINX_SITE"
  fi

  echo ">>> Purging old mariadb/mysql DB and config (if present)"
  systemctl stop mariadb || true
  systemctl stop mysql || true
  dpkg -l | grep -qw mariadb-server && \
    apt-get purge -y mariadb-server mariadb-server-core mariadb-client mariadb-common || true
  apt-get autoremove -y || true

  # Workaround: Ensure required MariaDB directories exist to prevent service start failure
  if [[ ! -d /var/lib/mysql ]]; then
    echo ">>> Creating /var/lib/mysql directory"
    mkdir -p /var/lib/mysql
    chown -R mysql:mysql /var/lib/mysql
  fi

  rm -rf /etc/mysql || true

  # Try to drop old DB/user if possible (suppress error)
  MYSQL="mysql -uroot -p$DBROOTPASS"
  $MYSQL -e "DROP DATABASE IF EXISTS \`$DBNAME\`;" 2>/dev/null || true
  $MYSQL -e "DROP USER IF EXISTS '$DBUSER'@'localhost';" 2>/dev/null || true

  [ -f "$SECUREFLAG" ] && rm -f "$SECUREFLAG"
  apt-get clean; apt-get update -y
)

# Install packages
echo ">>> Installing required packages ..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  nginx mariadb-server redis-server php-fpm php-mysql php-gd php-json \
  php-xml php-mbstring php-curl php-zip php-intl php-bcmath php-gmp php-imagick \
  php-redis php-apcu unzip wget rsync curl sudo

# Workaround: Make sure /var/lib/mysql exists and belongs to mysql BEFORE starting MariaDB
if [[ ! -d /var/lib/mysql ]]; then
  echo ">>> Creating /var/lib/mysql directory"
  mkdir -p /var/lib/mysql
  chown -R mysql:mysql /var/lib/mysql
fi

# Enable and start core services
systemctl enable --now mariadb

# Wait for mariadb to become active if it's still starting up (or failed to start)
if ! systemctl is-active --quiet mariadb; then
  echo ">>> Waiting for mariadb.service to become active ..."
  SECS=0
  while ! systemctl is-active --quiet mariadb; do
    sleep 1
    ((SECS++))
    if (( SECS > 30 )); then
      echo "ERROR: mariadb.service failed to start after 30 seconds."
      journalctl -xeu mariadb.service | tail -n40
      echo "See instructions above (log excerpt) for 'Can't create test file' errors."
      echo "If the error is about /var/lib/mysql missing or wrong permissions, fix the directory with:"
      echo "  sudo mkdir -p /var/lib/mysql && sudo chown -R mysql:mysql /var/lib/mysql"
      echo "and then restart MariaDB with: sudo systemctl restart mariadb"
      exit 2
    fi
  done
fi

# Enable and start php-fpm
echo ">>> Enabling and starting PHP-FPM ..."
for PHPFPMUNIT in $(systemctl list-units --all --type=service --no-legend 'php*-fpm.service' | awk '{print $1}'); do
  if ! systemctl enable --now "$PHPFPMUNIT"; then
    echo "WARNING: Failed to enable/start $PHPFPMUNIT"
  fi
done

# Set up nginx config before ever reloading or starting nginx
echo ">>> Setting up nginx config"
cat > "$NGINX_SITE" <<NGX
server {
    listen 80;
    server_name ${DOMAIN};
    root ${NEXTCLOUD_DIR};
    index index.php index.html;

    access_log /var/log/nginx/nextcloud.access.log;
    error_log  /var/log/nginx/nextcloud.error.log;

    client_max_body_size 512M;
    fastcgi_buffers 64 4K;

    location / {
      try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGX

mkdir -p /etc/nginx/sites-enabled/
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/nextcloud
rm -f /etc/nginx/sites-enabled/default

echo ">>> Testing nginx configuration"
if ! nginx -t; then
  echo "ERROR: nginx configuration test failed!"
  journalctl -xeu nginx.service | tail -n20
  exit 1
fi

echo ">>> Enabling and starting nginx ..."
if ! systemctl enable --now nginx; then
  echo "ERROR: Failed to enable/start nginx.service"
  echo "See: systemctl status nginx.service"
  echo "See: journalctl -xeu nginx.service"
  exit 1
fi

systemctl enable --now redis-server

# Secure MariaDB root + Create Nextcloud DB/User
echo ">>> Securing MariaDB (root password) ..."
if [[ ! -f "$SECUREFLAG" ]]; then
  mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DBROOTPASS'; FLUSH PRIVILEGES;" || true
  cat >/tmp/nc_sec.sql <<EOF
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db IN ('test','test_%');
FLUSH PRIVILEGES;
EOF
  mysql -uroot -p"$DBROOTPASS" < /tmp/nc_sec.sql || true
  touch "$SECUREFLAG"
fi

echo ">>> Preparing Nextcloud MariaDB database & user ..."
cat >/tmp/nc_db.sql <<EOSQL
CREATE DATABASE IF NOT EXISTS \`$DBNAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON \`$DBNAME\`.* TO '$DBUSER'@'localhost';
FLUSH PRIVILEGES;
EOSQL
mysql -uroot -p"$DBROOTPASS" < /tmp/nc_db.sql

# Download & extract Nextcloud
echo ">>> Downloading Nextcloud $NEXTCLOUD_VER ..."
rm -rf "$NEXTCLOUD_DIR"
wget -qO /tmp/nextcloud.zip "$NEXTCLOUD_DOWNLOAD_URL"
unzip -qq /tmp/nextcloud.zip -d /var/www/
chown -R $WEBUSER:$WEBUSER "$NEXTCLOUD_DIR"
find "$NEXTCLOUD_DIR" -type d -exec chmod 750 {} +
find "$NEXTCLOUD_DIR" -type f -exec chmod 640 {} +

# Configure PHP FPM pool user/group & socket
PHPVERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
PHPCONF="/etc/php/$PHPVERSION/fpm/pool.d/www.conf"
SOCK="/run/php/php${PHPVERSION}-fpm.sock"
if [[ -f "$PHPCONF" ]]; then
  sed -i "s|^user\s*=.*|user = $WEBUSER|" "$PHPCONF"
  sed -i "s|^group\s*=.*|group = $WEBUSER|" "$PHPCONF"
fi
systemctl restart php${PHPVERSION}-fpm

# After possible changes, reload nginx config
echo ">>> Reloading nginx"
nginx -t
systemctl reload nginx

# DONE: Show details
echo ""
echo "=========== NEXTCLOUD SETUP COMPLETE =============="
echo "URL:           http://$DOMAIN/"
echo "Nextcloud Dir: $NEXTCLOUD_DIR"
echo "Web Server:    $WEBUSER"
echo "--- DB Info:"
echo "  Host:     localhost"
echo "  Database: $DBNAME"
echo "  DB User:  $DBUSER"
echo "  DB Pass:  $DBPASS"
echo "--- MariaDB Root:"
echo "  User:     root"
echo "  Pass:     $DBROOTPASS"
echo ""
echo "--- Redis: enabled (default config) ---"
echo ""
echo "To finish installation, open above URL in browser and follow Nextcloud setup wizard"
echo ""
echo "-- TROUBLESHOOTING --"
echo "If nginx is not running, check the output of:"
echo "    systemctl status nginx.service"
echo "    journalctl -xeu nginx.service"
echo "    nginx -t"
echo ""
echo "If mariadb failed to start with errors about \"/var/lib/mysql\" or test file permissions:"
echo "  sudo mkdir -p /var/lib/mysql && sudo chown -R mysql:mysql /var/lib/mysql"
echo "  sudo systemctl restart mariadb"
echo ""
echo "Check: tail -n40 /var/log/nginx/nextcloud.error.log"
echo "Check: tail -n40 /var/log/php${PHPVERSION}-fpm.log (or in /var/log/php*/)"
echo "Check: ls -lha $NEXTCLOUD_DIR (should be owned by $WEBUSER)"
echo ""

exit 0
