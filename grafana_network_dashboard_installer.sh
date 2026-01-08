#!/usr/bin/env bash
#
# Grafana dashboard installer (Grafana.com dashboard ID 13140)
# Source: https://grafana.com/grafana/dashboards/13140-network/
#
# Supports:
# - Multi-run idempotent installs
# - Multi-distro package install paths (best-effort)
# - Provisioning-based install (local Grafana filesystem)
# - API-based import install (remote/Docker Grafana)
#
set -euo pipefail

# -----------------------------
# Config (env overrides)
# -----------------------------
DASHBOARD_ID="${DASHBOARD_ID:-13140}"
DASHBOARD_REVISION="${DASHBOARD_REVISION:-latest}"
DASHBOARD_SOURCE_URL="${DASHBOARD_SOURCE_URL:-https://grafana.com/api/dashboards/${DASHBOARD_ID}/revisions/${DASHBOARD_REVISION}/download}"

MODE="${MODE:-auto}" # auto|provisioning|api

# Grafana API (only needed for MODE=api or optional checks)
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASS="${GRAFANA_PASS:-admin}"
GRAFANA_API_TOKEN="${GRAFANA_API_TOKEN:-}"

# If Grafana is not installed, attempt install (best-effort) when 1
INSTALL_GRAFANA="${INSTALL_GRAFANA:-1}"

# Dashboard folder (provisioning mode)
GRAFANA_FOLDER_NAME="${GRAFANA_FOLDER_NAME:-Network}"

# InfluxDB datasource handling (this dashboard uses ${DS_INFLUXDB})
INFLUXDB_DS_NAME="${INFLUXDB_DS_NAME:-InfluxDB}"
INFLUXDB_URL="${INFLUXDB_URL:-}"               # e.g. http://localhost:8086
INFLUXDB_DATABASE="${INFLUXDB_DATABASE:-}"     # InfluxDB v1 database name (InfluxQL)
INFLUXDB_USER="${INFLUXDB_USER:-}"
INFLUXDB_PASSWORD="${INFLUXDB_PASSWORD:-}"
INFLUXDB_ORGANIZATION="${INFLUXDB_ORGANIZATION:-}" # InfluxDB v2 (Flux)
INFLUXDB_BUCKET="${INFLUXDB_BUCKET:-}"             # InfluxDB v2 (Flux)
INFLUXDB_TOKEN="${INFLUXDB_TOKEN:-}"               # InfluxDB v2 (Flux)
INFLUXDB_VERSION="${INFLUXDB_VERSION:-influxql}"   # influxql|flux
INFLUXDB_IS_DEFAULT="${INFLUXDB_IS_DEFAULT:-0}"    # 1 to make default datasource

# Paths (standard Grafana Linux package locations)
GRAFANA_ETC_DIR="${GRAFANA_ETC_DIR:-/etc/grafana}"
GRAFANA_PROVISIONING_DIR="${GRAFANA_PROVISIONING_DIR:-${GRAFANA_ETC_DIR}/provisioning}"
GRAFANA_DASHBOARDS_DIR="${GRAFANA_DASHBOARDS_DIR:-/var/lib/grafana/dashboards}"

DASHBOARD_JSON_NAME="${DASHBOARD_JSON_NAME:-grafana-dashboard-${DASHBOARD_ID}-network.json}"
DASHBOARD_JSON_PATH="${DASHBOARD_JSON_PATH:-${GRAFANA_DASHBOARDS_DIR}/${DASHBOARD_JSON_NAME}}"
DASHBOARD_PROVIDER_YAML="${DASHBOARD_PROVIDER_YAML:-${GRAFANA_PROVISIONING_DIR}/dashboards/${DASHBOARD_ID}-network-provider.yaml}"
DATASOURCE_YAML="${DATASOURCE_YAML:-${GRAFANA_PROVISIONING_DIR}/datasources/${INFLUXDB_DS_NAME// /_}-influxdb.yaml}"

# -----------------------------
# Logging
# -----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# -----------------------------
# Helpers
# -----------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  die "Run as root (or install sudo)."
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v pacman >/dev/null 2>&1; then echo "pacman"; return; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return; fi
  echo "unknown"
}

pkg_install() {
  local pm; pm="$(detect_pm)"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y --no-install-recommends "$@"
      ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    pacman) pacman -Sy --noconfirm --needed "$@" ;;
    zypper) zypper --non-interactive install --no-recommends "$@" ;;
    apk) apk add --no-cache "$@" ;;
    *) die "Unsupported package manager. Install dependencies manually: $*" ;;
  esac
}

write_file_if_changed() {
  local path="$1"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  install -D -m 0644 "$tmp" "$path"
  rm -f "$tmp"
  return 0
}

grafana_running_api_ok() {
  curl -fsS --max-time 3 "${GRAFANA_URL%/}/api/health" >/dev/null 2>&1
}

curl_auth_args() {
  if [[ -n "$GRAFANA_API_TOKEN" ]]; then
    printf '%s\n' "-H" "Authorization: Bearer ${GRAFANA_API_TOKEN}"
  else
    printf '%s\n' "-u" "${GRAFANA_USER}:${GRAFANA_PASS}"
  fi
}

restart_grafana_if_possible() {
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx 'grafana-server.service'; then
      log "Restarting grafana-server"
      if ! systemctl restart grafana-server; then
        warn "systemctl restart grafana-server failed; restart Grafana manually to load provisioning changes."
      fi
      return 0
    fi
  fi
  warn "Could not restart Grafana automatically. If using provisioning, restart Grafana manually."
  return 0
}

ensure_grafana_installed() {
  if command -v grafana-server >/dev/null 2>&1 || [[ -x /usr/sbin/grafana-server || -x /usr/share/grafana/bin/grafana-server ]]; then
    return 0
  fi
  if [[ "$INSTALL_GRAFANA" != "1" ]]; then
    die "Grafana not found and INSTALL_GRAFANA=0. Install Grafana, then re-run."
  fi

  log "Grafana not found; attempting to install (best-effort)"
  local pm; pm="$(detect_pm)"
  case "$pm" in
    apt)
      pkg_install ca-certificates curl gnupg
      install -d -m 0755 /etc/apt/keyrings
      if [[ ! -f /etc/apt/keyrings/grafana.gpg ]]; then
        curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
        chmod 0644 /etc/apt/keyrings/grafana.gpg
      fi
      if [[ ! -f /etc/apt/sources.list.d/grafana.list ]]; then
        echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" >/etc/apt/sources.list.d/grafana.list
      fi
      apt-get update -y
      apt-get install -y grafana
      ;;
    dnf|yum)
      pkg_install ca-certificates curl
      if [[ ! -f /etc/yum.repos.d/grafana.repo ]]; then
        cat >/etc/yum.repos.d/grafana.repo <<'EOF'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
EOF
      fi
      pkg_install grafana
      ;;
    pacman)
      pkg_install grafana
      ;;
    apk)
      pkg_install grafana
      ;;
    zypper)
      # Grafana availability depends on repo; try anyway.
      pkg_install grafana || die "Grafana install failed on this distro. Install Grafana manually, then re-run."
      ;;
    *)
      die "Cannot auto-install Grafana on this distro. Install Grafana manually, then re-run."
      ;;
  esac

  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now grafana-server >/dev/null 2>&1 || true
  fi
}

download_and_render_dashboard() {
  local out_path="$1"
  local ds_name="$2"
  local tmp_json raw_json
  tmp_json="$(mktemp)"
  raw_json="$(mktemp)"

  log "Downloading dashboard ${DASHBOARD_ID} (revision: ${DASHBOARD_REVISION}) from Grafana.com"
  curl -fsSL "$DASHBOARD_SOURCE_URL" -o "$raw_json"

  # Rewrite placeholders so provisioning can load unattended:
  # - Replace every string exactly "${DS_INFLUXDB}" with the chosen datasource name
  # - Strip __inputs/__requires (Grafana import helpers) to avoid unresolved input variables
  # - Null the "id" field for clean imports
  python3 - "$raw_json" "$tmp_json" "$ds_name" <<'PY'
import json,sys
src, dst, ds = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src,'r',encoding='utf-8') as f:
    data = json.load(f)
def walk(x):
    if isinstance(x, dict):
        return {k: walk(v) for k,v in x.items()}
    if isinstance(x, list):
        return [walk(v) for v in x]
    if isinstance(x, str) and x == "${DS_INFLUXDB}":
        return ds
    return x
data = walk(data)
if isinstance(data, dict) and "id" in data:
    data["id"] = None
if isinstance(data, dict):
    data.pop("__inputs", None)
    data.pop("__requires", None)
with open(dst,'w',encoding='utf-8') as f:
    json.dump(data,f,ensure_ascii=False,indent=2)
PY

  if [[ -f "$out_path" ]] && cmp -s "$tmp_json" "$out_path"; then
    rm -f "$tmp_json" "$raw_json"
    log "Dashboard JSON already up-to-date: ${out_path}"
    return 1
  fi

  install -D -m 0644 "$tmp_json" "$out_path"
  rm -f "$tmp_json" "$raw_json"
  log "Wrote dashboard JSON: ${out_path}"
  return 0
}

ensure_dirs_and_perms() {
  install -d -m 0755 "${GRAFANA_PROVISIONING_DIR}/dashboards" "${GRAFANA_PROVISIONING_DIR}/datasources" "${GRAFANA_DASHBOARDS_DIR}"
  if id grafana >/dev/null 2>&1; then
    chown -R grafana:grafana /var/lib/grafana >/dev/null 2>&1 || true
  fi
}

install_provisioning_files() {
  ensure_dirs_and_perms

  local changed=0
  if download_and_render_dashboard "$DASHBOARD_JSON_PATH" "$INFLUXDB_DS_NAME"; then
    changed=1
  fi

  if write_file_if_changed "$DASHBOARD_PROVIDER_YAML" <<EOF
apiVersion: 1
providers:
  - name: "dashboard-${DASHBOARD_ID}-network"
    orgId: 1
    folder: "${GRAFANA_FOLDER_NAME}"
    type: file
    disableDeletion: false
    editable: true
    options:
      path: "${GRAFANA_DASHBOARDS_DIR}"
      foldersFromFilesStructure: false
EOF
  then
    log "Wrote dashboard provider: ${DASHBOARD_PROVIDER_YAML}"
    changed=1
  else
    log "Dashboard provider already up-to-date: ${DASHBOARD_PROVIDER_YAML}"
  fi

  # Optional datasource provisioning if user supplied connection details
  if [[ -n "$INFLUXDB_URL" ]]; then
    if [[ "${INFLUXDB_VERSION,,}" == "flux" ]] || [[ -n "$INFLUXDB_TOKEN" || -n "$INFLUXDB_BUCKET" || -n "$INFLUXDB_ORGANIZATION" ]]; then
      if [[ -z "$INFLUXDB_TOKEN" || -z "$INFLUXDB_BUCKET" || -z "$INFLUXDB_ORGANIZATION" ]]; then
        warn "INFLUXDB_VERSION=flux selected but one of INFLUXDB_TOKEN/INFLUXDB_BUCKET/INFLUXDB_ORGANIZATION is missing; skipping datasource provisioning."
      else
        if write_file_if_changed "$DATASOURCE_YAML" <<EOF
apiVersion: 1
datasources:
  - name: "${INFLUXDB_DS_NAME}"
    type: influxdb
    access: proxy
    url: "${INFLUXDB_URL}"
    isDefault: ${INFLUXDB_IS_DEFAULT}
    jsonData:
      version: Flux
      organization: "${INFLUXDB_ORGANIZATION}"
      defaultBucket: "${INFLUXDB_BUCKET}"
    secureJsonData:
      token: "${INFLUXDB_TOKEN}"
EOF
        then
          log "Wrote InfluxDB (Flux) datasource provisioning: ${DATASOURCE_YAML}"
          changed=1
        else
          log "Datasource provisioning already up-to-date: ${DATASOURCE_YAML}"
        fi
      fi
    else
      if [[ -z "$INFLUXDB_DATABASE" ]]; then
        warn "INFLUXDB_URL set but INFLUXDB_DATABASE is empty (InfluxQL). Skipping datasource provisioning."
      else
        if write_file_if_changed "$DATASOURCE_YAML" <<EOF
apiVersion: 1
datasources:
  - name: "${INFLUXDB_DS_NAME}"
    type: influxdb
    access: proxy
    url: "${INFLUXDB_URL}"
    database: "${INFLUXDB_DATABASE}"
    user: "${INFLUXDB_USER}"
    isDefault: ${INFLUXDB_IS_DEFAULT}
    jsonData:
      httpMode: POST
    secureJsonData:
      password: "${INFLUXDB_PASSWORD}"
EOF
        then
          log "Wrote InfluxDB (InfluxQL) datasource provisioning: ${DATASOURCE_YAML}"
          changed=1
        else
          log "Datasource provisioning already up-to-date: ${DATASOURCE_YAML}"
        fi
      fi
    fi
  fi

  if (( changed == 1 )); then
    restart_grafana_if_possible
  else
    log "No changes detected; nothing to restart."
  fi
}

api_import_dashboard() {
  need_cmd curl
  need_cmd python3

  local tmp_json rendered tmp_payload http_code
  rendered="$(mktemp)"
  tmp_payload="$(mktemp)"
  tmp_json="$(mktemp)"

  curl -fsSL "$DASHBOARD_SOURCE_URL" -o "$tmp_json"
  python3 - "$tmp_json" "$rendered" "$INFLUXDB_DS_NAME" <<'PY'
import json,sys
src, dst, ds = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src,'r',encoding='utf-8') as f:
    data = json.load(f)
def walk(x):
    if isinstance(x, dict):
        return {k: walk(v) for k,v in x.items()}
    if isinstance(x, list):
        return [walk(v) for v in x]
    if isinstance(x, str) and x == "${DS_INFLUXDB}":
        return ds
    return x
data = walk(data)
if isinstance(data, dict) and "id" in data:
    data["id"] = None
if isinstance(data, dict):
    data.pop("__inputs", None)
    data.pop("__requires", None)
with open(dst,'w',encoding='utf-8') as f:
    json.dump(data,f,ensure_ascii=False)
PY

  # Use the direct save endpoint; avoids import-time __inputs requirements.
  python3 - "$rendered" "$tmp_payload" <<'PY'
import json,sys
dash_path, out_path = sys.argv[1], sys.argv[2]
with open(dash_path,'r',encoding='utf-8') as f:
    dash = json.load(f)
payload = {
    "dashboard": dash,
    "overwrite": True,
    "folderId": 0,
    "message": "Installed via grafana_network_dashboard_installer.sh"
}
with open(out_path,'w',encoding='utf-8') as f:
    json.dump(payload,f)
PY

  if ! grafana_running_api_ok; then
    die "Grafana API not reachable at ${GRAFANA_URL}. Start Grafana or use MODE=provisioning."
  fi

  # shellcheck disable=SC2207
  local auth=()
  mapfile -t auth < <(curl_auth_args)
  http_code="$(
    curl -sS -o /tmp/grafana-import-response.json -w '%{http_code}' \
      "${auth[@]}" \
      -H 'Content-Type: application/json' \
      -X POST "${GRAFANA_URL%/}/api/dashboards/db" \
      --data-binary "@${tmp_payload}" || true
  )"

  rm -f "$tmp_json" "$rendered" "$tmp_payload"

  if [[ "$http_code" != "200" ]]; then
    warn "Grafana import response:"
    sed -n '1,200p' /tmp/grafana-import-response.json 2>/dev/null || true
    if [[ "$http_code" == "401" ]]; then
      warn "Auth failed. Many distro-packaged Grafana installs do NOT use admin/admin."
      warn "Use GRAFANA_API_TOKEN (preferred) or set correct GRAFANA_USER/GRAFANA_PASS."
    fi
    die "Dashboard import failed (HTTP ${http_code})."
  fi

  log "Dashboard imported successfully via API (HTTP ${http_code})."
}

api_upsert_influxdb_datasource() {
  # Optional: create/update datasource if details provided
  if [[ -z "$INFLUXDB_URL" ]]; then
    return 0
  fi
  if ! grafana_running_api_ok; then
    warn "Grafana API not reachable; skipping datasource API upsert."
    return 0
  fi

  need_cmd curl
  need_cmd python3

  # shellcheck disable=SC2207
  local auth=()
  mapfile -t auth < <(curl_auth_args)
  local tmp_payload http_code
  tmp_payload="$(mktemp)"

  export INFLUXDB_DS_NAME INFLUXDB_URL INFLUXDB_IS_DEFAULT INFLUXDB_VERSION
  export INFLUXDB_ORGANIZATION INFLUXDB_BUCKET INFLUXDB_TOKEN
  export INFLUXDB_DATABASE INFLUXDB_USER INFLUXDB_PASSWORD

  python3 - "$tmp_payload" <<'PY'
import json,os,sys

out=sys.argv[1]
def getenv(k, default=""):
  return os.environ.get(k, default)

name=getenv("INFLUXDB_DS_NAME","InfluxDB")
url=getenv("INFLUXDB_URL","")
is_default=getenv("INFLUXDB_IS_DEFAULT","0") == "1"
version=getenv("INFLUXDB_VERSION","influxql").lower()

if not url:
  raise SystemExit("INFLUXDB_URL is empty")

payload={
  "name": name,
  "type": "influxdb",
  "access": "proxy",
  "url": url,
  "isDefault": is_default,
}

token=getenv("INFLUXDB_TOKEN","")
if version == "flux" or bool(token):
  org=getenv("INFLUXDB_ORGANIZATION","")
  bucket=getenv("INFLUXDB_BUCKET","")
  if not (org and bucket and token):
    raise SystemExit("Missing INFLUXDB_ORGANIZATION/INFLUXDB_BUCKET/INFLUXDB_TOKEN for Flux mode")
  payload["jsonData"]={"version":"Flux","organization":org,"defaultBucket":bucket}
  payload["secureJsonData"]={"token":token}
else:
  db=getenv("INFLUXDB_DATABASE","")
  user=getenv("INFLUXDB_USER","")
  pw=getenv("INFLUXDB_PASSWORD","")
  if not db:
    raise SystemExit("Missing INFLUXDB_DATABASE for InfluxQL mode")
  payload["database"]=db
  payload["user"]=user
  payload["jsonData"]={"httpMode":"POST"}
  payload["secureJsonData"]={"password":pw}

with open(out,'w',encoding='utf-8') as f:
  json.dump(payload,f)
PY

  # Try create; if it fails due to name conflict, update by id.
  http_code="$(
    curl -sS -o /tmp/grafana-ds-create.json -w '%{http_code}' \
      "${auth[@]}" -H 'Content-Type: application/json' \
      -X POST "${GRAFANA_URL%/}/api/datasources" \
      --data-binary "@${tmp_payload}" || true
  )"

  if [[ "$http_code" == "409" ]]; then
    # Find existing datasource id by name
    local ds_id
    export INFLUXDB_DS_NAME
    ds_id="$(
      python3 - <<'PY'
import os,urllib.parse
print(urllib.parse.quote(os.environ.get("INFLUXDB_DS_NAME","InfluxDB"), safe=""))
PY
    )"
    ds_id="$(
      curl -sS "${auth[@]}" "${GRAFANA_URL%/}/api/datasources/name/${ds_id}" \
        | python3 - <<'PY'
import json,sys
try:
  d=json.load(sys.stdin)
  print(d.get("id","") or "")
except Exception:
  print("")
PY
    )"
    if [[ -z "${ds_id:-}" ]]; then
      warn "Datasource exists but could not resolve id; skipping update."
      rm -f "$tmp_payload"
      return 0
    fi
    http_code="$(
      curl -sS -o /tmp/grafana-ds-update.json -w '%{http_code}' \
        "${auth[@]}" -H 'Content-Type: application/json' \
        -X PUT "${GRAFANA_URL%/}/api/datasources/${ds_id}" \
        --data-binary "@${tmp_payload}" || true
    )"
    [[ "$http_code" == "200" ]] || warn "Datasource update returned HTTP ${http_code} (continuing)."
  elif [[ "$http_code" != "200" ]]; then
    warn "Datasource create returned HTTP ${http_code} (continuing)."
  fi

  rm -f "$tmp_payload"
  log "InfluxDB datasource ensured via API (name: ${INFLUXDB_DS_NAME})."
}

usage() {
  cat <<EOF
Usage: sudo -E bash $0

Environment variables (common):
  MODE=auto|provisioning|api
  INSTALL_GRAFANA=1|0

Grafana API (MODE=api or auto):
  GRAFANA_URL=http://localhost:3000
  GRAFANA_USER=admin
  GRAFANA_PASS=admin
  GRAFANA_API_TOKEN=...   (preferred over user/pass)

InfluxDB datasource (optional, to auto-provision/create datasource):
  INFLUXDB_DS_NAME="InfluxDB"
  INFLUXDB_URL="http://localhost:8086"
  INFLUXDB_VERSION=influxql|flux
  # InfluxQL:
  INFLUXDB_DATABASE="telegraf"
  INFLUXDB_USER="..."
  INFLUXDB_PASSWORD="..."
  # Flux:
  INFLUXDB_ORGANIZATION="..."
  INFLUXDB_BUCKET="..."
  INFLUXDB_TOKEN="..."

Dashboard source override:
  DASHBOARD_ID=13140
  DASHBOARD_REVISION=latest
  DASHBOARD_SOURCE_URL=...
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  as_root "$@"

  # Dependencies needed for all modes
  if ! command -v curl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    log "Installing base dependencies (curl, python3, ca-certificates)"
    pkg_install ca-certificates curl python3
  fi

  ensure_grafana_installed

  # Decide mode
  local selected="$MODE"
  if [[ "$selected" == "auto" ]]; then
    if grafana_running_api_ok; then
      selected="api"
    else
      selected="provisioning"
    fi
  fi

  case "$selected" in
    api)
      log "Selected mode: API import (${GRAFANA_URL})"
      api_upsert_influxdb_datasource || warn "Datasource API upsert skipped/failed."
      api_import_dashboard
      ;;
    provisioning)
      log "Selected mode: provisioning files (${GRAFANA_ETC_DIR})"
      install_provisioning_files
      ;;
    *)
      die "Unknown MODE: ${MODE} (expected auto|provisioning|api)"
      ;;
  esac

  log "Done."
  log "Dashboard source: https://grafana.com/grafana/dashboards/${DASHBOARD_ID}-network/"
}

main "$@"
