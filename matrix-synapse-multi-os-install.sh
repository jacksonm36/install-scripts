#!/usr/bin/env bash
set -Eeuo pipefail

# Matrix Synapse interactive installer (multi-OS)
# - Debian/Ubuntu + Fedora/RHEL-family
# - Database backend selection: PostgreSQL (recommended) or MariaDB (legacy/compat mode)
# - Optional components: Nginx + TLS, coturn, firewall rules, fail2ban, admin user creation

SCRIPT_VERSION="1.0.0"

SYNAPSE_USER="matrix-synapse"
SYNAPSE_GROUP="matrix-synapse"
SYNAPSE_ROOT="/opt/matrix-synapse"
SYNAPSE_VENV="${SYNAPSE_ROOT}/venv"
SYNAPSE_ETC="/etc/matrix-synapse"
SYNAPSE_DATA="/var/lib/matrix-synapse"
SYNAPSE_LOG="/var/log/matrix-synapse"
SYNAPSE_CONFIG="${SYNAPSE_ETC}/homeserver.yaml"
SYNAPSE_UNIT="/etc/systemd/system/matrix-synapse.service"
SUMMARY_FILE="/root/matrix-synapse-install-summary.txt"

OS_FAMILY=""
PKG_MANAGER=""
PRETTY_NAME=""

SERVER_NAME=""
SYNAPSE_FQDN=""
PUBLIC_BASEURL=""
DB_BACKEND=""
DB_NAME=""
DB_USER=""
DB_PASS=""

INSTALL_NGINX="false"
USE_LETSENCRYPT="false"
LETSENCRYPT_EMAIL=""
INSTALL_COTURN="false"
CONFIGURE_FIREWALL="false"
INSTALL_FAIL2BAN="false"
ENABLE_REGISTRATION="false"
ALLOW_UNVERIFIED_REGISTRATION="false"
CREATE_ADMIN_USER="false"
ADMIN_USERNAME=""
ADMIN_PASSWORD=""
SSH_ALLOWED_CIDR="any"
TURN_HOST=""
TURN_SHARED_SECRET=""
REGISTRATION_SHARED_SECRET=""

TLS_CERT_FILE=""
TLS_KEY_FILE=""
MARIADB_MODE_WARNING=""

# Optional automation overrides (used by wrapper/full-stack mode)
FORCE_INSTALL_NGINX="${SYNAPSE_FORCE_INSTALL_NGINX:-}"
FORCE_USE_LETSENCRYPT="${SYNAPSE_FORCE_USE_LETSENCRYPT:-}"
FORCE_CONFIGURE_FIREWALL="${SYNAPSE_FORCE_CONFIGURE_FIREWALL:-}"
FORCE_SSH_ALLOWED_CIDR="${SYNAPSE_FORCE_SSH_ALLOWED_CIDR:-}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "[ERROR] Please run this script as root." >&2
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
  echo "[ERROR] systemd is required by this installer." >&2
  exit 1
fi

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

gen_alnum() {
  local len="${1:-32}"
  local out=""
  while [[ "${#out}" -lt "$len" ]]; do
    if command_exists openssl; then
      out+=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | awk -v L="$len" '{print substr($0,1,L)}')
    else
      out+=$(tr -dc 'A-Za-z0-9' </dev/urandom | awk -v L="$len" '{print substr($0,1,L)}')
    fi
  done
  printf '%s' "${out:0:len}"
}

sql_escape_literal() {
  printf '%s' "$1" | sed "s/'/''/g"
}

pick_nologin_shell() {
  if [[ -x /usr/sbin/nologin ]]; then
    printf '/usr/sbin/nologin'
  elif [[ -x /sbin/nologin ]]; then
    printf '/sbin/nologin'
  else
    printf '/bin/false'
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local suffix="[Y/n]"
  local answer=""

  if [[ "${default,,}" == "n" ]]; then
    suffix="[y/N]"
  fi

  while true; do
    read -r -p "${prompt} ${suffix}: " answer || true
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

ask_text() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " value || true
    value="${value:-$default}"
  else
    read -r -p "${prompt}: " value || true
  fi
  printf '%s' "$value"
}

ask_required_text() {
  local prompt="$1"
  local default="${2:-}"
  local value=""
  while true; do
    value="$(ask_text "$prompt" "$default")"
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
    warn "Value cannot be empty."
  done
}

validate_db_identifier() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    die "Cannot detect OS: /etc/os-release is missing."
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  PRETTY_NAME="${PRETTY_NAME:-$ID}"

  case "${ID,,}" in
    debian|ubuntu)
      OS_FAMILY="debian"
      PKG_MANAGER="apt-get"
      export DEBIAN_FRONTEND=noninteractive
      ;;
    fedora)
      OS_FAMILY="fedora"
      PKG_MANAGER="dnf"
      ;;
    rhel|centos|rocky|almalinux|ol|oraclelinux)
      OS_FAMILY="rhel"
      if command_exists dnf; then
        PKG_MANAGER="dnf"
      elif command_exists yum; then
        PKG_MANAGER="yum"
      else
        die "Neither dnf nor yum found."
      fi
      ;;
    *)
      if [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
        OS_FAMILY="debian"
        PKG_MANAGER="apt-get"
        export DEBIAN_FRONTEND=noninteractive
      elif [[ "${ID_LIKE:-}" =~ (rhel|fedora|centos) ]]; then
        OS_FAMILY="rhel"
        if command_exists dnf; then
          PKG_MANAGER="dnf"
        elif command_exists yum; then
          PKG_MANAGER="yum"
        else
          die "Neither dnf nor yum found."
        fi
      else
        die "Unsupported OS: ${ID}"
      fi
      ;;
  esac
}

pkg_update() {
  case "$OS_FAMILY" in
    debian)
      apt-get update -y
      ;;
    fedora|rhel)
      if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf makecache -y
      else
        yum makecache -y
      fi
      ;;
    *)
      die "Unknown OS family: $OS_FAMILY"
      ;;
  esac
}

pkg_install() {
  case "$OS_FAMILY" in
    debian)
      apt-get install -y "$@"
      ;;
    fedora|rhel)
      if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf install -y "$@"
      else
        yum install -y "$@"
      fi
      ;;
    *)
      die "Unknown OS family: $OS_FAMILY"
      ;;
  esac
}

configure_prompts() {
  local default_host
  default_host="$(hostname -f 2>/dev/null || hostname)"
  if [[ -z "$default_host" ]]; then
    default_host="matrix.local"
  fi

  printf "\nMatrix Synapse interactive installer v%s\n" "$SCRIPT_VERSION"
  printf "Detected OS: %s\n\n" "$PRETTY_NAME"

  SERVER_NAME="$(ask_required_text "Matrix server_name (for @user:server_name)" "$default_host")"
  SYNAPSE_FQDN="$(ask_required_text "Public Synapse hostname (DNS A/AAAA record)" "$SERVER_NAME")"

  printf "\nChoose database backend:\n"
  printf "  1) PostgreSQL (recommended, officially supported)\n"
  printf "  2) MariaDB (legacy compatibility mode)\n"
  while true; do
    local db_choice
    read -r -p "Select [1-2] [1]: " db_choice || true
    db_choice="${db_choice:-1}"
    case "$db_choice" in
      1)
        DB_BACKEND="postgresql"
        break
        ;;
      2)
        DB_BACKEND="mariadb"
        MARIADB_MODE_WARNING="Modern Synapse releases officially support SQLite/PostgreSQL only; MariaDB mode is for legacy/custom builds and may require manual fixes."
        warn "$MARIADB_MODE_WARNING"
        if ask_yes_no "Continue with MariaDB compatibility mode?" "n"; then
          break
        fi
        ;;
      *)
        warn "Please choose 1 or 2."
        ;;
    esac
  done

  DB_NAME="$(ask_required_text "Database name" "synapse")"
  DB_USER="$(ask_required_text "Database user" "synapse")"
  local db_pass_prompt
  db_pass_prompt="$(ask_text "Database password (leave empty to auto-generate)" "")"
  DB_PASS="${db_pass_prompt:-$(gen_alnum 32)}"

  if ! validate_db_identifier "$DB_NAME"; then
    die "Database name must match: ^[A-Za-z_][A-Za-z0-9_]*$"
  fi
  if ! validate_db_identifier "$DB_USER"; then
    die "Database user must match: ^[A-Za-z_][A-Za-z0-9_]*$"
  fi

  if [[ -n "$FORCE_INSTALL_NGINX" ]]; then
    case "${FORCE_INSTALL_NGINX,,}" in
      1|true|yes|y)
        INSTALL_NGINX="true"
        log "Nginx install forced by SYNAPSE_FORCE_INSTALL_NGINX=${FORCE_INSTALL_NGINX}"
        ;;
      0|false|no|n)
        INSTALL_NGINX="false"
        USE_LETSENCRYPT="false"
        log "Nginx install forced OFF by SYNAPSE_FORCE_INSTALL_NGINX=${FORCE_INSTALL_NGINX}"
        ;;
      *)
        die "Invalid SYNAPSE_FORCE_INSTALL_NGINX value: ${FORCE_INSTALL_NGINX} (use true/false)"
        ;;
    esac
  elif ask_yes_no "Install and configure Nginx reverse proxy + TLS?" "y"; then
    INSTALL_NGINX="true"
  fi

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    if [[ -n "$FORCE_USE_LETSENCRYPT" ]]; then
      case "${FORCE_USE_LETSENCRYPT,,}" in
        1|true|yes|y)
          USE_LETSENCRYPT="true"
          log "Let's Encrypt forced ON by SYNAPSE_FORCE_USE_LETSENCRYPT=${FORCE_USE_LETSENCRYPT}"
          ;;
        0|false|no|n)
          USE_LETSENCRYPT="false"
          log "Let's Encrypt forced OFF by SYNAPSE_FORCE_USE_LETSENCRYPT=${FORCE_USE_LETSENCRYPT}"
          ;;
        *)
          die "Invalid SYNAPSE_FORCE_USE_LETSENCRYPT value: ${FORCE_USE_LETSENCRYPT} (use true/false)"
          ;;
      esac
    elif ask_yes_no "Use Let's Encrypt certificate (requires working public DNS + port 80)?" "n"; then
      USE_LETSENCRYPT="true"
    fi

    if [[ "$USE_LETSENCRYPT" == "true" ]]; then
      LETSENCRYPT_EMAIL="$(ask_required_text "Let's Encrypt email" "admin@${SERVER_NAME}")"
    fi
  fi

  if ask_yes_no "Install coturn TURN server (voice/video relay)?" "y"; then
    INSTALL_COTURN="true"
    TURN_HOST="$(ask_required_text "TURN public hostname" "$SYNAPSE_FQDN")"
    TURN_SHARED_SECRET="$(gen_alnum 48)"
  fi

  if [[ -n "$FORCE_CONFIGURE_FIREWALL" ]]; then
    case "${FORCE_CONFIGURE_FIREWALL,,}" in
      1|true|yes|y)
        CONFIGURE_FIREWALL="true"
        if [[ -n "$FORCE_SSH_ALLOWED_CIDR" ]]; then
          SSH_ALLOWED_CIDR="$FORCE_SSH_ALLOWED_CIDR"
        else
          SSH_ALLOWED_CIDR="any"
        fi
        log "Firewall config forced ON by SYNAPSE_FORCE_CONFIGURE_FIREWALL=${FORCE_CONFIGURE_FIREWALL}"
        ;;
      0|false|no|n)
        CONFIGURE_FIREWALL="false"
        log "Firewall config forced OFF by SYNAPSE_FORCE_CONFIGURE_FIREWALL=${FORCE_CONFIGURE_FIREWALL}"
        ;;
      *)
        die "Invalid SYNAPSE_FORCE_CONFIGURE_FIREWALL value: ${FORCE_CONFIGURE_FIREWALL} (use true/false)"
        ;;
    esac
  elif ask_yes_no "Configure firewall automatically?" "y"; then
    CONFIGURE_FIREWALL="true"
    SSH_ALLOWED_CIDR="$(ask_text "Allow SSH from CIDR (or 'any')" "any")"
  fi

  if ask_yes_no "Install fail2ban hardening?" "y"; then
    INSTALL_FAIL2BAN="true"
  fi

  if ask_yes_no "Enable open user registration?" "n"; then
    ENABLE_REGISTRATION="true"
    ALLOW_UNVERIFIED_REGISTRATION="true"
    warn "Open registration selected: installer will set enable_registration_without_verification=true."
  fi

  if ask_yes_no "Create an initial Matrix admin user now?" "y"; then
    CREATE_ADMIN_USER="true"
    ADMIN_USERNAME="$(ask_required_text "Admin username (without @)" "admin")"
    local admin_pass_input
    admin_pass_input="$(ask_text "Admin password (leave empty to auto-generate)" "")"
    ADMIN_PASSWORD="${admin_pass_input:-$(gen_alnum 24)}"
  fi

  REGISTRATION_SHARED_SECRET="$(gen_alnum 48)"
  if [[ "$INSTALL_NGINX" == "true" ]]; then
    PUBLIC_BASEURL="https://${SYNAPSE_FQDN}/"
  else
    PUBLIC_BASEURL="http://${SYNAPSE_FQDN}:8008/"
  fi
}

install_system_packages() {
  log "Installing base dependencies..."
  pkg_update

  if [[ "$OS_FAMILY" == "debian" ]]; then
    pkg_install \
      ca-certificates curl gnupg2 jq openssl sudo lsb-release \
      python3 python3-venv python3-pip build-essential pkg-config \
      libffi-dev libssl-dev git
  else
    pkg_install \
      ca-certificates curl gnupg2 jq openssl sudo \
      python3 python3-pip gcc gcc-c++ make \
      libffi-devel openssl-devel git
  fi

  case "$DB_BACKEND" in
    postgresql)
      if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_install postgresql postgresql-contrib postgresql-client libpq-dev
      else
        pkg_install postgresql postgresql-server postgresql-contrib postgresql-devel
      fi
      ;;
    mariadb)
      if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_install mariadb-server mariadb-client libmariadb-dev libmariadb-dev-compat
      else
        pkg_install mariadb-server mariadb mariadb-connector-c-devel
      fi
      ;;
    *)
      die "Unknown DB backend: $DB_BACKEND"
      ;;
  esac

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    pkg_install nginx
    if [[ "$USE_LETSENCRYPT" == "true" ]]; then
      pkg_install certbot
    fi
  fi

  if [[ "$INSTALL_COTURN" == "true" ]]; then
    pkg_install coturn
  fi

  if [[ "$CONFIGURE_FIREWALL" == "true" ]]; then
    if [[ "$OS_FAMILY" == "debian" ]]; then
      pkg_install ufw
    else
      pkg_install firewalld
    fi
  fi

  if [[ "$INSTALL_FAIL2BAN" == "true" ]]; then
    pkg_install fail2ban
  fi
}

ensure_postgres_running() {
  log "Configuring PostgreSQL..."
  if [[ "$OS_FAMILY" != "debian" ]]; then
    if [[ -d /var/lib/pgsql/data ]] && [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
      if command_exists postgresql-setup; then
        postgresql-setup --initdb || true
      elif [[ -x /usr/bin/postgresql-setup ]]; then
        /usr/bin/postgresql-setup --initdb || true
      fi
    fi
  fi

  systemctl enable --now postgresql 2>/dev/null || true
  if ! systemctl is-active --quiet postgresql; then
    local pg_unit
    pg_unit="$(systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | awk '/^postgresql/ {gsub(/\.service$/,""); print; exit}')"
    [[ -n "$pg_unit" ]] || die "Could not find a PostgreSQL systemd unit."
    systemctl enable --now "$pg_unit"
  fi

  local i
  for i in {1..40}; do
    if runuser -u postgres -- psql -tAc "SELECT 1" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  runuser -u postgres -- psql -tAc "SELECT 1" >/dev/null 2>&1 || die "PostgreSQL is not ready."
}

setup_postgres_database() {
  ensure_postgres_running
  local esc_db esc_user esc_pass
  esc_db="$(sql_escape_literal "$DB_NAME")"
  esc_user="$(sql_escape_literal "$DB_USER")"
  esc_pass="$(sql_escape_literal "$DB_PASS")"

  runuser -u postgres -- psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${esc_user}') THEN
    CREATE ROLE "${DB_USER}" LOGIN PASSWORD '${esc_pass}';
  ELSE
    ALTER ROLE "${DB_USER}" WITH LOGIN PASSWORD '${esc_pass}';
  END IF;
END
\$\$;
SQL

  local db_exists
  db_exists="$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${esc_db}'" | tr -d '[:space:]')"
  if [[ "$db_exists" != "1" ]]; then
    if ! runuser -u postgres -- createdb --template=template0 --encoding=UTF8 --owner="$DB_USER" "$DB_NAME"; then
      warn "UTF8 database creation failed; retrying without explicit encoding using template0."
      runuser -u postgres -- createdb --template=template0 --owner="$DB_USER" "$DB_NAME"
    fi
  fi

  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";"
  runuser -u postgres -- psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";"
  log "PostgreSQL database configured."
}

ensure_mariadb_running() {
  log "Configuring MariaDB..."
  systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysql 2>/dev/null || die "Could not start MariaDB/MySQL service."
  local i
  for i in {1..40}; do
    if mysqladmin ping --silent >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  mysqladmin ping --silent >/dev/null 2>&1 || die "MariaDB is not ready."
}

setup_mariadb_database() {
  ensure_mariadb_running
  local esc_pass
  esc_pass="$(sql_escape_literal "$DB_PASS")"
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${esc_pass}';"
  mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${esc_pass}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
  log "MariaDB database configured."
}

create_synapse_user_and_dirs() {
  local nologin_shell
  nologin_shell="$(pick_nologin_shell)"

  if ! id -u "$SYNAPSE_USER" >/dev/null 2>&1; then
    useradd \
      --system \
      --user-group \
      --home-dir "$SYNAPSE_DATA" \
      --create-home \
      --shell "$nologin_shell" \
      "$SYNAPSE_USER"
  fi
  SYNAPSE_GROUP="$(id -gn "$SYNAPSE_USER")"

  mkdir -p "$SYNAPSE_ROOT" "$SYNAPSE_ETC" "$SYNAPSE_DATA" "$SYNAPSE_LOG"
  chown -R "$SYNAPSE_USER:$SYNAPSE_GROUP" "$SYNAPSE_ROOT" "$SYNAPSE_ETC" "$SYNAPSE_DATA" "$SYNAPSE_LOG"
  chmod 750 "$SYNAPSE_ETC" "$SYNAPSE_DATA" "$SYNAPSE_LOG"
}

install_synapse_python() {
  log "Installing Matrix Synapse into Python virtual environment..."
  if [[ ! -d "$SYNAPSE_VENV" ]]; then
    python3 -m venv "$SYNAPSE_VENV"
  fi

  "${SYNAPSE_VENV}/bin/pip" install --upgrade pip setuptools wheel

  if [[ "$DB_BACKEND" == "postgresql" ]]; then
    "${SYNAPSE_VENV}/bin/pip" install --upgrade "matrix-synapse[postgres]"
  else
    "${SYNAPSE_VENV}/bin/pip" install --upgrade matrix-synapse PyMySQL
    warn "MariaDB mode selected. This is legacy compatibility mode and may not work on all Synapse versions."
  fi

  chown -R "$SYNAPSE_USER:$SYNAPSE_GROUP" "$SYNAPSE_ROOT"
}

generate_or_update_synapse_config() {
  log "Generating and applying Synapse configuration..."

  if [[ -f "$SYNAPSE_CONFIG" ]]; then
    if ask_yes_no "Existing ${SYNAPSE_CONFIG} found. Overwrite generated base config?" "n"; then
      cp -a "$SYNAPSE_CONFIG" "${SYNAPSE_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
      rm -f "$SYNAPSE_CONFIG"
    fi
  fi

  if [[ ! -f "$SYNAPSE_CONFIG" ]]; then
    runuser -u "$SYNAPSE_USER" -- "${SYNAPSE_VENV}/bin/python" -m synapse.app.homeserver \
      --server-name "$SERVER_NAME" \
      --config-path "$SYNAPSE_CONFIG" \
      --data-directory "$SYNAPSE_DATA" \
      --generate-config \
      --report-stats=no
  fi

  local synapse_log_config
  synapse_log_config="${SYNAPSE_ETC}/${SERVER_NAME}.log.config"
  if [[ ! -f "$synapse_log_config" ]]; then
    synapse_log_config="${SYNAPSE_ETC}/log.config"
  fi

  export SYNAPSE_CONFIG DB_BACKEND DB_NAME DB_USER DB_PASS INSTALL_NGINX PUBLIC_BASEURL
  export ENABLE_REGISTRATION ALLOW_UNVERIFIED_REGISTRATION REGISTRATION_SHARED_SECRET
  export INSTALL_COTURN TURN_HOST TURN_SHARED_SECRET
  export SYNAPSE_LOG_CONFIG="$synapse_log_config"

  "${SYNAPSE_VENV}/bin/python" - <<'PY'
import os
import yaml

config_path = os.environ["SYNAPSE_CONFIG"]
with open(config_path, "r", encoding="utf-8") as handle:
    config = yaml.safe_load(handle) or {}

db_backend = os.environ["DB_BACKEND"]
if db_backend == "postgresql":
    config["database"] = {
        "name": "psycopg2",
        "args": {
            "user": os.environ["DB_USER"],
            "password": os.environ["DB_PASS"],
            "database": os.environ["DB_NAME"],
            "host": "127.0.0.1",
            "port": 5432,
            "cp_min": 5,
            "cp_max": 10,
        },
    }
elif db_backend == "mariadb":
    config["database"] = {
        "name": "mysql",
        "args": {
            "user": os.environ["DB_USER"],
            "password": os.environ["DB_PASS"],
            "database": os.environ["DB_NAME"],
            "host": "127.0.0.1",
            "port": 3306,
            "charset": "utf8mb4",
            "cp_min": 5,
            "cp_max": 10,
        },
    }

use_nginx = os.environ["INSTALL_NGINX"] == "true"
bind_addresses = ["127.0.0.1"] if use_nginx else ["0.0.0.0"]

config["listeners"] = [
    {
        "port": 8008,
        "tls": False,
        "type": "http",
        "x_forwarded": use_nginx,
        "bind_addresses": bind_addresses,
        "resources": [{"names": ["client", "federation"], "compress": False}],
    }
]

config["public_baseurl"] = os.environ["PUBLIC_BASEURL"]
enable_registration = os.environ["ENABLE_REGISTRATION"] == "true"
config["enable_registration"] = enable_registration
config["enable_registration_without_verification"] = (
    os.environ["ALLOW_UNVERIFIED_REGISTRATION"] == "true"
)
config["registration_shared_secret"] = os.environ["REGISTRATION_SHARED_SECRET"]
config["report_stats"] = False
config["suppress_key_server_warning"] = True
config["pid_file"] = "/run/matrix-synapse/homeserver.pid"
config["log_config"] = os.environ.get("SYNAPSE_LOG_CONFIG", "/etc/matrix-synapse/log.config")

if "trusted_key_servers" not in config:
    config["trusted_key_servers"] = [{"server_name": "matrix.org"}]

if os.environ["INSTALL_COTURN"] == "true":
    host = os.environ.get("TURN_HOST", "")
    config["turn_uris"] = [
        f"turn:{host}:3478?transport=udp",
        f"turn:{host}:3478?transport=tcp",
    ]
    config["turn_shared_secret"] = os.environ.get("TURN_SHARED_SECRET", "")
    config["turn_user_lifetime"] = "1h"
    config["turn_allow_guests"] = True
else:
    for key in ("turn_uris", "turn_shared_secret", "turn_user_lifetime", "turn_allow_guests"):
        config.pop(key, None)

with open(config_path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(config, handle, default_flow_style=False, sort_keys=False)
PY

  if [[ -f "$synapse_log_config" ]]; then
    sed -i "s|/root/homeserver.log|${SYNAPSE_LOG}/homeserver.log|g" "$synapse_log_config" || true
    chown "$SYNAPSE_USER:$SYNAPSE_GROUP" "$synapse_log_config" || true
    chmod 640 "$synapse_log_config" || true
  fi

  chown "$SYNAPSE_USER:$SYNAPSE_GROUP" "$SYNAPSE_CONFIG"
  chmod 640 "$SYNAPSE_CONFIG"
}

write_synapse_systemd_unit() {
  log "Writing matrix-synapse systemd unit..."
  cat >"$SYNAPSE_UNIT" <<EOF
[Unit]
Description=Matrix Synapse homeserver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SYNAPSE_USER}
Group=${SYNAPSE_GROUP}
WorkingDirectory=${SYNAPSE_DATA}
Environment=PYTHONUNBUFFERED=1
ExecStart=${SYNAPSE_VENV}/bin/python -m synapse.app.homeserver --config-path ${SYNAPSE_CONFIG}
Restart=on-failure
RestartSec=5
RuntimeDirectory=matrix-synapse
RuntimeDirectoryMode=0750
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now matrix-synapse
}

wait_for_synapse() {
  local i
  for i in {1..60}; do
    if curl -fsS "http://127.0.0.1:8008/_matrix/client/versions" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

create_self_signed_cert() {
  local cert_dir="$1"
  local cert_name="$2"
  mkdir -p "$cert_dir"

  TLS_CERT_FILE="${cert_dir}/${cert_name}.crt"
  TLS_KEY_FILE="${cert_dir}/${cert_name}.key"

  if [[ ! -f "$TLS_CERT_FILE" || ! -f "$TLS_KEY_FILE" ]]; then
    log "Generating self-signed TLS certificate for ${SYNAPSE_FQDN}..."
    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout "$TLS_KEY_FILE" \
      -out "$TLS_CERT_FILE" \
      -subj "/CN=${SYNAPSE_FQDN}" \
      -addext "subjectAltName=DNS:${SYNAPSE_FQDN},DNS:${SERVER_NAME}" >/dev/null 2>&1; then
      openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -keyout "$TLS_KEY_FILE" \
        -out "$TLS_CERT_FILE" \
        -subj "/CN=${SYNAPSE_FQDN}" >/dev/null 2>&1
    fi
    chmod 640 "$TLS_KEY_FILE"
    chmod 644 "$TLS_CERT_FILE"
  fi
}

configure_nginx() {
  log "Configuring Nginx reverse proxy..."
  mkdir -p /etc/nginx/conf.d /var/www/certbot
  rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

  # Bootstrap HTTP config first (used for ACME challenge and initial startup).
  cat >/etc/nginx/conf.d/matrix-synapse-bootstrap.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SYNAPSE_FQDN} _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx

  if [[ "$USE_LETSENCRYPT" == "true" ]]; then
    log "Requesting Let's Encrypt certificate for ${SYNAPSE_FQDN}..."
    if certbot certonly \
      --webroot \
      -w /var/www/certbot \
      -d "$SYNAPSE_FQDN" \
      --email "$LETSENCRYPT_EMAIL" \
      --agree-tos \
      --non-interactive; then
      TLS_CERT_FILE="/etc/letsencrypt/live/${SYNAPSE_FQDN}/fullchain.pem"
      TLS_KEY_FILE="/etc/letsencrypt/live/${SYNAPSE_FQDN}/privkey.pem"
    else
      warn "Let's Encrypt issuance failed. Falling back to self-signed certificate."
      create_self_signed_cert "/etc/ssl/matrix-synapse" "matrix-synapse"
    fi
  else
    create_self_signed_cert "/etc/ssl/matrix-synapse" "matrix-synapse"
  fi

  rm -f /etc/nginx/conf.d/matrix-synapse-bootstrap.conf

  cat >/etc/nginx/conf.d/matrix-synapse.conf <<EOF
# Matrix Synapse reverse proxy

server {
    listen 80;
    listen [::]:80;
    server_name ${SYNAPSE_FQDN} _;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location = /.well-known/matrix/server {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.server":"${SYNAPSE_FQDN}:443"}';
    }

    location = /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver":{"base_url":"https://${SYNAPSE_FQDN}"}}';
    }

    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${SYNAPSE_FQDN} _;

    ssl_certificate ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 100M;

    location ~ ^(/_matrix|/_synapse/client) {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 600s;
    }

    location = /.well-known/matrix/server {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.server":"${SYNAPSE_FQDN}:443"}';
    }

    location = /.well-known/matrix/client {
        default_type application/json;
        add_header Access-Control-Allow-Origin *;
        return 200 '{"m.homeserver":{"base_url":"https://${SYNAPSE_FQDN}"}}';
    }
}

server {
    listen 8448 ssl;
    listen [::]:8448 ssl;
    http2 on;
    server_name ${SYNAPSE_FQDN} _;

    ssl_certificate ${TLS_CERT_FILE};
    ssl_certificate_key ${TLS_KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;

    location ~ ^(/_matrix|/_synapse/client) {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 600s;
    }
}
EOF

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

disable_synapse_nginx_configs_if_disabled() {
  local removed=0
  local path=""
  for path in \
    /etc/nginx/conf.d/matrix-synapse.conf \
    /etc/nginx/conf.d/matrix-synapse-bootstrap.conf \
    /etc/nginx/sites-enabled/matrix-synapse \
    /etc/nginx/sites-available/matrix-synapse; do
    if [[ -e "$path" ]]; then
      rm -f "$path"
      removed=1
    fi
  done

  if [[ "$removed" -eq 1 ]]; then
    log "Removed existing Synapse Nginx config because Synapse Nginx install is disabled."
  fi
}

configure_coturn() {
  log "Configuring coturn..."
  mkdir -p /var/log/turnserver

  local turn_cert_dir turn_cert turn_key
  turn_cert_dir="/etc/turnserver/certs"
  turn_cert="${turn_cert_dir}/turnserver.crt"
  turn_key="${turn_cert_dir}/turnserver.key"
  mkdir -p "$turn_cert_dir"

  if [[ -n "$TLS_CERT_FILE" && -n "$TLS_KEY_FILE" && -f "$TLS_CERT_FILE" && -f "$TLS_KEY_FILE" ]]; then
    cp -f "$TLS_CERT_FILE" "$turn_cert"
    cp -f "$TLS_KEY_FILE" "$turn_key"
  else
    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout "$turn_key" \
      -out "$turn_cert" \
      -subj "/CN=${TURN_HOST}" \
      -addext "subjectAltName=DNS:${TURN_HOST},DNS:${SERVER_NAME}" >/dev/null 2>&1; then
      openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
        -keyout "$turn_key" \
        -out "$turn_cert" \
        -subj "/CN=${TURN_HOST}" >/dev/null 2>&1
    fi
  fi

  if getent group turnserver >/dev/null 2>&1; then
    chgrp turnserver "$turn_cert" "$turn_key" || true
  fi
  chmod 644 "$turn_cert"
  chmod 640 "$turn_key"

  cat >/etc/turnserver.conf <<EOF
use-auth-secret
static-auth-secret=${TURN_SHARED_SECRET}
realm=${SERVER_NAME}
server-name=${TURN_HOST}
fingerprint
lt-cred-mech
listening-port=3478
tls-listening-port=5349
min-port=49160
max-port=49200
no-multicast-peers
no-cli
cert=${turn_cert}
pkey=${turn_key}
log-file=/var/log/turnserver/turnserver.log
simple-log
EOF

  if [[ -f /etc/default/coturn ]]; then
    sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  fi

  systemctl enable --now coturn 2>/dev/null || systemctl enable --now turnserver 2>/dev/null || die "Could not start coturn."
}

configure_fail2ban() {
  log "Configuring fail2ban..."
  mkdir -p /etc/fail2ban/jail.d
  cat >/etc/fail2ban/jail.d/matrix-synapse.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 6

[sshd]
enabled = true
EOF

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    cat >>/etc/fail2ban/jail.d/matrix-synapse.local <<EOF

[nginx-http-auth]
enabled = true
EOF
  fi

  systemctl enable --now fail2ban
}

configure_ufw() {
  log "Applying UFW rules..."
  ufw default deny incoming
  ufw default allow outgoing

  if [[ "${SSH_ALLOWED_CIDR,,}" == "any" ]]; then
    ufw allow 22/tcp comment 'SSH'
  else
    ufw allow from "$SSH_ALLOWED_CIDR" to any port 22 proto tcp comment 'SSH restricted'
  fi

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 8448/tcp comment 'Matrix federation'
  else
    ufw allow 8008/tcp comment 'Synapse direct'
  fi

  if [[ "$INSTALL_COTURN" == "true" ]]; then
    ufw allow 3478/tcp comment 'TURN TCP'
    ufw allow 3478/udp comment 'TURN UDP'
    ufw allow 5349/tcp comment 'TURN TLS'
    ufw allow 5349/udp comment 'TURN DTLS'
    ufw allow 49160:49200/udp comment 'TURN relay UDP range'
  fi

  ufw --force enable
}

configure_firewalld() {
  log "Applying firewalld rules..."
  systemctl enable --now firewalld

  if [[ "${SSH_ALLOWED_CIDR,,}" == "any" ]]; then
    firewall-cmd --permanent --add-service=ssh
  else
    firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${SSH_ALLOWED_CIDR}' port protocol='tcp' port='22' accept"
  fi

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --permanent --add-port=8448/tcp
  else
    firewall-cmd --permanent --add-port=8008/tcp
  fi

  if [[ "$INSTALL_COTURN" == "true" ]]; then
    firewall-cmd --permanent --add-port=3478/tcp
    firewall-cmd --permanent --add-port=3478/udp
    firewall-cmd --permanent --add-port=5349/tcp
    firewall-cmd --permanent --add-port=5349/udp
    firewall-cmd --permanent --add-port=49160-49200/udp
  fi

  firewall-cmd --reload
}

configure_firewall_rules() {
  if [[ "$CONFIGURE_FIREWALL" != "true" ]]; then
    return 0
  fi

  if [[ "$OS_FAMILY" == "debian" ]]; then
    if ! command_exists ufw; then
      die "ufw is not installed."
    fi
    configure_ufw
  else
    if ! command_exists firewall-cmd; then
      die "firewalld is not installed."
    fi
    configure_firewalld
  fi
}

create_admin_user() {
  if [[ "$CREATE_ADMIN_USER" != "true" ]]; then
    return 0
  fi

  log "Creating admin user @${ADMIN_USERNAME}:${SERVER_NAME}..."
  "${SYNAPSE_VENV}/bin/register_new_matrix_user" \
    -u "$ADMIN_USERNAME" \
    -p "$ADMIN_PASSWORD" \
    -a \
    -k "$REGISTRATION_SHARED_SECRET" \
    "http://127.0.0.1:8008"
}

write_summary() {
  cat >"$SUMMARY_FILE" <<EOF
Matrix Synapse installation summary
===================================
Date: $(date)
OS: ${PRETTY_NAME}

Server name: ${SERVER_NAME}
Public hostname: ${SYNAPSE_FQDN}
Public base URL: ${PUBLIC_BASEURL}

Database backend: ${DB_BACKEND}
Database name: ${DB_NAME}
Database user: ${DB_USER}
Database password: ${DB_PASS}

Nginx installed: ${INSTALL_NGINX}
Let's Encrypt used: ${USE_LETSENCRYPT}
TLS certificate: ${TLS_CERT_FILE:-not-set}
TLS private key: ${TLS_KEY_FILE:-not-set}

coturn installed: ${INSTALL_COTURN}
TURN host: ${TURN_HOST:-not-enabled}
TURN shared secret: ${TURN_SHARED_SECRET:-not-set}

Firewall configured: ${CONFIGURE_FIREWALL}
SSH source restriction: ${SSH_ALLOWED_CIDR}
fail2ban installed: ${INSTALL_FAIL2BAN}

Open registration enabled: ${ENABLE_REGISTRATION}
Unverified registration allowed: ${ALLOW_UNVERIFIED_REGISTRATION}
Registration shared secret: ${REGISTRATION_SHARED_SECRET}

Admin user created: ${CREATE_ADMIN_USER}
Admin username: ${ADMIN_USERNAME:-not-created}
Admin password: ${ADMIN_PASSWORD:-not-set}

Paths
-----
Config: ${SYNAPSE_CONFIG}
Data: ${SYNAPSE_DATA}
Logs: ${SYNAPSE_LOG}
Service: ${SYNAPSE_UNIT}

MariaDB note
------------
${MARIADB_MODE_WARNING:-N/A}
EOF
  chmod 600 "$SUMMARY_FILE"
}

print_final_notes() {
  printf '\n'
  log "Installation complete."
  printf "  - Matrix server_name: %s\n" "$SERVER_NAME"
  printf "  - Synapse endpoint:   %s\n" "$PUBLIC_BASEURL"
  printf "  - DB backend:         %s\n" "$DB_BACKEND"
  if [[ "$CREATE_ADMIN_USER" == "true" ]]; then
    printf "  - Admin account:      @%s:%s\n" "$ADMIN_USERNAME" "$SERVER_NAME"
  fi
  if [[ -n "$MARIADB_MODE_WARNING" ]]; then
    warn "$MARIADB_MODE_WARNING"
  fi
  printf "  - Full summary saved to: %s\n\n" "$SUMMARY_FILE"
}

main() {
  detect_os
  configure_prompts
  install_system_packages

  case "$DB_BACKEND" in
    postgresql) setup_postgres_database ;;
    mariadb) setup_mariadb_database ;;
    *) die "Unsupported DB backend: $DB_BACKEND" ;;
  esac

  create_synapse_user_and_dirs
  install_synapse_python
  generate_or_update_synapse_config
  write_synapse_systemd_unit

  if ! wait_for_synapse; then
    journalctl -u matrix-synapse --no-pager -n 100 || true
    die "Synapse service failed to become ready. Check: journalctl -u matrix-synapse -f"
  fi

  if [[ "$INSTALL_NGINX" == "true" ]]; then
    configure_nginx
  else
    disable_synapse_nginx_configs_if_disabled
  fi

  if [[ "$INSTALL_COTURN" == "true" ]]; then
    configure_coturn
    systemctl restart matrix-synapse
    if ! wait_for_synapse; then
      die "Synapse failed after coturn settings were applied."
    fi
  fi

  configure_firewall_rules

  if [[ "$INSTALL_FAIL2BAN" == "true" ]]; then
    configure_fail2ban
  fi

  create_admin_user
  write_summary
  print_final_notes
}

main "$@"
