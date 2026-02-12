#!/usr/bin/env bash
set -Eeuo pipefail

# Matrix full stack installer (monolithic rewrite)
# - Installs Synapse (+ PostgreSQL/MariaDB compatibility), optional coturn/fail2ban/firewall/admin account
# - Installs Element Web from latest/tag/ESS Helm mapped release
# - Designed for reverse-proxy-first deployments (e.g. Pangolin)
# - Supports Debian/Ubuntu and Fedora/RHEL-family

SCRIPT_VERSION="2.0.0"

MODE=""
OS_FAMILY=""
PKG_MANAGER=""
PRETTY_NAME=""

DEFAULT_MATRIX_DOMAIN="${MATRIX_DEFAULT_SERVER_DOMAIN:-matrix.gamedns.hu}"
DEFAULT_ELEMENT_DOMAIN="${ELEMENT_DEFAULT_PUBLIC_DOMAIN:-chat.gamedns.hu}"
DEFAULT_ESS_HELM_RELEASE="${ELEMENT_DEFAULT_ESS_HELM_RELEASE:-26.2.0}"
DEFAULT_ELEMENT_VERSION="${ELEMENT_DEFAULT_VERSION:-ess-helm:${DEFAULT_ESS_HELM_RELEASE}}"
DEFAULT_EXTERNAL_PROXY="${MATRIX_DEFAULT_EXTERNAL_REVERSE_PROXY:-true}"

EXTERNAL_REVERSE_PROXY="true"
MATRIX_DOMAIN=""
ELEMENT_DOMAIN=""

INSTALL_SYNAPSE="false"
INSTALL_ELEMENT="false"

DB_BACKEND="postgresql"
DB_NAME="synapse"
DB_USER="synapse"
DB_PASS=""

SYNAPSE_ENABLE_OPEN_REGISTRATION="false"
SYNAPSE_ALLOW_UNVERIFIED_REGISTRATION="false"
SYNAPSE_CREATE_ADMIN="true"
SYNAPSE_ADMIN_USER="admin"
SYNAPSE_ADMIN_PASS=""
SYNAPSE_INSTALL_COTURN="true"
SYNAPSE_INSTALL_FAIL2BAN="true"
SYNAPSE_INSTALL_LOCAL_NGINX="false"
SYNAPSE_LOCAL_TLS="false"
SYNAPSE_LOCAL_LETSENCRYPT="false"
SYNAPSE_LOCAL_LE_EMAIL=""
SYNAPSE_PUBLIC_BASEURL=""
SYNAPSE_REGISTRATION_SHARED_SECRET=""
TURN_HOST=""
TURN_SHARED_SECRET=""

ELEMENT_VERSION_REQUEST=""
ELEMENT_RESOLVED_TAG=""
ELEMENT_VERSION_SOURCE=""
ELEMENT_HOMESERVER_URL=""
ELEMENT_PROXY_MATRIX_ENDPOINTS="false"
ELEMENT_SYNAPSE_UPSTREAM="http://127.0.0.1:8008"
ELEMENT_LOCAL_TLS="false"
ELEMENT_LOCAL_LETSENCRYPT="false"
ELEMENT_LOCAL_LE_EMAIL=""

CONFIGURE_FIREWALL="true"
SSH_SOURCE="any"
SYNAPSE_BACKEND_SOURCE="any"
ELEMENT_BACKEND_SOURCE="any"

SUMMARY_FILE="/root/matrix-full-stack-summary.txt"

SYNAPSE_USER="matrix-synapse"
SYNAPSE_GROUP="matrix-synapse"
SYNAPSE_ROOT="/opt/matrix-synapse"
SYNAPSE_VENV="${SYNAPSE_ROOT}/venv"
SYNAPSE_ETC="/etc/matrix-synapse"
SYNAPSE_DATA="/var/lib/matrix-synapse"
SYNAPSE_LOG="/var/log/matrix-synapse"
SYNAPSE_CONFIG="${SYNAPSE_ETC}/homeserver.yaml"
SYNAPSE_UNIT="/etc/systemd/system/matrix-synapse.service"

ELEMENT_ROOT="/var/www/element"
ELEMENT_NGINX_CONF="/etc/nginx/conf.d/element-web.conf"
ELEMENT_BOOTSTRAP_CONF="/etc/nginx/conf.d/element-web-bootstrap.conf"
SYNAPSE_NGINX_CONF="/etc/nginx/conf.d/matrix-synapse.conf"
SYNAPSE_NGINX_BOOTSTRAP_CONF="/etc/nginx/conf.d/matrix-synapse-bootstrap.conf"
CERTBOT_WEBROOT="/var/www/certbot"

ELEMENT_TLS_CERT=""
ELEMENT_TLS_KEY=""
SYNAPSE_TLS_CERT=""
SYNAPSE_TLS_KEY=""

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: sudo bash matrix-complete-install.sh [--mode full|synapse|element]

Modes:
  full      Install Synapse + Element Web (default)
  synapse   Install only Synapse stack
  element   Install only Element Web stack

Env defaults:
  MATRIX_DEFAULT_SERVER_DOMAIN
  ELEMENT_DEFAULT_PUBLIC_DOMAIN
  MATRIX_DEFAULT_EXTERNAL_REVERSE_PROXY
  ELEMENT_DEFAULT_ESS_HELM_RELEASE
  ELEMENT_DEFAULT_VERSION
EOF
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root."
}

require_systemd() {
  command_exists systemctl || die "systemd is required."
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

ask_secret_or_generate() {
  local prompt="$1"
  local len="${2:-32}"
  local in=""
  read -r -s -p "${prompt} (leave empty to auto-generate): " in || true
  printf '\n'
  if [[ -n "$in" ]]; then
    printf '%s' "$in"
  else
    gen_alnum "$len"
  fi
}

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

is_valid_ip_or_cidr() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  if command_exists python3; then
    python3 - "$value" <<'PY'
import ipaddress
import sys
try:
    ipaddress.ip_network(sys.argv[1], strict=False)
except ValueError:
    raise SystemExit(1)
PY
  else
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]
  fi
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        [[ $# -ge 2 ]] || die "--mode requires a value."
        MODE="${2,,}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

choose_mode() {
  case "$MODE" in
    full)
      INSTALL_SYNAPSE="true"
      INSTALL_ELEMENT="true"
      ;;
    synapse)
      INSTALL_SYNAPSE="true"
      ;;
    element)
      INSTALL_ELEMENT="true"
      ;;
    "")
      printf "\nMatrix Full Stack Installer v%s\n" "$SCRIPT_VERSION"
      printf "Choose what to install:\n"
      printf "  1) Full stack (Synapse + Element)\n"
      printf "  2) Synapse only\n"
      printf "  3) Element only\n"
      local choice
      while true; do
        read -r -p "Select [1-3] [1]: " choice || true
        choice="${choice:-1}"
        case "$choice" in
          1) INSTALL_SYNAPSE="true"; INSTALL_ELEMENT="true"; break ;;
          2) INSTALL_SYNAPSE="true"; break ;;
          3) INSTALL_ELEMENT="true"; break ;;
          *) warn "Please select 1, 2, or 3." ;;
        esac
      done
      ;;
    *)
      die "Invalid mode '${MODE}'. Use full, synapse, or element."
      ;;
  esac
}

detect_os() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
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
        die "dnf/yum not found."
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
          die "dnf/yum not found."
        fi
      else
        die "Unsupported OS ${ID}"
      fi
      ;;
  esac
}

pkg_update() {
  case "$OS_FAMILY" in
    debian) apt-get update -y ;;
    fedora|rhel)
      if [[ "$PKG_MANAGER" == "dnf" ]]; then dnf makecache -y; else yum makecache -y; fi
      ;;
    *) die "Unknown OS family $OS_FAMILY" ;;
  esac
}

pkg_install() {
  case "$OS_FAMILY" in
    debian) apt-get install -y "$@" ;;
    fedora|rhel)
      if [[ "$PKG_MANAGER" == "dnf" ]]; then dnf install -y "$@"; else yum install -y "$@"; fi
      ;;
    *) die "Unknown OS family $OS_FAMILY" ;;
  esac
}

collect_inputs() {
  local proxy_default="y"
  case "${DEFAULT_EXTERNAL_PROXY,,}" in
    0|false|no|n) proxy_default="n" ;;
  esac

  if ask_yes_no "Use external reverse proxy (Pangolin/Traefik/NPM) in front?" "$proxy_default"; then
    EXTERNAL_REVERSE_PROXY="true"
  else
    EXTERNAL_REVERSE_PROXY="false"
  fi

  if [[ "$INSTALL_SYNAPSE" == "true" || "$INSTALL_ELEMENT" == "true" ]]; then
    MATRIX_DOMAIN="$(ask_required_text "Matrix server_name domain" "$DEFAULT_MATRIX_DOMAIN")"
  fi
  if [[ "$INSTALL_ELEMENT" == "true" ]]; then
    ELEMENT_DOMAIN="$(ask_required_text "Element public domain" "$DEFAULT_ELEMENT_DOMAIN")"
  fi

  if [[ "$INSTALL_SYNAPSE" == "true" ]]; then
    printf "\nSynapse database backend:\n"
    printf "  1) PostgreSQL (recommended)\n"
    printf "  2) MariaDB (legacy compatibility)\n"
    local db_choice
    while true; do
      read -r -p "Select [1-2] [1]: " db_choice || true
      db_choice="${db_choice:-1}"
      case "$db_choice" in
        1) DB_BACKEND="postgresql"; break ;;
        2) DB_BACKEND="mariadb"; warn "MariaDB mode is compatibility-only for modern Synapse."; break ;;
        *) warn "Choose 1 or 2." ;;
      esac
    done

    DB_NAME="$(ask_required_text "Database name" "$DB_NAME")"
    DB_USER="$(ask_required_text "Database user" "$DB_USER")"
    DB_PASS="$(ask_secret_or_generate "Database password" 32)"

    if [[ "$EXTERNAL_REVERSE_PROXY" == "true" ]]; then
      SYNAPSE_INSTALL_LOCAL_NGINX="false"
      SYNAPSE_PUBLIC_BASEURL="https://${MATRIX_DOMAIN}/"
      log "External reverse proxy mode: local Synapse Nginx is disabled."
    else
      if ask_yes_no "Install local Nginx in front of Synapse?" "y"; then
        SYNAPSE_INSTALL_LOCAL_NGINX="true"
        if ask_yes_no "Enable TLS on local Synapse Nginx?" "y"; then
          SYNAPSE_LOCAL_TLS="true"
          if ask_yes_no "Use Let's Encrypt for local Synapse Nginx?" "n"; then
            SYNAPSE_LOCAL_LETSENCRYPT="true"
            SYNAPSE_LOCAL_LE_EMAIL="$(ask_required_text "Let's Encrypt email" "admin@${MATRIX_DOMAIN}")"
          fi
        fi
      fi
      if [[ "$SYNAPSE_INSTALL_LOCAL_NGINX" == "true" && "$SYNAPSE_LOCAL_TLS" == "true" ]]; then
        SYNAPSE_PUBLIC_BASEURL="https://${MATRIX_DOMAIN}/"
      elif [[ "$SYNAPSE_INSTALL_LOCAL_NGINX" == "true" ]]; then
        SYNAPSE_PUBLIC_BASEURL="http://${MATRIX_DOMAIN}/"
      else
        SYNAPSE_PUBLIC_BASEURL="http://${MATRIX_DOMAIN}:8008/"
      fi
    fi
    [[ "$SYNAPSE_PUBLIC_BASEURL" =~ /$ ]] || SYNAPSE_PUBLIC_BASEURL="${SYNAPSE_PUBLIC_BASEURL}/"

    if ask_yes_no "Install coturn?" "y"; then
      SYNAPSE_INSTALL_COTURN="true"
      TURN_HOST="$(ask_required_text "TURN public hostname" "$MATRIX_DOMAIN")"
      TURN_SHARED_SECRET="$(gen_alnum 48)"
    else
      SYNAPSE_INSTALL_COTURN="false"
    fi

    if ask_yes_no "Install fail2ban?" "y"; then
      SYNAPSE_INSTALL_FAIL2BAN="true"
    else
      SYNAPSE_INSTALL_FAIL2BAN="false"
    fi

    if ask_yes_no "Enable open registration?" "n"; then
      SYNAPSE_ENABLE_OPEN_REGISTRATION="true"
      if ask_yes_no "Allow registration without verification (unsafe)?" "y"; then
        SYNAPSE_ALLOW_UNVERIFIED_REGISTRATION="true"
      else
        warn "Open registration without verification is blocked by modern Synapse. Enabling unverified registration to keep startup healthy."
        SYNAPSE_ALLOW_UNVERIFIED_REGISTRATION="true"
      fi
    fi

    if ask_yes_no "Create initial Matrix admin user?" "y"; then
      SYNAPSE_CREATE_ADMIN="true"
      SYNAPSE_ADMIN_USER="$(ask_required_text "Admin username" "$SYNAPSE_ADMIN_USER")"
      SYNAPSE_ADMIN_PASS="$(ask_secret_or_generate "Admin password" 24)"
    else
      SYNAPSE_CREATE_ADMIN="false"
    fi

    SYNAPSE_REGISTRATION_SHARED_SECRET="$(gen_alnum 48)"
  fi

  if [[ "$INSTALL_ELEMENT" == "true" ]]; then
    ELEMENT_HOMESERVER_URL="$(ask_required_text "Element homeserver URL" "https://${MATRIX_DOMAIN}")"
    if [[ ! "$ELEMENT_HOMESERVER_URL" =~ ^https?:// ]]; then
      warn "Homeserver URL missing scheme, prefixing with https://"
      ELEMENT_HOMESERVER_URL="https://${ELEMENT_HOMESERVER_URL}"
    fi
    ELEMENT_HOMESERVER_URL="${ELEMENT_HOMESERVER_URL%/}"

    ELEMENT_VERSION_REQUEST="$(ask_text "Element version ('latest', tag, 'ess-helm:<release>', or ESS release URL)" "$DEFAULT_ELEMENT_VERSION")"
    ELEMENT_VERSION_REQUEST="${ELEMENT_VERSION_REQUEST:-$DEFAULT_ELEMENT_VERSION}"

    local proxy_matrix_default="y"
    if [[ "$EXTERNAL_REVERSE_PROXY" == "true" ]]; then
      proxy_matrix_default="n"
    fi
    if ask_yes_no "Proxy Matrix endpoints in local Element Nginx?" "$proxy_matrix_default"; then
      ELEMENT_PROXY_MATRIX_ENDPOINTS="true"
      ELEMENT_SYNAPSE_UPSTREAM="$(ask_required_text "Local Synapse upstream URL" "$ELEMENT_SYNAPSE_UPSTREAM")"
      ELEMENT_SYNAPSE_UPSTREAM="${ELEMENT_SYNAPSE_UPSTREAM%/}"
    else
      ELEMENT_PROXY_MATRIX_ENDPOINTS="false"
    fi

    if [[ "$EXTERNAL_REVERSE_PROXY" == "true" ]]; then
      ELEMENT_LOCAL_TLS="false"
      ELEMENT_LOCAL_LETSENCRYPT="false"
      log "External reverse proxy mode: local Element TLS disabled."
    else
      if ask_yes_no "Enable local TLS for Element Nginx?" "y"; then
        ELEMENT_LOCAL_TLS="true"
        if ask_yes_no "Use Let's Encrypt for Element?" "y"; then
          ELEMENT_LOCAL_LETSENCRYPT="true"
          ELEMENT_LOCAL_LE_EMAIL="$(ask_required_text "Let's Encrypt email" "admin@${ELEMENT_DOMAIN}")"
        fi
      fi
    fi
  fi

  if ask_yes_no "Configure firewall automatically?" "y"; then
    CONFIGURE_FIREWALL="true"
    SSH_SOURCE="$(ask_text "Allow SSH from CIDR (or 'any')" "any")"
    if [[ "$INSTALL_SYNAPSE" == "true" && "$SYNAPSE_INSTALL_LOCAL_NGINX" == "false" ]]; then
      SYNAPSE_BACKEND_SOURCE="$(ask_text "Allow Synapse 8008 from CIDR (or 'any')" "any")"
    fi
    if [[ "$INSTALL_ELEMENT" == "true" ]]; then
      ELEMENT_BACKEND_SOURCE="$(ask_text "Allow Element 80 from CIDR (or 'any')" "any")"
    fi
  else
    CONFIGURE_FIREWALL="false"
  fi
}

install_required_packages() {
  log "Installing required packages..."
  pkg_update

  if [[ "$OS_FAMILY" == "debian" ]]; then
    pkg_install ca-certificates curl jq tar openssl sudo git python3 python3-venv python3-pip
    if [[ "$INSTALL_SYNAPSE" == "true" ]]; then
      pkg_install build-essential pkg-config libffi-dev libssl-dev
    fi
  else
    pkg_install ca-certificates curl jq tar openssl sudo git python3 python3-pip
    if [[ "$INSTALL_SYNAPSE" == "true" ]]; then
      pkg_install gcc gcc-c++ make libffi-devel openssl-devel
    fi
  fi

  if [[ "$INSTALL_SYNAPSE" == "true" ]]; then
    if [[ "$DB_BACKEND" == "postgresql" ]]; then
      if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_install postgresql postgresql-contrib postgresql-client libpq-dev
      else
        pkg_install postgresql postgresql-server postgresql-contrib postgresql-devel
      fi
    else
      if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_install mariadb-server mariadb-client libmariadb-dev libmariadb-dev-compat
      else
        pkg_install mariadb-server mariadb mariadb-connector-c-devel
      fi
    fi
    if [[ "$SYNAPSE_INSTALL_COTURN" == "true" ]]; then pkg_install coturn; fi
    if [[ "$SYNAPSE_INSTALL_FAIL2BAN" == "true" ]]; then pkg_install fail2ban; fi
  fi

  if [[ "$INSTALL_ELEMENT" == "true" || "$SYNAPSE_INSTALL_LOCAL_NGINX" == "true" ]]; then
    pkg_install nginx
  fi

  if [[ "$SYNAPSE_LOCAL_LETSENCRYPT" == "true" || "$ELEMENT_LOCAL_LETSENCRYPT" == "true" ]]; then
    pkg_install certbot
  fi

  if [[ "$CONFIGURE_FIREWALL" == "true" ]]; then
    if [[ "$OS_FAMILY" == "debian" ]]; then
      pkg_install ufw
    else
      pkg_install firewalld
    fi
  fi
}

ensure_postgres_running() {
  if [[ "$OS_FAMILY" != "debian" ]]; then
    if [[ -d /var/lib/pgsql/data ]] && [[ ! -f /var/lib/pgsql/data/PG_VERSION ]]; then
      if command_exists postgresql-setup; then postgresql-setup --initdb || true; fi
    fi
  fi
  systemctl enable --now postgresql 2>/dev/null || true
  if ! systemctl is-active --quiet postgresql; then
    local unit
    unit="$(systemctl list-unit-files --type=service --no-legend | awk '{print $1}' | awk '/^postgresql/{gsub(/\.service$/,"");print;exit}')"
    [[ -n "$unit" ]] || die "Could not find PostgreSQL service unit."
    systemctl enable --now "$unit"
  fi
  local i
  for i in {1..40}; do
    if runuser -u postgres -- psql -tAc "SELECT 1" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "PostgreSQL did not become ready."
}

setup_postgres_database() {
  ensure_postgres_running
  local esc_db esc_user esc_pass exists
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

  exists="$(runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='${esc_db}'" | tr -d '[:space:]')"
  if [[ "$exists" != "1" ]]; then
    runuser -u postgres -- createdb --template=template0 --encoding=UTF8 --owner="$DB_USER" "$DB_NAME"
  fi
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";"
  runuser -u postgres -- psql -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "GRANT ALL ON SCHEMA public TO \"${DB_USER}\";"
}

setup_mariadb_database() {
  systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysql 2>/dev/null || die "Could not start MariaDB."
  local i
  for i in {1..40}; do
    if mysqladmin ping --silent >/dev/null 2>&1; then break; fi
    sleep 1
  done
  mysqladmin ping --silent >/dev/null 2>&1 || die "MariaDB did not become ready."

  local esc_pass
  esc_pass="$(sql_escape_literal "$DB_PASS")"
  mysql -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${esc_pass}';"
  mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${esc_pass}';"
  mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
}

create_synapse_user_and_dirs() {
  local shell
  shell="$(pick_nologin_shell)"
  if ! id -u "$SYNAPSE_USER" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$SYNAPSE_DATA" --create-home --shell "$shell" "$SYNAPSE_USER"
  fi
  SYNAPSE_GROUP="$(id -gn "$SYNAPSE_USER")"
  mkdir -p "$SYNAPSE_ROOT" "$SYNAPSE_ETC" "$SYNAPSE_DATA" "$SYNAPSE_LOG"
  chown -R "$SYNAPSE_USER:$SYNAPSE_GROUP" "$SYNAPSE_ROOT" "$SYNAPSE_ETC" "$SYNAPSE_DATA" "$SYNAPSE_LOG"
  chmod 750 "$SYNAPSE_ETC" "$SYNAPSE_DATA" "$SYNAPSE_LOG"
}

install_synapse_python() {
  log "Installing Synapse..."
  if [[ ! -d "$SYNAPSE_VENV" ]]; then
    python3 -m venv "$SYNAPSE_VENV"
  fi
  "${SYNAPSE_VENV}/bin/pip" install --upgrade pip setuptools wheel
  if [[ "$DB_BACKEND" == "postgresql" ]]; then
    "${SYNAPSE_VENV}/bin/pip" install --upgrade "matrix-synapse[postgres]"
  else
    "${SYNAPSE_VENV}/bin/pip" install --upgrade matrix-synapse PyMySQL
  fi
  chown -R "$SYNAPSE_USER:$SYNAPSE_GROUP" "$SYNAPSE_ROOT"
}

configure_synapse_yaml() {
  log "Generating/updating Synapse config..."
  if [[ -f "$SYNAPSE_CONFIG" ]]; then
    if ask_yes_no "Existing ${SYNAPSE_CONFIG} found. Overwrite generated base config?" "n"; then
      cp -a "$SYNAPSE_CONFIG" "${SYNAPSE_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
      rm -f "$SYNAPSE_CONFIG"
    fi
  fi
  if [[ ! -f "$SYNAPSE_CONFIG" ]]; then
    runuser -u "$SYNAPSE_USER" -- "${SYNAPSE_VENV}/bin/python" -m synapse.app.homeserver \
      --server-name "$MATRIX_DOMAIN" \
      --config-path "$SYNAPSE_CONFIG" \
      --data-directory "$SYNAPSE_DATA" \
      --generate-config \
      --report-stats=no
  fi

  local log_cfg
  log_cfg="${SYNAPSE_ETC}/${MATRIX_DOMAIN}.log.config"
  if [[ ! -f "$log_cfg" ]]; then log_cfg="${SYNAPSE_ETC}/log.config"; fi

  export SYNAPSE_CONFIG DB_BACKEND DB_NAME DB_USER DB_PASS SYNAPSE_PUBLIC_BASEURL MATRIX_DOMAIN
  export SYNAPSE_ENABLE_OPEN_REGISTRATION SYNAPSE_ALLOW_UNVERIFIED_REGISTRATION SYNAPSE_REGISTRATION_SHARED_SECRET
  export SYNAPSE_INSTALL_COTURN TURN_HOST TURN_SHARED_SECRET
  export SYNAPSE_INSTALL_LOCAL_NGINX EXTERNAL_REVERSE_PROXY
  export SYNAPSE_LOG_CFG="$log_cfg"

  "${SYNAPSE_VENV}/bin/python" - <<'PY'
import os
import yaml

cfg_path = os.environ["SYNAPSE_CONFIG"]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

db_backend = os.environ["DB_BACKEND"]
if db_backend == "postgresql":
    cfg["database"] = {
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
else:
    cfg["database"] = {
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

local_nginx = os.environ.get("SYNAPSE_INSTALL_LOCAL_NGINX", "false") == "true"
external_proxy = os.environ.get("EXTERNAL_REVERSE_PROXY", "false") == "true"

cfg["listeners"] = [{
    "port": 8008,
    "tls": False,
    "type": "http",
    "x_forwarded": (local_nginx or external_proxy),
    "bind_addresses": ["127.0.0.1"] if local_nginx else ["0.0.0.0"],
    "resources": [{"names": ["client", "federation"], "compress": False}],
}]

cfg["public_baseurl"] = os.environ["SYNAPSE_PUBLIC_BASEURL"]
cfg["enable_registration"] = os.environ["SYNAPSE_ENABLE_OPEN_REGISTRATION"] == "true"
cfg["enable_registration_without_verification"] = os.environ["SYNAPSE_ALLOW_UNVERIFIED_REGISTRATION"] == "true"
cfg["registration_shared_secret"] = os.environ["SYNAPSE_REGISTRATION_SHARED_SECRET"]
cfg["report_stats"] = False
cfg["suppress_key_server_warning"] = True
cfg["pid_file"] = "/run/matrix-synapse/homeserver.pid"
cfg["log_config"] = os.environ.get("SYNAPSE_LOG_CFG", "/etc/matrix-synapse/log.config")
cfg["trusted_key_servers"] = [{"server_name": "matrix.org"}]

if os.environ.get("SYNAPSE_INSTALL_COTURN", "false") == "true":
    host = os.environ.get("TURN_HOST", "")
    cfg["turn_uris"] = [f"turn:{host}:3478?transport=udp", f"turn:{host}:3478?transport=tcp"]
    cfg["turn_shared_secret"] = os.environ.get("TURN_SHARED_SECRET", "")
    cfg["turn_user_lifetime"] = "1h"
    cfg["turn_allow_guests"] = True
else:
    for k in ("turn_uris", "turn_shared_secret", "turn_user_lifetime", "turn_allow_guests"):
        cfg.pop(k, None)

with open(cfg_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
PY

  if [[ -f "$log_cfg" ]]; then
    sed -i "s|/root/homeserver.log|${SYNAPSE_LOG}/homeserver.log|g" "$log_cfg" || true
    chown "$SYNAPSE_USER:$SYNAPSE_GROUP" "$log_cfg" || true
    chmod 640 "$log_cfg" || true
  fi
  chown "$SYNAPSE_USER:$SYNAPSE_GROUP" "$SYNAPSE_CONFIG"
  chmod 640 "$SYNAPSE_CONFIG"
}

write_synapse_systemd_unit() {
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

disable_stale_synapse_nginx() {
  rm -f "$SYNAPSE_NGINX_CONF" "$SYNAPSE_NGINX_BOOTSTRAP_CONF" /etc/nginx/sites-enabled/matrix-synapse /etc/nginx/sites-available/matrix-synapse
}

generate_self_signed_cert() {
  local host="$1" cert="$2" key="$3"
  mkdir -p "$(dirname "$cert")"
  if [[ ! -f "$cert" || ! -f "$key" ]]; then
    if ! openssl req -x509 -nodes -newkey rsa:2048 -days 825 -keyout "$key" -out "$cert" -subj "/CN=${host}" -addext "subjectAltName=DNS:${host}" >/dev/null 2>&1; then
      openssl req -x509 -nodes -newkey rsa:2048 -days 825 -keyout "$key" -out "$cert" -subj "/CN=${host}" >/dev/null 2>&1
    fi
    chmod 640 "$key"
    chmod 644 "$cert"
  fi
}

configure_synapse_local_nginx() {
  [[ "$SYNAPSE_INSTALL_LOCAL_NGINX" == "true" ]] || return 0
  mkdir -p /etc/nginx/conf.d "$CERTBOT_WEBROOT"
  rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

  if [[ "$SYNAPSE_LOCAL_TLS" == "true" && "$SYNAPSE_LOCAL_LETSENCRYPT" == "true" ]]; then
    cat >"$SYNAPSE_NGINX_BOOTSTRAP_CONF" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${MATRIX_DOMAIN};
  location ^~ /.well-known/acme-challenge/ { root ${CERTBOT_WEBROOT}; }
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
    if certbot certonly --webroot -w "$CERTBOT_WEBROOT" -d "$MATRIX_DOMAIN" --email "$SYNAPSE_LOCAL_LE_EMAIL" --agree-tos --non-interactive; then
      SYNAPSE_TLS_CERT="/etc/letsencrypt/live/${MATRIX_DOMAIN}/fullchain.pem"
      SYNAPSE_TLS_KEY="/etc/letsencrypt/live/${MATRIX_DOMAIN}/privkey.pem"
    else
      warn "Let's Encrypt failed, using self-signed for local Synapse Nginx."
      SYNAPSE_TLS_CERT="/etc/ssl/matrix-synapse/local.crt"
      SYNAPSE_TLS_KEY="/etc/ssl/matrix-synapse/local.key"
      generate_self_signed_cert "$MATRIX_DOMAIN" "$SYNAPSE_TLS_CERT" "$SYNAPSE_TLS_KEY"
    fi
    rm -f "$SYNAPSE_NGINX_BOOTSTRAP_CONF"
  elif [[ "$SYNAPSE_LOCAL_TLS" == "true" ]]; then
    SYNAPSE_TLS_CERT="/etc/ssl/matrix-synapse/local.crt"
    SYNAPSE_TLS_KEY="/etc/ssl/matrix-synapse/local.key"
    generate_self_signed_cert "$MATRIX_DOMAIN" "$SYNAPSE_TLS_CERT" "$SYNAPSE_TLS_KEY"
  fi

  if [[ "$SYNAPSE_LOCAL_TLS" == "true" ]]; then
    cat >"$SYNAPSE_NGINX_CONF" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${MATRIX_DOMAIN};
  location ^~ /.well-known/acme-challenge/ { root ${CERTBOT_WEBROOT}; }
  return 301 https://\$host\$request_uri;
}
server {
  listen 443 ssl;
  listen [::]:443 ssl;
  http2 on;
  server_name ${MATRIX_DOMAIN};
  ssl_certificate ${SYNAPSE_TLS_CERT};
  ssl_certificate_key ${SYNAPSE_TLS_KEY};
  ssl_protocols TLSv1.2 TLSv1.3;
  location ~ ^(/_matrix|/_synapse/client) {
    proxy_pass http://127.0.0.1:8008;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
server {
  listen 8448 ssl;
  listen [::]:8448 ssl;
  http2 on;
  server_name ${MATRIX_DOMAIN};
  ssl_certificate ${SYNAPSE_TLS_CERT};
  ssl_certificate_key ${SYNAPSE_TLS_KEY};
  ssl_protocols TLSv1.2 TLSv1.3;
  location ~ ^(/_matrix|/_synapse/client) {
    proxy_pass http://127.0.0.1:8008;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
  else
    cat >"$SYNAPSE_NGINX_CONF" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${MATRIX_DOMAIN};
  location ~ ^(/_matrix|/_synapse/client) {
    proxy_pass http://127.0.0.1:8008;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
EOF
  fi
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

configure_coturn() {
  [[ "$SYNAPSE_INSTALL_COTURN" == "true" ]] || return 0
  local cert="/etc/turnserver/certs/turnserver.crt"
  local key="/etc/turnserver/certs/turnserver.key"
  generate_self_signed_cert "$TURN_HOST" "$cert" "$key"
  mkdir -p /var/log/turnserver
  cat >/etc/turnserver.conf <<EOF
use-auth-secret
static-auth-secret=${TURN_SHARED_SECRET}
realm=${MATRIX_DOMAIN}
server-name=${TURN_HOST}
fingerprint
lt-cred-mech
listening-port=3478
tls-listening-port=5349
min-port=49160
max-port=49200
no-multicast-peers
no-cli
cert=${cert}
pkey=${key}
log-file=/var/log/turnserver/turnserver.log
simple-log
EOF
  if [[ -f /etc/default/coturn ]]; then
    sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
  fi
  systemctl enable --now coturn 2>/dev/null || systemctl enable --now turnserver 2>/dev/null || die "Could not start coturn."
}

configure_fail2ban() {
  [[ "$SYNAPSE_INSTALL_FAIL2BAN" == "true" ]] || return 0
  mkdir -p /etc/fail2ban/jail.d
  cat >/etc/fail2ban/jail.d/matrix-synapse.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 6

[sshd]
enabled = true
EOF
  systemctl enable --now fail2ban
}

create_admin_user() {
  [[ "$SYNAPSE_CREATE_ADMIN" == "true" ]] || return 0
  local output rc
  set +e
  output="$("${SYNAPSE_VENV}/bin/register_new_matrix_user" \
    -u "$SYNAPSE_ADMIN_USER" \
    -p "$SYNAPSE_ADMIN_PASS" \
    -a \
    -k "$SYNAPSE_REGISTRATION_SHARED_SECRET" \
    "http://127.0.0.1:8008" 2>&1)"
  rc=$?
  set -e

  if [[ "$rc" -eq 0 ]]; then
    log "Admin user @${SYNAPSE_ADMIN_USER}:${MATRIX_DOMAIN} created."
    return 0
  fi

  if [[ "$output" == *"User ID already taken"* || "$output" == *"already exists"* ]]; then
    warn "Admin user @${SYNAPSE_ADMIN_USER}:${MATRIX_DOMAIN} already exists; continuing."
    return 0
  fi

  printf '%s\n' "$output" >&2
  die "Admin user creation failed."
}

resolve_element_tag_from_ess_helm() {
  local chart_url="$1"
  python3 - "$chart_url" <<'PY'
import io
import re
import sys
import tarfile
import urllib.request

chart_url = sys.argv[1]
with urllib.request.urlopen(chart_url, timeout=40) as response:
    content = response.read()

with tarfile.open(fileobj=io.BytesIO(content), mode="r:gz") as tar:
    values_member = None
    for name in tar.getnames():
        if name.endswith("/values.yaml"):
            values_member = name
            break
    if values_member is None:
        raise SystemExit("Could not find values.yaml in ESS helm chart.")
    values_text = tar.extractfile(values_member).read().decode("utf-8", "ignore")

match = re.search(
    r"(?ms)^elementWeb:\n(?:^[ \t].*\n)*?^[ \t]{2}image:\n(?:^[ \t].*\n)*?^[ \t]{4}tag:\s*[\"']?([^\"'\n#]+)",
    values_text,
)
if not match:
    raise SystemExit("Could not extract elementWeb.image.tag from ESS values.yaml")
print(match.group(1).strip())
PY
}

resolve_element_asset() {
  local req chart_tag chart_url metadata api_url
  req="${ELEMENT_VERSION_REQUEST}"
  api_url="https://api.github.com/repos/element-hq/element-web/releases/latest"
  chart_tag=""

  if [[ "$req" =~ ^https://github.com/element-hq/ess-helm/releases/tag/([^/]+)$ ]]; then
    chart_tag="${BASH_REMATCH[1]}"
  elif [[ "$req" =~ ^ess-helm:(.+)$ ]]; then
    chart_tag="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$chart_tag" ]]; then
    chart_url="https://github.com/element-hq/ess-helm/releases/download/${chart_tag}/matrix-stack-${chart_tag}.tgz"
    ELEMENT_RESOLVED_TAG="$(resolve_element_tag_from_ess_helm "$chart_url")"
    ELEMENT_VERSION_SOURCE="ess-helm:${chart_tag}"
    ELEMENT_ASSET_URL="https://github.com/element-hq/element-web/releases/download/${ELEMENT_RESOLVED_TAG}/element-${ELEMENT_RESOLVED_TAG}.tar.gz"
    return 0
  fi

  if [[ "${req,,}" == "latest" ]]; then
    metadata="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$api_url")"
    ELEMENT_RESOLVED_TAG="$(printf '%s\n' "$metadata" | jq -r '.tag_name')"
    [[ -n "$ELEMENT_RESOLVED_TAG" && "$ELEMENT_RESOLVED_TAG" != "null" ]] || die "Could not resolve latest Element release tag."
    ELEMENT_ASSET_URL="$(printf '%s\n' "$metadata" | jq -r '.assets[] | select(.name | test("^element-.*\\.tar\\.gz$")) | .browser_download_url' | awk 'NR==1{print; exit}')"
    ELEMENT_VERSION_SOURCE="element-web:latest"
  else
    if [[ "$req" =~ ^v ]]; then
      ELEMENT_RESOLVED_TAG="$req"
    else
      ELEMENT_RESOLVED_TAG="v${req}"
    fi
    ELEMENT_ASSET_URL="https://github.com/element-hq/element-web/releases/download/${ELEMENT_RESOLVED_TAG}/element-${ELEMENT_RESOLVED_TAG}.tar.gz"
    ELEMENT_VERSION_SOURCE="element-web:${ELEMENT_RESOLVED_TAG}"
  fi
}

install_element_files() {
  log "Installing Element Web..."
  resolve_element_asset
  local archive
  archive="/tmp/element-${ELEMENT_RESOLVED_TAG}.tar.gz"
  curl -fL "$ELEMENT_ASSET_URL" -o "$archive"
  mkdir -p "$ELEMENT_ROOT"
  find "$ELEMENT_ROOT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  tar -xzf "$archive" --strip-components=1 -C "$ELEMENT_ROOT"
  [[ -f "${ELEMENT_ROOT}/index.html" ]] || die "Element index.html missing after extraction."
  rm -f "$archive"
}

write_element_config_json() {
  cat >"${ELEMENT_ROOT}/config.json" <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "${ELEMENT_HOMESERVER_URL}",
      "server_name": "${MATRIX_DOMAIN}"
    },
    "m.identity_server": {
      "base_url": "https://vector.im"
    }
  },
  "disable_custom_urls": false,
  "disable_guests": false,
  "show_labs_settings": true,
  "brand": "Element"
}
EOF
}

element_static_locations() {
  cat <<'EOF'
    location = /config.json {
        add_header Cache-Control "no-store";
        try_files $uri =404;
    }

    location = /sw.js {
        add_header Cache-Control "no-cache";
        try_files $uri =404;
    }

    location = /service-worker.js {
        add_header Cache-Control "no-cache";
        try_files $uri =404;
    }

    location ~* \.(js|mjs|css|png|jpg|jpeg|gif|svg|ico|webp|woff|woff2|ttf|map)$ {
        try_files $uri =404;
        expires 7d;
        access_log off;
    }
EOF
}

element_matrix_proxy_locations() {
  [[ "$ELEMENT_PROXY_MATRIX_ENDPOINTS" == "true" ]] || return 0
  cat <<EOF
    location ~ ^(/_matrix|/_synapse/client) {
        proxy_pass ${ELEMENT_SYNAPSE_UPSTREAM};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 600s;
    }
EOF
}

disable_default_nginx_sites() {
  rm -f /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
}

configure_element_nginx() {
  mkdir -p /etc/nginx/conf.d "$CERTBOT_WEBROOT"
  disable_default_nginx_sites
  disable_stale_synapse_nginx

  if [[ "$EXTERNAL_REVERSE_PROXY" == "true" ]]; then
    cat >"$ELEMENT_NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ELEMENT_DOMAIN} _;
    root ${ELEMENT_ROOT};
    index index.html;

$(element_static_locations)

    location / {
        try_files \$uri \$uri/ /index.html;
    }
$(element_matrix_proxy_locations)
}
EOF
  elif [[ "$ELEMENT_LOCAL_TLS" == "true" ]]; then
    if [[ "$ELEMENT_LOCAL_LETSENCRYPT" == "true" ]]; then
      cat >"$ELEMENT_BOOTSTRAP_CONF" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${ELEMENT_DOMAIN};
  root ${ELEMENT_ROOT};
  location ^~ /.well-known/acme-challenge/ { root ${CERTBOT_WEBROOT}; }
  location / { try_files \$uri \$uri/ /index.html; }
}
EOF
      nginx -t
      systemctl enable --now nginx
      systemctl reload nginx
      if certbot certonly --webroot -w "$CERTBOT_WEBROOT" -d "$ELEMENT_DOMAIN" --email "$ELEMENT_LOCAL_LE_EMAIL" --agree-tos --non-interactive; then
        ELEMENT_TLS_CERT="/etc/letsencrypt/live/${ELEMENT_DOMAIN}/fullchain.pem"
        ELEMENT_TLS_KEY="/etc/letsencrypt/live/${ELEMENT_DOMAIN}/privkey.pem"
      else
        warn "Element Let's Encrypt failed, using self-signed."
        ELEMENT_TLS_CERT="/etc/ssl/element-web/local.crt"
        ELEMENT_TLS_KEY="/etc/ssl/element-web/local.key"
        generate_self_signed_cert "$ELEMENT_DOMAIN" "$ELEMENT_TLS_CERT" "$ELEMENT_TLS_KEY"
      fi
      rm -f "$ELEMENT_BOOTSTRAP_CONF"
    else
      ELEMENT_TLS_CERT="/etc/ssl/element-web/local.crt"
      ELEMENT_TLS_KEY="/etc/ssl/element-web/local.key"
      generate_self_signed_cert "$ELEMENT_DOMAIN" "$ELEMENT_TLS_CERT" "$ELEMENT_TLS_KEY"
    fi
    cat >"$ELEMENT_NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ELEMENT_DOMAIN};
    location ^~ /.well-known/acme-challenge/ { root ${CERTBOT_WEBROOT}; }
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name ${ELEMENT_DOMAIN};
    root ${ELEMENT_ROOT};
    index index.html;
    ssl_certificate ${ELEMENT_TLS_CERT};
    ssl_certificate_key ${ELEMENT_TLS_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 100M;

$(element_static_locations)

    location / { try_files \$uri \$uri/ /index.html; }
$(element_matrix_proxy_locations)
}
EOF
  else
    cat >"$ELEMENT_NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${ELEMENT_DOMAIN};
    root ${ELEMENT_ROOT};
    index index.html;

$(element_static_locations)

    location / { try_files \$uri \$uri/ /index.html; }
$(element_matrix_proxy_locations)
}
EOF
  fi

  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

configure_ufw() {
  local ssh_source syn_source elem_source
  ssh_source="$(printf '%s' "$SSH_SOURCE" | awk '{$1=$1; print}')"
  syn_source="$(printf '%s' "$SYNAPSE_BACKEND_SOURCE" | awk '{$1=$1; print}')"
  elem_source="$(printf '%s' "$ELEMENT_BACKEND_SOURCE" | awk '{$1=$1; print}')"
  [[ -n "$ssh_source" ]] || ssh_source="any"
  [[ -n "$syn_source" ]] || syn_source="any"
  [[ -n "$elem_source" ]] || elem_source="any"

  ufw default allow outgoing
  if [[ "${ssh_source,,}" == "any" ]]; then
    ufw allow 22/tcp comment 'SSH'
  elif is_valid_ip_or_cidr "$ssh_source"; then
    if ! ufw allow from "$ssh_source" to any port 22 proto tcp comment 'SSH restricted'; then
      warn "Invalid SSH source '${ssh_source}', fallback any."
      ufw allow 22/tcp comment 'SSH fallback'
      ssh_source="any"
    fi
  else
    warn "Invalid SSH source '${ssh_source}', fallback any."
    ufw allow 22/tcp comment 'SSH fallback'
    ssh_source="any"
  fi

  if [[ "$INSTALL_ELEMENT" == "true" ]]; then
    if [[ "${elem_source,,}" == "any" ]]; then
      ufw allow 80/tcp comment 'Element backend HTTP'
    elif is_valid_ip_or_cidr "$elem_source"; then
      ufw allow from "$elem_source" to any port 80 proto tcp comment 'Element backend restricted'
    else
      warn "Invalid Element backend source '${elem_source}', opening 80 from any."
      ufw allow 80/tcp comment 'Element backend fallback'
      elem_source="any"
    fi
    if [[ "$EXTERNAL_REVERSE_PROXY" == "false" && "$ELEMENT_LOCAL_TLS" == "true" ]]; then
      ufw allow 443/tcp comment 'Element HTTPS'
    fi
  fi

  if [[ "$INSTALL_SYNAPSE" == "true" ]]; then
    if [[ "$SYNAPSE_INSTALL_LOCAL_NGINX" == "true" ]]; then
      ufw allow 80/tcp comment 'Synapse HTTP'
      if [[ "$SYNAPSE_LOCAL_TLS" == "true" ]]; then
        ufw allow 443/tcp comment 'Synapse HTTPS'
        ufw allow 8448/tcp comment 'Synapse federation'
      fi
    else
      if [[ "${syn_source,,}" == "any" ]]; then
        ufw allow 8008/tcp comment 'Synapse backend'
      elif is_valid_ip_or_cidr "$syn_source"; then
        ufw allow from "$syn_source" to any port 8008 proto tcp comment 'Synapse backend restricted'
      else
        warn "Invalid Synapse backend source '${syn_source}', opening 8008 from any."
        ufw allow 8008/tcp comment 'Synapse backend fallback'
        syn_source="any"
      fi
    fi

    if [[ "$SYNAPSE_INSTALL_COTURN" == "true" ]]; then
      ufw allow 3478/tcp comment 'TURN TCP'
      ufw allow 3478/udp comment 'TURN UDP'
      ufw allow 5349/tcp comment 'TURN TLS'
      ufw allow 5349/udp comment 'TURN DTLS'
      ufw allow 49160:49200/udp comment 'TURN relay UDP range'
    fi
  fi

  ufw default deny incoming
  ufw --force enable
}

configure_firewalld() {
  systemctl enable --now firewalld
  firewall-cmd --permanent --add-service=ssh

  if [[ "$INSTALL_ELEMENT" == "true" ]]; then
    firewall-cmd --permanent --add-port=80/tcp
    if [[ "$EXTERNAL_REVERSE_PROXY" == "false" && "$ELEMENT_LOCAL_TLS" == "true" ]]; then
      firewall-cmd --permanent --add-port=443/tcp
    fi
  fi

  if [[ "$INSTALL_SYNAPSE" == "true" ]]; then
    if [[ "$SYNAPSE_INSTALL_LOCAL_NGINX" == "true" ]]; then
      firewall-cmd --permanent --add-port=80/tcp
      if [[ "$SYNAPSE_LOCAL_TLS" == "true" ]]; then
        firewall-cmd --permanent --add-port=443/tcp
        firewall-cmd --permanent --add-port=8448/tcp
      fi
    else
      firewall-cmd --permanent --add-port=8008/tcp
    fi
    if [[ "$SYNAPSE_INSTALL_COTURN" == "true" ]]; then
      firewall-cmd --permanent --add-port=3478/tcp
      firewall-cmd --permanent --add-port=3478/udp
      firewall-cmd --permanent --add-port=5349/tcp
      firewall-cmd --permanent --add-port=5349/udp
      firewall-cmd --permanent --add-port=49160-49200/udp
    fi
  fi
  firewall-cmd --reload
}

configure_firewall() {
  [[ "$CONFIGURE_FIREWALL" == "true" ]] || return 0
  log "Configuring firewall..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    configure_ufw
  else
    configure_firewalld
  fi
}

write_summary() {
  cat >"$SUMMARY_FILE" <<EOF
Matrix Full Stack Install Summary
=================================
Date: $(date)
OS: ${PRETTY_NAME}
Mode: synapse=${INSTALL_SYNAPSE}, element=${INSTALL_ELEMENT}
External reverse proxy: ${EXTERNAL_REVERSE_PROXY}

Domains
-------
Matrix domain: ${MATRIX_DOMAIN}
Element domain: ${ELEMENT_DOMAIN}

Synapse
-------
DB backend: ${DB_BACKEND}
DB name: ${DB_NAME}
DB user: ${DB_USER}
DB pass: ${DB_PASS}
Public base URL: ${SYNAPSE_PUBLIC_BASEURL}
Local Synapse Nginx: ${SYNAPSE_INSTALL_LOCAL_NGINX}
Open registration: ${SYNAPSE_ENABLE_OPEN_REGISTRATION}
Allow unverified registration: ${SYNAPSE_ALLOW_UNVERIFIED_REGISTRATION}
Admin created: ${SYNAPSE_CREATE_ADMIN}
Admin user: ${SYNAPSE_ADMIN_USER}
Admin pass: ${SYNAPSE_ADMIN_PASS}
Coturn installed: ${SYNAPSE_INSTALL_COTURN}
TURN host: ${TURN_HOST}
TURN secret: ${TURN_SHARED_SECRET}
Fail2ban installed: ${SYNAPSE_INSTALL_FAIL2BAN}

Element
-------
Requested version: ${ELEMENT_VERSION_REQUEST}
Resolved tag: ${ELEMENT_RESOLVED_TAG}
Version source: ${ELEMENT_VERSION_SOURCE}
Homeserver URL: ${ELEMENT_HOMESERVER_URL}
Proxy matrix endpoints locally: ${ELEMENT_PROXY_MATRIX_ENDPOINTS}
Local Element TLS: ${ELEMENT_LOCAL_TLS}

Firewall
--------
Configured: ${CONFIGURE_FIREWALL}
SSH source: ${SSH_SOURCE}
Synapse backend source: ${SYNAPSE_BACKEND_SOURCE}
Element backend source: ${ELEMENT_BACKEND_SOURCE}
EOF
  chmod 600 "$SUMMARY_FILE"
}

run_synapse_install() {
  if [[ "$DB_BACKEND" == "postgresql" ]]; then
    setup_postgres_database
  else
    setup_mariadb_database
  fi
  create_synapse_user_and_dirs
  install_synapse_python
  configure_synapse_yaml
  write_synapse_systemd_unit
  if ! wait_for_synapse; then
    journalctl -u matrix-synapse --no-pager -n 100 || true
    die "Synapse failed to become ready."
  fi
  if [[ "$SYNAPSE_INSTALL_LOCAL_NGINX" == "true" ]]; then
    configure_synapse_local_nginx
  else
    disable_stale_synapse_nginx
  fi
  configure_coturn
  if [[ "$SYNAPSE_INSTALL_COTURN" == "true" ]]; then
    systemctl restart matrix-synapse
    wait_for_synapse || die "Synapse failed after coturn configuration."
  fi
  configure_fail2ban
  create_admin_user
}

run_element_install() {
  install_element_files
  write_element_config_json
  configure_element_nginx
}

main() {
  parse_args "$@"
  require_root
  require_systemd
  choose_mode
  detect_os

  printf "\nDetected OS: %s\n" "$PRETTY_NAME"
  collect_inputs
  install_required_packages

  if [[ "$INSTALL_SYNAPSE" == "true" ]]; then
    run_synapse_install
  fi
  if [[ "$INSTALL_ELEMENT" == "true" ]]; then
    run_element_install
  fi

  configure_firewall
  write_summary

  printf "\n"
  log "Installation completed."
  if [[ "$INSTALL_SYNAPSE" == "true" ]]; then
    printf "  - Synapse: %s\n" "$SYNAPSE_PUBLIC_BASEURL"
  fi
  if [[ "$INSTALL_ELEMENT" == "true" ]]; then
    if [[ "$EXTERNAL_REVERSE_PROXY" == "true" ]]; then
      printf "  - Element backend: http://%s:80\n" "$(hostname -I | awk '{print $1}')"
      printf "  - Public UI via proxy: https://%s/\n" "$ELEMENT_DOMAIN"
    else
      if [[ "$ELEMENT_LOCAL_TLS" == "true" ]]; then
        printf "  - Element UI: https://%s/\n" "$ELEMENT_DOMAIN"
      else
        printf "  - Element UI: http://%s/\n" "$ELEMENT_DOMAIN"
      fi
    fi
  fi
  printf "  - Summary: %s\n\n" "$SUMMARY_FILE"
}

main "$@"
