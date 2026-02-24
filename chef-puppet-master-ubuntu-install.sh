#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"
SUMMARY_FILE="/root/chef-puppet-install-summary.txt"
CHEF_KEY_DIR="/etc/chef"
KNIFE_DIR="/root/.chef"
PUPPETBOARD_VENV="/opt/puppetboard/venv"
PUPPETBOARD_SETTINGS="/etc/puppetboard/settings.py"
PUPPETBOARD_SERVICE="/etc/systemd/system/puppetboard.service"

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

generate_secret() {
  openssl rand -hex 16
}

wait_for_service() {
  local service_name="$1"
  local timeout="${2:-180}"
  local elapsed=0

  while ! systemctl is-active --quiet "$service_name"; do
    sleep 2
    elapsed=$((elapsed + 2))
    if (( elapsed >= timeout )); then
      systemctl --no-pager --full status "$service_name" || true
      die "Service '$service_name' did not become active within ${timeout}s."
    fi
  done
}

download_file() {
  local url="$1"
  local destination="$2"
  curl -fL "$url" -o "$destination"
}

fetch_chef_package_url() {
  local product="$1"
  local metadata_url metadata package_url

  metadata_url="https://omnitruck.chef.io/${CHEF_CHANNEL}/${product}/metadata?p=ubuntu&pv=${UBUNTU_VERSION}&m=x86_64"
  metadata="$(curl -fsSL "$metadata_url")" || die "Failed to query Chef package metadata for ${product}."
  package_url="$(printf '%s\n' "$metadata" | awk -F '\t' '$1=="url"{print $2}')"
  [[ -n "$package_url" ]] || die "Could not resolve download URL for ${product}."
  printf '%s' "$package_url"
}

ensure_line_in_hosts() {
  local ip="$1"
  local fqdn="$2"
  local short_name="$3"
  local hosts_line="${ip} ${fqdn} ${short_name}"

  if ! getent hosts "$fqdn" >/dev/null 2>&1; then
    warn "Hostname '${fqdn}' is not resolvable. Adding a local /etc/hosts entry."
    printf '%s\n' "$hosts_line" >> /etc/hosts
  fi
}

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "Run this script as root."
fi

if ! command_exists systemctl; then
  die "systemd is required."
fi

[[ -r /etc/os-release ]] || die "/etc/os-release not found."
# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID,,}" != "ubuntu" ]]; then
  die "This installer currently supports Ubuntu only."
fi

UBUNTU_VERSION="${VERSION_ID:-}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
[[ -n "$UBUNTU_VERSION" ]] || die "Could not detect Ubuntu version."
[[ -n "$UBUNTU_CODENAME" ]] || die "Could not detect Ubuntu codename."

HOST_FQDN="$(hostname -f 2>/dev/null || true)"
if [[ -z "$HOST_FQDN" || "$HOST_FQDN" == "(none)" ]]; then
  HOST_FQDN="$(hostname)"
fi
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"

CHEF_CHANNEL="${CHEF_CHANNEL:-stable}"
CHEF_ADMIN_USER="${CHEF_ADMIN_USER:-chefadmin}"
CHEF_ADMIN_FIRST_NAME="${CHEF_ADMIN_FIRST_NAME:-Chef}"
CHEF_ADMIN_LAST_NAME="${CHEF_ADMIN_LAST_NAME:-Admin}"
CHEF_ADMIN_EMAIL="${CHEF_ADMIN_EMAIL:-chefadmin@${HOST_FQDN}}"
if [[ -n "${CHEF_ADMIN_PASSWORD:-}" ]]; then
  CHEF_ADMIN_PASSWORD_SOURCE="provided"
else
  CHEF_ADMIN_PASSWORD="$(generate_secret)"
  CHEF_ADMIN_PASSWORD_SOURCE="generated"
fi
CHEF_ORG_SHORT="${CHEF_ORG_SHORT:-infra}"
CHEF_ORG_FULL="${CHEF_ORG_FULL:-Infrastructure Organization}"
INSTALL_CHEF_WORKSTATION="${INSTALL_CHEF_WORKSTATION:-true}"

PUPPET_CERTNAME="${PUPPET_CERTNAME:-${HOST_FQDN}}"
PUPPET_DNS_ALT_NAMES="${PUPPET_DNS_ALT_NAMES:-${HOST_FQDN},puppet}"
PUPPETSERVER_JAVA_ARGS="${PUPPETSERVER_JAVA_ARGS:--Xms1g -Xmx1g}"
PUPPETBOARD_BIND="${PUPPETBOARD_BIND:-0.0.0.0}"
PUPPETBOARD_PORT="${PUPPETBOARD_PORT:-3000}"
CONFIGURE_UFW="${CONFIGURE_UFW:-true}"

CHEF_ADMIN_PEM="${CHEF_KEY_DIR}/${CHEF_ADMIN_USER}.pem"
CHEF_ORG_PEM="${CHEF_KEY_DIR}/${CHEF_ORG_SHORT}-validator.pem"
PUPPETBOARD_URL="http://${HOST_FQDN}:${PUPPETBOARD_PORT}/"
CHEF_ORG_URL="https://${HOST_FQDN}/organizations/${CHEF_ORG_SHORT}"

install_base_packages() {
  log "Installing base dependencies..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    jq \
    lsb-release \
    openssl \
    python3 \
    python3-pip \
    python3-venv \
    ufw \
    wget
}

install_chef_server() {
  local package_url package_path

  if dpkg -s chef-server-core >/dev/null 2>&1; then
    log "Chef Infra Server is already installed."
  else
    log "Installing Chef Infra Server..."
    package_url="$(fetch_chef_package_url "chef-server")"
    package_path="/tmp/chef-server-core_${UBUNTU_VERSION}_amd64.deb"
    download_file "$package_url" "$package_path"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_path"
    rm -f "$package_path"
  fi

  log "Reconfiguring Chef Infra Server..."
  chef-server-ctl reconfigure

  mkdir -p "$CHEF_KEY_DIR"

  if chef-server-ctl user-show "$CHEF_ADMIN_USER" >/dev/null 2>&1; then
    warn "Chef admin user '${CHEF_ADMIN_USER}' already exists; skipping user-create."
  else
    log "Creating Chef admin user '${CHEF_ADMIN_USER}'..."
    chef-server-ctl user-create \
      "$CHEF_ADMIN_USER" \
      "$CHEF_ADMIN_FIRST_NAME" \
      "$CHEF_ADMIN_LAST_NAME" \
      "$CHEF_ADMIN_EMAIL" \
      "$CHEF_ADMIN_PASSWORD" \
      --filename "$CHEF_ADMIN_PEM"
    chmod 600 "$CHEF_ADMIN_PEM"
  fi

  if chef-server-ctl org-show "$CHEF_ORG_SHORT" >/dev/null 2>&1; then
    warn "Chef organization '${CHEF_ORG_SHORT}' already exists; skipping org-create."
  else
    log "Creating Chef organization '${CHEF_ORG_SHORT}'..."
    chef-server-ctl org-create \
      "$CHEF_ORG_SHORT" \
      "$CHEF_ORG_FULL" \
      --association_user "$CHEF_ADMIN_USER" \
      --filename "$CHEF_ORG_PEM"
    chmod 600 "$CHEF_ORG_PEM"
  fi
}

install_chef_workstation() {
  local package_url package_path

  if ! is_true "$INSTALL_CHEF_WORKSTATION"; then
    log "Skipping Chef Workstation install (INSTALL_CHEF_WORKSTATION=${INSTALL_CHEF_WORKSTATION})."
    return 0
  fi

  if dpkg -s chef-workstation >/dev/null 2>&1; then
    log "Chef Workstation is already installed."
    return 0
  fi

  log "Installing Chef Workstation..."
  package_url="$(fetch_chef_package_url "chef-workstation")"
  package_path="/tmp/chef-workstation_${UBUNTU_VERSION}_amd64.deb"
  download_file "$package_url" "$package_path"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$package_path"
  rm -f "$package_path"
}

configure_knife() {
  if ! command_exists knife; then
    warn "knife command is not available; skipping knife bootstrap config."
    return 0
  fi

  if [[ ! -f "$CHEF_ADMIN_PEM" ]]; then
    warn "Chef admin PEM key not found at ${CHEF_ADMIN_PEM}; skipping knife bootstrap config."
    return 0
  fi

  log "Configuring knife for root user..."
  mkdir -p "$KNIFE_DIR"
  cp -f "$CHEF_ADMIN_PEM" "${KNIFE_DIR}/${CHEF_ADMIN_USER}.pem"
  chmod 600 "${KNIFE_DIR}/${CHEF_ADMIN_USER}.pem"

  cat > "${KNIFE_DIR}/config.rb" <<EOF
current_dir = File.dirname(__FILE__)
log_level                :info
log_location             STDOUT
node_name                "${CHEF_ADMIN_USER}"
client_key               "#{current_dir}/${CHEF_ADMIN_USER}.pem"
chef_server_url          "${CHEF_ORG_URL}"
trusted_certs_dir        "#{current_dir}/trusted_certs"
EOF
  chmod 600 "${KNIFE_DIR}/config.rb"

  if knife ssl fetch "https://${HOST_FQDN}" >/dev/null 2>&1; then
    log "Fetched Chef server TLS certificate for knife."
  else
    warn "Could not fetch Chef TLS certificate automatically. Run 'knife ssl fetch' manually if needed."
  fi
}

install_puppet_repo() {
  local release_pkg release_url

  if dpkg -s puppet8-release >/dev/null 2>&1; then
    log "Puppet 8 apt repository package is already installed."
  else
    log "Installing Puppet 8 apt repository package..."
    release_pkg="/tmp/puppet8-release-${UBUNTU_CODENAME}.deb"
    release_url="https://apt.puppet.com/puppet8-release-${UBUNTU_CODENAME}.deb"
    download_file "$release_url" "$release_pkg"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$release_pkg"
    rm -f "$release_pkg"
  fi

  apt-get update -y
}

configure_puppet_files() {
  log "Configuring Puppet Server and PuppetDB integration..."

  if [[ -f /etc/default/puppetserver ]]; then
    if awk '/^JAVA_ARGS=/' /etc/default/puppetserver >/dev/null; then
      sed -i "s|^JAVA_ARGS=.*|JAVA_ARGS=\"${PUPPETSERVER_JAVA_ARGS}\"|" /etc/default/puppetserver
    else
      printf 'JAVA_ARGS="%s"\n' "$PUPPETSERVER_JAVA_ARGS" >> /etc/default/puppetserver
    fi
  fi

  mkdir -p /etc/puppetlabs/puppet

  cat > /etc/puppetlabs/puppet/puppet.conf <<EOF
[main]
certname = ${PUPPET_CERTNAME}
server = ${PUPPET_CERTNAME}
environment = production
runinterval = 1h

[master]
dns_alt_names = ${PUPPET_DNS_ALT_NAMES}
storeconfigs = true
storeconfigs_backend = puppetdb
reports = store,puppetdb
EOF

  cat > /etc/puppetlabs/puppet/puppetdb.conf <<EOF
[main]
server_urls = https://${PUPPET_CERTNAME}:8081
soft_write_failure = false
EOF

  cat > /etc/puppetlabs/puppet/routes.yaml <<EOF
---
master:
  facts:
    terminus: puppetdb
    cache: yaml
  catalog:
    terminus: puppetdb
    cache: yaml
  report:
    terminus: puppetdb
    cache: yaml
  resource:
    terminus: puppetdb
    cache: yaml
EOF
}

install_puppet_stack() {
  log "Installing Puppet Server, PuppetDB, and dependencies..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    openjdk-17-jre-headless \
    puppetdb \
    puppetdb-termini \
    puppetserver

  configure_puppet_files
}

setup_puppet_services() {
  log "Starting Puppet Server..."
  systemctl enable --now puppetserver
  wait_for_service puppetserver 300

  if [[ -x /opt/puppetlabs/bin/puppetdb ]]; then
    log "Initializing PuppetDB SSL materials..."
    /opt/puppetlabs/bin/puppetdb ssl-setup -f || warn "PuppetDB SSL setup returned a non-zero status."
  elif [[ -x /opt/puppetlabs/server/apps/puppetdb/cli/apps/puppetdb ]]; then
    log "Initializing PuppetDB SSL materials..."
    /opt/puppetlabs/server/apps/puppetdb/cli/apps/puppetdb ssl-setup -f || warn "PuppetDB SSL setup returned a non-zero status."
  else
    warn "Could not find puppetdb ssl-setup command. PuppetDB SSL setup may require manual action."
  fi

  log "Starting PuppetDB..."
  systemctl enable --now puppetdb
  wait_for_service puppetdb 180

  log "Restarting Puppet Server to apply PuppetDB configuration..."
  systemctl restart puppetserver
  wait_for_service puppetserver 180
}

install_puppetboard() {
  log "Installing Puppetboard web UI..."

  if ! id -u puppetboard >/dev/null 2>&1; then
    useradd --system --home /var/lib/puppetboard --create-home --shell /usr/sbin/nologin puppetboard
  fi

  mkdir -p /opt/puppetboard /etc/puppetboard

  if [[ ! -x "${PUPPETBOARD_VENV}/bin/python3" ]]; then
    python3 -m venv "$PUPPETBOARD_VENV"
  fi

  "${PUPPETBOARD_VENV}/bin/pip" install --upgrade pip setuptools wheel
  "${PUPPETBOARD_VENV}/bin/pip" install --upgrade gunicorn puppetboard

  cat > "$PUPPETBOARD_SETTINGS" <<EOF
PUPPETDB_HOST = '127.0.0.1'
PUPPETDB_PORT = 8081
PUPPETDB_PROTO = 'https'
PUPPETDB_SSL_VERIFY = False
LOCALISE_TIMESTAMP = True
EOF

  cat > "$PUPPETBOARD_SERVICE" <<EOF
[Unit]
Description=Puppetboard web UI
After=network-online.target puppetdb.service
Wants=network-online.target

[Service]
Type=simple
User=puppetboard
Group=puppetboard
Environment="PUPPETBOARD_SETTINGS=${PUPPETBOARD_SETTINGS}"
ExecStart=${PUPPETBOARD_VENV}/bin/gunicorn --workers 2 --bind ${PUPPETBOARD_BIND}:${PUPPETBOARD_PORT} --access-logfile - --error-logfile - puppetboard.app:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  chown -R puppetboard:puppetboard /opt/puppetboard /etc/puppetboard
  chmod 640 "$PUPPETBOARD_SETTINGS"

  systemctl daemon-reload
  systemctl enable --now puppetboard
  wait_for_service puppetboard 90
}

configure_firewall() {
  if ! is_true "$CONFIGURE_UFW"; then
    log "Skipping UFW configuration (CONFIGURE_UFW=${CONFIGURE_UFW})."
    return 0
  fi

  log "Applying UFW firewall rules..."
  ufw allow 22/tcp comment 'SSH'
  ufw allow 80/tcp comment 'Chef HTTP'
  ufw allow 443/tcp comment 'Chef HTTPS'
  ufw allow 8140/tcp comment 'Puppet Server'
  ufw allow "${PUPPETBOARD_PORT}/tcp" comment 'Puppetboard UI'
  ufw --force enable
}

verify_stack() {
  local failures=0
  local service=""

  for service in chef-server-runsvdir puppetserver puppetdb puppetboard; do
    if systemctl is-active --quiet "$service"; then
      log "Service '${service}' is active."
    else
      warn "Service '${service}' is not active."
      failures=$((failures + 1))
    fi
  done

  if curl -fsS "http://127.0.0.1:${PUPPETBOARD_PORT}/" >/dev/null 2>&1; then
    log "Puppetboard responded on http://127.0.0.1:${PUPPETBOARD_PORT}/"
  else
    warn "Could not reach Puppetboard locally."
    failures=$((failures + 1))
  fi

  if (( failures > 0 )); then
    warn "Verification detected ${failures} issue(s). Check service status for details."
  else
    log "Verification checks passed."
  fi
}

write_summary() {
  cat > "$SUMMARY_FILE" <<EOF
Chef + Puppet Master install summary
===================================
Version: ${SCRIPT_VERSION}
Date: $(date)
Host FQDN: ${HOST_FQDN}
Ubuntu: ${PRETTY_NAME:-Ubuntu ${UBUNTU_VERSION}}

Chef Infra Server
-----------------
URL: https://${HOST_FQDN}/
Admin user: ${CHEF_ADMIN_USER}
Admin email: ${CHEF_ADMIN_EMAIL}
Admin password source: ${CHEF_ADMIN_PASSWORD_SOURCE}
Admin password: ${CHEF_ADMIN_PASSWORD}
Admin key: ${CHEF_ADMIN_PEM}
Organization short name: ${CHEF_ORG_SHORT}
Organization full name: ${CHEF_ORG_FULL}
Organization validator key: ${CHEF_ORG_PEM}
Organization URL: ${CHEF_ORG_URL}

Puppet Master + UI
------------------
Puppet certname: ${PUPPET_CERTNAME}
Puppet DNS alt names: ${PUPPET_DNS_ALT_NAMES}
Puppet Server endpoint: https://${HOST_FQDN}:8140/
PuppetDB endpoint: https://${HOST_FQDN}:8081/
Puppetboard bind: ${PUPPETBOARD_BIND}
Puppetboard URL: ${PUPPETBOARD_URL}

Notes
-----
- Puppetboard is deployed without authentication by default.
- Restrict network access to port ${PUPPETBOARD_PORT} and/or place it behind a reverse proxy with auth for production use.
EOF
  chmod 600 "$SUMMARY_FILE"
}

print_final_notes() {
  printf '\n'
  log "Chef Infra Server + Puppet Master + Puppetboard install completed."
  printf "  - Chef Server URL:      https://%s/\n" "$HOST_FQDN"
  printf "  - Puppetboard URL:      %s\n" "$PUPPETBOARD_URL"
  printf "  - Puppet endpoint:      https://%s:8140/\n" "$HOST_FQDN"
  printf "  - Summary file:         %s\n\n" "$SUMMARY_FILE"
}

main() {
  log "Starting installer v${SCRIPT_VERSION} on ${PRETTY_NAME:-Ubuntu} (${HOST_FQDN})"
  ensure_line_in_hosts "127.0.1.1" "$HOST_FQDN" "$HOST_SHORT"
  install_base_packages
  install_chef_server
  install_chef_workstation
  configure_knife
  install_puppet_repo
  install_puppet_stack
  setup_puppet_services
  install_puppetboard
  configure_firewall
  verify_stack
  write_summary
  print_final_notes
}

main "$@"
