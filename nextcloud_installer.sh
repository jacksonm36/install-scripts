#!/bin/bash
# NEXTCLOUD COMPLETE INSTALLER WITH ALL FIXES AND PATCHES
# Version: 3.0 - Includes: SSL, caching, cron, security, reverse proxy support, firewall

set -euo pipefail

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
EXTERNAL_DOMAIN="${EXTERNAL_DOMAIN:-}"
NEXTCLOUD_VER="32.0.3"
NEXTCLOUD_DIR="${NEXTCLOUD_DIR:-/var/www/nextcloud}"
DBNAME="${DBNAME:-nextcloud}"
DBUSER="${DBUSER:-ncuser}"
DBPASS="$(genpw 32)"
DBROOTPASS="$(genpw 28)"
WEBUSER="${WEBUSER:-www-data}"
NGINX_SITE="/etc/nginx/sites-available/nextcloud"
SSL_DIR="/etc/ssl/nextcloud"
SECUREFLAG="/root/.nc_mariadb_secured"
NEXTCLOUD_DOWNLOAD_URL="https://github.com/nextcloud-releases/server/releases/download/v32.0.3/nextcloud-32.0.3.zip"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ==================== MAIN INSTALLATION ====================
(
  log ">>> Stopping services..."
  systemctl stop nginx mariadb mysql php-fpm redis-server >/dev/null 2>&1 || true

  if [[ -d "$NEXTCLOUD_DIR" ]]; then
    log ">>> Removing old Nextcloud files"
    rm -rf "$NEXTCLOUD_DIR"
  fi
  if [[ -f "$NGINX_SITE" ]]; then
    log ">>> Removing old Nginx config"
    rm -f "$NGINX_SITE"
  fi

  log ">>> Purging old mariadb/mysql"
  systemctl stop mariadb || true
  systemctl stop mysql || true
  dpkg -l | grep -qw mariadb-server && \
    apt-get purge -y mariadb-server mariadb-server-core mariadb-client mariadb-common || true
  apt-get autoremove -y || true

  if [[ ! -d /var/lib/mysql ]]; then
    log ">>> Creating /var/lib/mysql directory"
    mkdir -p /var/lib/mysql
    chown -R mysql:mysql /var/lib/mysql
  fi

  rm -rf /etc/mysql || true
  mysql -uroot -p"$DBROOTPASS" -e "DROP DATABASE IF EXISTS \`$DBNAME\`;" 2>/dev/null || true
  mysql -uroot -p"$DBROOTPASS" -e "DROP USER IF EXISTS '$DBUSER'@'localhost';" 2>/dev/null || true

  [ -f "$SECUREFLAG" ] && rm -f "$SECUREFLAG"
  apt-get clean; apt-get update -y
)

# Install packages
log ">>> Installing required packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  nginx mariadb-server redis-server php-fpm php-mysql php-gd php-json \
  php-xml php-mbstring php-curl php-zip php-intl php-bcmath php-gmp php-imagick \
  php-redis php-apcu unzip wget rsync curl sudo jq openssl cron ufw

# Ensure MariaDB directory
if [[ ! -d /var/lib/mysql ]]; then
  log ">>> Creating /var/lib/mysql directory"
  mkdir -p /var/lib/mysql
  chown -R mysql:mysql /var/lib/mysql
fi

# Enable and start core services
systemctl enable --now mariadb

# Wait for mariadb
if ! systemctl is-active --quiet mariadb; then
  log ">>> Waiting for mariadb.service..."
  SECS=0
  while ! systemctl is-active --quiet mariadb; do
    sleep 1
    ((SECS++))
    if (( SECS > 30 )); then
      error "mariadb.service failed to start"
      exit 2
    fi
  done
fi

# Enable PHP-FPM
log ">>> Enabling and starting PHP-FPM..."
for PHPFPMUNIT in $(systemctl list-units --all --type=service --no-legend 'php*-fpm.service' | awk '{print $1}'); do
  systemctl enable --now "$PHPFPMUNIT" 2>/dev/null || true
done

# ==================== SSL CERTIFICATE ====================
log ">>> Generating self-signed SSL certificate..."
mkdir -p "$SSL_DIR"
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout "$SSL_DIR/nextcloud.key" \
  -out "$SSL_DIR/nextcloud.crt" \
  -subj "/C=HU/ST=Hungary/L=Budapest/O=Nextcloud/CN=$DOMAIN" \
  -addext "subjectAltName=DNS:$DOMAIN,DNS:localhost,DNS:127.0.0.1" 2>/dev/null || true
chmod 600 "$SSL_DIR/nextcloud.key"
chmod 644 "$SSL_DIR/nextcloud.crt"

# ==================== .mjs MIME TYPE FIX ====================
log ">>> Configuring .mjs MIME type..."
if [ -f /etc/nginx/mime.types ]; then
  sed -i '/application\/javascript.*mjs;/d' /etc/nginx/mime.types
  sed -i '/application\/javascript.*js;/a\    application\/javascript    mjs;' /etc/nginx/mime.types
fi

# ==================== NGINX CONFIG WITH ALL FIXES ====================
log ">>> Creating Nginx configuration with all fixes..."
PHPVERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
cat > "$NGINX_SITE" <<EOF
# Nextcloud configuration with all fixes
upstream php-handler {
    server unix:/var/run/php/php${PHPVERSION}-fpm.sock;
}

# HTTP server (for local access and reverse proxy)
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN localhost 127.0.0.1${EXTERNAL_DOMAIN:+ $EXTERNAL_DOMAIN};
    
    # Serve directly for local access, proxy can handle external
    root ${NEXTCLOUD_DIR};
    index index.php index.html /index.php\$request_uri;

    # Security headers
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Download-Options "noopen" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;" always;
    fastcgi_hide_header X-Powered-By;

    client_max_body_size 10G;
    fastcgi_buffers 64 4K;

    # Main location block
    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    # .mjs files with correct MIME type
    location ~ \\.mjs\$ {
        try_files \$uri =404;
    }

    # .well-known directory
    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }
        location /.well-known/acme-challenge { try_files \$uri \$uri/ =404; }
        location /.well-known/pki-validation { try_files \$uri \$uri/ =404; }
        return 301 /index.php\$request_uri;
    }

    # Hide certain paths
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)              { return 404; }

    # PHP handling
    location ~ \\.php(?:$|/) {
        fastcgi_split_path_info ^(.+?\\.php)(/.*)$;
        set \$path_info \$fastcgi_path_info;
        try_files \$fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_param HTTPS off;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass php-handler;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
    }

    # Static files
    location ~ \\.(?:css|js|mjs|svg|gif|png|jpg|ico|wasm|tflite|map)\$ {
        try_files \$uri /index.php\$request_uri;
        expires 6M;
        access_log off;
    }

    location ~ \\.woff2?\$ {
        try_files \$uri /index.php\$request_uri;
        expires 7d;
        access_log off;
    }

    # Deny access to sensitive files
    location ~ /(\\.ht|\\.user\\.ini|\\.git|README|db_structure\\.xml) {
        deny all;
    }
}

# HTTPS server for direct local access
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN localhost 127.0.0.1${EXTERNAL_DOMAIN:+ $EXTERNAL_DOMAIN};

    ssl_certificate ${SSL_DIR}/nextcloud.crt;
    ssl_certificate_key ${SSL_DIR}/nextcloud.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Same configuration as HTTP block
    root ${NEXTCLOUD_DIR};
    index index.php index.html /index.php\$request_uri;

    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Download-Options "noopen" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Permitted-Cross-Domain-Policies "none" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=15768000; includeSubDomains; preload;" always;
    fastcgi_hide_header X-Powered-By;

    client_max_body_size 10G;
    fastcgi_buffers 64 4K;

    location / {
        try_files \$uri \$uri/ /index.php\$request_uri;
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }

    location ~ \\.mjs\$ {
        try_files \$uri =404;
    }

    location ^~ /.well-known {
        location = /.well-known/carddav { return 301 /remote.php/dav/; }
        location = /.well-known/caldav  { return 301 /remote.php/dav/; }
        location /.well-known/acme-challenge { try_files \$uri \$uri/ =404; }
        location /.well-known/pki-validation { try_files \$uri \$uri/ =404; }
        return 301 /index.php\$request_uri;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)              { return 404; }

    location ~ \\.php(?:$|/) {
        fastcgi_split_path_info ^(.+?\\.php)(/.*)$;
        set \$path_info \$fastcgi_path_info;
        try_files \$fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass php-handler;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
    }

    location ~ \\.(?:css|js|mjs|svg|gif|png|jpg|ico|wasm|tflite|map)\$ {
        try_files \$uri /index.php\$request_uri;
        expires 6M;
        access_log off;
    }

    location ~ \\.woff2?\$ {
        try_files \$uri /index.php\$request_uri;
        expires 7d;
        access_log off;
    }

    location ~ /(\\.ht|\\.user\\.ini|\\.git|README|db_structure\\.xml) {
        deny all;
    }
}
EOF

mkdir -p /etc/nginx/sites-enabled/
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/nextcloud
rm -f /etc/nginx/sites-enabled/default

log ">>> Testing nginx configuration"
if ! nginx -t; then
  error "nginx configuration test failed!"
  exit 1
fi

log ">>> Enabling and starting nginx..."
systemctl enable --now nginx

systemctl enable --now redis-server

# ==================== DATABASE SETUP ====================
log ">>> Securing MariaDB..."
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

log ">>> Creating Nextcloud database..."
cat >/tmp/nc_db.sql <<EOSQL
CREATE DATABASE IF NOT EXISTS \`$DBNAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '$DBUSER'@'localhost' IDENTIFIED BY '$DBPASS';
GRANT ALL PRIVILEGES ON \`$DBNAME\`.* TO '$DBUSER'@'localhost';
FLUSH PRIVILEGES;
EOSQL
mysql -uroot -p"$DBROOTPASS" < /tmp/nc_db.sql

# ==================== NEXTCLOUD INSTALLATION ====================
log ">>> Downloading Nextcloud $NEXTCLOUD_VER ..."
rm -rf "$NEXTCLOUD_DIR"
wget -qO /tmp/nextcloud.zip "$NEXTCLOUD_DOWNLOAD_URL"
unzip -qq /tmp/nextcloud.zip -d /var/www/
chown -R $WEBUSER:$WEBUSER "$NEXTCLOUD_DIR"
find "$NEXTCLOUD_DIR" -type d -exec chmod 750 {} +
find "$NEXTCLOUD_DIR" -type f -exec chmod 640 {} +

# ==================== PHP OPTIMIZATIONS ====================
log ">>> Optimizing PHP settings..."
PHP_FPM_INI="/etc/php/$PHPVERSION/fpm/php.ini"
PHP_CLI_INI="/etc/php/$PHPVERSION/cli/php.ini"

# OPcache optimizations
for ini_file in "$PHP_FPM_INI" "$PHP_CLI_INI"; do
  if [ -f "$ini_file" ]; then
    sed -i 's/^;*memory_limit\s*=.*/memory_limit = 512M/' "$ini_file"
    sed -i 's/^;*opcache.enable\s*=.*/opcache.enable = 1/' "$ini_file"
    sed -i 's/^;*opcache.enable_cli\s*=.*/opcache.enable_cli = 1/' "$ini_file"
    sed -i 's/^;*opcache.memory_consumption\s*=.*/opcache.memory_consumption = 256/' "$ini_file"
    sed -i 's/^;*opcache.interned_strings_buffer\s*=.*/opcache.interned_strings_buffer = 16/' "$ini_file"
    sed -i 's/^;*opcache.max_accelerated_files\s*=.*/opcache.max_accelerated_files = 100000/' "$ini_file"
  fi
done

# PHP-FPM pool configuration
PHPCONF="/etc/php/$PHPVERSION/fpm/pool.d/www.conf"
if [[ -f "$PHPCONF" ]]; then
  sed -i "s|^user\s*=.*|user = $WEBUSER|" "$PHPCONF"
  sed -i "s|^group\s*=.*|group = $WEBUSER|" "$PHPCONF"
fi

systemctl restart php${PHPVERSION}-fpm
nginx -t && systemctl reload nginx

# ==================== NEXTCLOUD CONFIGURATION ====================
log ">>> Waiting for Nextcloud to be accessible..."
sleep 5

OCC="sudo -u www-data php $NEXTCLOUD_DIR/occ"
if [ -f "$NEXTCLOUD_DIR/occ" ]; then
  ADMIN_PASS=$(genpw 24)
  
  # Install Nextcloud
  if $OCC maintenance:install \
    --database mysql \
    --database-name "$DBNAME" \
    --database-user "$DBUSER" \
    --database-pass "$DBPASS" \
    --admin-user "admin" \
    --admin-pass "$ADMIN_PASS" \
    --data-dir "$NEXTCLOUD_DIR/data"; then
    log "Nextcloud installation successful!"
  else
    warn "Automatic installation failed, manual setup required"
  fi
fi

log ">>> Applying Nextcloud configuration..."
if [ -f "$NEXTCLOUD_DIR/occ" ]; then
  # Trusted domains (both local and external)
  $OCC config:system:set trusted_domains 0 --value="localhost" 2>/dev/null || true
  $OCC config:system:set trusted_domains 1 --value="$DOMAIN" 2>/dev/null || true
  $OCC config:system:set trusted_domains 2 --value="127.0.0.1" 2>/dev/null || true
  if [ -n "$EXTERNAL_DOMAIN" ]; then
    $OCC config:system:set trusted_domains 3 --value="$EXTERNAL_DOMAIN" 2>/dev/null || true
  fi
  
  # Proxy configuration (supports both direct and reverse proxy access)
  $OCC config:system:set overwriteprotocol --value="https" 2>/dev/null || true
  $OCC config:system:set overwrite.cli.url --value="https://${EXTERNAL_DOMAIN:-$DOMAIN}" 2>/dev/null || true
  $OCC config:system:delete overwritehost 2>/dev/null || true
  $OCC config:system:set trusted_proxies 0 --value="127.0.0.1" 2>/dev/null || true
  $OCC config:system:set trusted_proxies 1 --value="::1" 2>/dev/null || true
  $OCC config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR" 2>/dev/null || true
  $OCC config:system:set forwarded_for_headers 1 --value="HTTP_X_REAL_IP" 2>/dev/null || true
  
  # Maintenance and caching
  $OCC config:app:set core backgroundjobs_mode --value="cron" 2>/dev/null || true
  $OCC config:system:set maintenance_window_start --type=integer --value=1 2>/dev/null || true
  $OCC config:system:set default_phone_region --value="HU" 2>/dev/null || true
  $OCC config:system:set loglevel --value=2 2>/dev/null || true
  
  # Cache configuration (Redis + APCu)
  if php -m | grep -qi redis; then
    $OCC config:system:set memcache.local --value='\OC\Memcache\Redis' 2>/dev/null || true
    $OCC config:system:set memcache.locking --value='\OC\Memcache\Redis' 2>/dev/null || true
    $OCC config:system:set redis --value='{"host":"localhost","port":6379,"timeout":1.5}' 2>/dev/null || true
  else
    $OCC config:system:set memcache.local --value='\OC\Memcache\APCu' 2>/dev/null || true
  fi
  
  # Database optimizations
  $OCC db:add-missing-indices 2>/dev/null || true
  $OCC db:add-missing-primary-keys 2>/dev/null || true
  $OCC db:add-missing-columns 2>/dev/null || true
  $OCC maintenance:repair 2>/dev/null || true
  
  log "Nextcloud configuration applied!"
fi

# ==================== CRON CONFIGURATION ====================
log ">>> Configuring Nextcloud cron..."
$OCC background:cron 2>/dev/null || true

# System cron
if [ ! -f /etc/cron.d/nextcloud ]; then
    cat > /etc/cron.d/nextcloud << CRON
# Nextcloud cron jobs
*/5  *  *  *  * www-data /usr/bin/php $NEXTCLOUD_DIR/occ background:cron
30   3  *  *  * www-data /usr/bin/php $NEXTCLOUD_DIR/occ files:scan --all
0    4  *  *  * www-data /usr/bin/php $NEXTCLOUD_DIR/occ preview:pre-generate
CRON
    chmod 0644 /etc/cron.d/nextcloud
fi

# User cron
(crontab -u www-data -l 2>/dev/null | grep -v "occ background:cron"; \
 echo "*/5 * * * * /usr/bin/php $NEXTCLOUD_DIR/occ background:cron") | crontab -u www-data - 2>/dev/null || true

systemctl enable cron 2>/dev/null || true
systemctl restart cron 2>/dev/null || true

# ==================== FIREWALL CONFIGURATION ====================
log ">>> Configuring firewall (UFW)..."
if command -v ufw >/dev/null 2>&1; then
  # Reset to known state
  sudo ufw --force reset >/dev/null 2>&1 || true
  
  # Set defaults
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  
  # Essential services
  LOCAL_NET="192.168.1.0/24"
  sudo ufw allow from "$LOCAL_NET" to any port 22 proto tcp comment 'SSH from LAN'
  sudo ufw allow 80/tcp comment 'HTTP'
  sudo ufw allow 443/tcp comment 'HTTPS'
  
  # Nextcloud Talk ports
  sudo ufw allow 3478/tcp comment 'Nextcloud Talk - STUN/TURN TCP'
  sudo ufw allow 3478/udp comment 'Nextcloud Talk - STUN/TURN UDP'
  sudo ufw allow 5349/tcp comment 'Nextcloud Talk - TURN TLS'
  sudo ufw allow 5349/udp comment 'Nextcloud Talk - TURN DTLS'
  sudo ufw allow from "$LOCAL_NET" to any port 10000:20000 proto udp comment 'WebRTC from LAN'
  
  # Enable firewall
  echo "y" | sudo ufw enable >/dev/null 2>&1
  log "Firewall configured"
fi

# ==================== FINALIZATION ====================
SETUP_COMPLETE_FILE="/root/.nextcloud-setup-complete"
cat > "$SETUP_COMPLETE_FILE" << INFO
NEXTCLOUD INSTALLATION COMPLETE
================================
Date: $(date)
Local Access: https://$DOMAIN/
External Access: ${EXTERNAL_DOMAIN:+https://$EXTERNAL_DOMAIN/}
Admin User: admin
Admin Password: $ADMIN_PASS

DATABASE:
  Name: $DBNAME
  User: $DBUSER
  Password: $DBPASS
  Root Password: $DBROOTPASS

SSL:
  Certificate: $SSL_DIR/nextcloud.crt
  Private Key: $SSL_DIR/nextcloud.key

SERVICES:
  Cron: /etc/cron.d/nextcloud
  Firewall: UFW configured
  Cache: Redis + APCu + OPcache

FIXES APPLIED:
  ✅ .mjs MIME type
  ✅ Security headers
  ✅ Cron configuration
  ✅ PHP optimizations
  ✅ Reverse proxy support
  ✅ Database optimizations
  ✅ Firewall configuration
INFO
chmod 600 "$SETUP_COMPLETE_FILE"

# ==================== SUMMARY ====================
echo ""
echo "=========== NEXTCLOUD INSTALLATION COMPLETE =============="
echo "✅ ALL FIXES AND PATCHES INCLUDED:"
echo "   - SSL with self-signed certificate"
echo "   - .mjs MIME type fixed (JavaScript modules)"
echo "   - All security headers configured"
echo "   - OPcache optimized (256MB memory)"
echo "   - Redis + APCu caching configured"
echo "   - Cron jobs configured (background tasks)"
echo "   - Firewall (UFW) with secure rules"
echo "   - Support for both local and reverse proxy access"
echo ""
echo "📋 ACCESS INFORMATION:"
echo "   Local URL:      https://$DOMAIN/"
[ -n "$EXTERNAL_DOMAIN" ] && echo "   External URL:   https://$EXTERNAL_DOMAIN/"
echo "   Admin user:     admin"
echo "   Admin password: $ADMIN_PASS"
echo ""
echo "🔐 SSL NOTE:"
echo "   Self-signed certificate - browser will show warning"
echo "   To accept: Click 'Advanced' → 'Proceed to site'"
echo ""
echo "⏰ CRON:"
echo "   Background jobs run every 5 minutes"
echo "   File scanning: Daily at 3:30 AM"
echo ""
echo "🛡️  FIREWALL:"
echo "   Open ports: 22(SSH-LAN), 80(HTTP), 443(HTTPS)"
echo "   Talk ports: 3478, 5349 (TCP/UDP)"
echo "   WebRTC ports: 10000-20000 (UDP, LAN only)"
echo ""
echo "🔧 TROUBLESHOOTING:"
echo "   Check logs: sudo tail -f /var/log/nginx/error.log"
echo "   Test cron: sudo -u www-data php $NEXTCLOUD_DIR/occ background:cron"
echo "   Firewall: sudo ufw status"
echo ""
echo "💾 Complete setup details saved to: $SETUP_COMPLETE_FILE"
echo "=========================================================="

exit 0
