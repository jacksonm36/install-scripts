#!/usr/bin/env bash
set -Eeuo pipefail

# Matrix complete installer wrapper
# Runs one or both installers from a single .sh entrypoint:
#  - matrix-synapse-multi-os-install.sh
#  - element-web-deploy.sh

SCRIPT_VERSION="1.0.0"
DEFAULT_RAW_BASE="https://raw.githubusercontent.com/jacksonm36/install-scripts/cursor/synapse-multi-os-installation-d5e8"
RAW_BASE="${INSTALL_SCRIPTS_RAW_BASE:-$DEFAULT_RAW_BASE}"

SYNAPSE_SCRIPT_NAME="matrix-synapse-multi-os-install.sh"
ELEMENT_SCRIPT_NAME="element-web-deploy.sh"

WORK_DIR="${INSTALL_WRAPPER_WORKDIR:-/tmp/matrix-complete-install}"
MODE=""
FORCE_DOWNLOAD="false"
DEFAULT_MATRIX_DOMAIN="${MATRIX_DEFAULT_SERVER_DOMAIN:-matrix.gamedns.hu}"
DEFAULT_ELEMENT_DOMAIN="${ELEMENT_DEFAULT_PUBLIC_DOMAIN:-chat.gamedns.hu}"
DEFAULT_EXTERNAL_REVERSE_PROXY="${MATRIX_DEFAULT_EXTERNAL_REVERSE_PROXY:-true}"
MATRIX_DOMAIN=""
ELEMENT_DOMAIN=""
EXTERNAL_REVERSE_PROXY="true"

log() { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: sudo bash matrix-complete-install.sh [options]

Options:
  --mode <synapse|element|full>   Run a specific install mode.
  --raw-base <url>                Raw GitHub base URL for installer scripts.
  --force-download                Ignore local scripts and always download.
  -h, --help                      Show this help.

Environment variables:
  INSTALL_SCRIPTS_RAW_BASE        Same as --raw-base.
  INSTALL_WRAPPER_WORKDIR         Directory used for downloaded scripts.
  MATRIX_DEFAULT_SERVER_DOMAIN    Default Matrix server_name shown in prompts.
  ELEMENT_DEFAULT_PUBLIC_DOMAIN   Default Element domain shown in prompts.
  MATRIX_DEFAULT_EXTERNAL_REVERSE_PROXY  Default reverse-proxy mode (true/false).

Examples:
  sudo bash matrix-complete-install.sh
  sudo bash matrix-complete-install.sh --mode full
  sudo INSTALL_SCRIPTS_RAW_BASE="https://raw.githubusercontent.com/ORG/REPO/BRANCH" \\
       bash matrix-complete-install.sh --mode synapse
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        [[ $# -ge 2 ]] || die "--mode requires a value."
        MODE="${2,,}"
        shift 2
        ;;
      --raw-base)
        [[ $# -ge 2 ]] || die "--raw-base requires a value."
        RAW_BASE="$2"
        shift 2
        ;;
      --force-download)
        FORCE_DOWNLOAD="true"
        shift
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

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root."
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

choose_mode_interactive() {
  printf "\nMatrix Complete Installer v%s\n" "$SCRIPT_VERSION"
  printf "This wrapper runs Synapse and Element installers from one file.\n\n"
  printf "Choose what to install:\n"
  printf "  1) Synapse only\n"
  printf "  2) Element Web only\n"
  printf "  3) Full stack (Synapse + Element Web; Synapse Nginx/firewall auto-disabled)\n"

  local choice
  while true; do
    read -r -p "Select [1-3] [3]: " choice || true
    choice="${choice:-3}"
    case "$choice" in
      1) MODE="synapse"; return 0 ;;
      2) MODE="element"; return 0 ;;
      3) MODE="full"; return 0 ;;
      *) warn "Please select 1, 2, or 3." ;;
    esac
  done
}

validate_mode() {
  case "$MODE" in
    synapse|element|full) ;;
    "")
      choose_mode_interactive
      ;;
    *)
      die "Invalid mode '${MODE}'. Use synapse, element, or full."
      ;;
  esac
}

collect_domain_defaults() {
  local reverse_proxy_default="y"
  case "${DEFAULT_EXTERNAL_REVERSE_PROXY,,}" in
    0|false|no|n) reverse_proxy_default="n" ;;
  esac

  if ask_yes_no "Use external reverse proxy in front of this server?" "$reverse_proxy_default"; then
    EXTERNAL_REVERSE_PROXY="true"
  else
    EXTERNAL_REVERSE_PROXY="false"
  fi

  printf "\nDomain defaults (editable, press Enter to keep):\n"
  case "$MODE" in
    synapse)
      MATRIX_DOMAIN="$(ask_required_text "Matrix server_name for Synapse" "$DEFAULT_MATRIX_DOMAIN")"
      ELEMENT_DOMAIN="$DEFAULT_ELEMENT_DOMAIN"
      ;;
    element)
      ELEMENT_DOMAIN="$(ask_required_text "Element public domain" "$DEFAULT_ELEMENT_DOMAIN")"
      MATRIX_DOMAIN="$(ask_required_text "Matrix server_name for Element" "$DEFAULT_MATRIX_DOMAIN")"
      ;;
    full)
      MATRIX_DOMAIN="$(ask_required_text "Matrix server_name" "$DEFAULT_MATRIX_DOMAIN")"
      ELEMENT_DOMAIN="$(ask_required_text "Element public domain" "$DEFAULT_ELEMENT_DOMAIN")"
      ;;
  esac
}

prepare_workdir() {
  mkdir -p "$WORK_DIR"
  chmod 700 "$WORK_DIR"
}

candidate_script_paths() {
  local name="$1"
  # Ordered by preference:
  # 1) sibling to this wrapper
  # 2) current directory
  # 3) /workspace repository root (cloud default)
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s\n' \
    "${self_dir}/${name}" \
    "$(pwd)/${name}" \
    "/workspace/${name}"
}

download_script() {
  local name="$1"
  local dest="${WORK_DIR}/${name}"
  local url="${RAW_BASE%/}/${name}"

  log "Downloading ${name} from ${url}" >&2
  curl -fsSL "$url" -o "$dest" || die "Failed to download ${name} from ${url}"
  chmod +x "$dest"
  printf '%s\n' "$dest"
}

resolve_script() {
  local name="$1"
  if [[ "$FORCE_DOWNLOAD" == "true" ]]; then
    download_script "$name"
    return 0
  fi

  local path
  while IFS= read -r path; do
    if [[ -f "$path" ]]; then
      chmod +x "$path" || true
      printf '%s\n' "$path"
      return 0
    fi
  done < <(candidate_script_paths "$name")

  download_script "$name"
}

run_component() {
  local label="$1"
  local script_path="$2"
  log "Starting ${label} installer: ${script_path}"
  bash "$script_path"
  log "${label} installer completed."
}

run_synapse() {
  local synapse_script
  local synapse_force_public_baseurl=""
  synapse_script="$(resolve_script "$SYNAPSE_SCRIPT_NAME")"
  log "Starting Synapse installer: ${synapse_script}"

  if [[ "$EXTERNAL_REVERSE_PROXY" == "true" ]]; then
    synapse_force_public_baseurl="https://${MATRIX_DOMAIN}/"
  fi

  if [[ "$MODE" == "full" ]]; then
    log "Full mode: running Synapse without Nginx/firewall (Element will provide web/proxy layer)."
    SYNAPSE_DEFAULT_SERVER_NAME="$MATRIX_DOMAIN" \
    SYNAPSE_DEFAULT_PUBLIC_FQDN="$MATRIX_DOMAIN" \
    SYNAPSE_FORCE_EXTERNAL_REVERSE_PROXY="$EXTERNAL_REVERSE_PROXY" \
    SYNAPSE_FORCE_PUBLIC_BASEURL="$synapse_force_public_baseurl" \
    SYNAPSE_FORCE_INSTALL_NGINX=false \
    SYNAPSE_FORCE_CONFIGURE_FIREWALL=false \
      bash "$synapse_script"
  elif [[ "$EXTERNAL_REVERSE_PROXY" == "true" ]]; then
    SYNAPSE_DEFAULT_SERVER_NAME="$MATRIX_DOMAIN" \
    SYNAPSE_DEFAULT_PUBLIC_FQDN="$MATRIX_DOMAIN" \
    SYNAPSE_FORCE_EXTERNAL_REVERSE_PROXY=true \
    SYNAPSE_FORCE_PUBLIC_BASEURL="$synapse_force_public_baseurl" \
    SYNAPSE_FORCE_INSTALL_NGINX=false \
      bash "$synapse_script"
  else
    SYNAPSE_DEFAULT_SERVER_NAME="$MATRIX_DOMAIN" \
    SYNAPSE_DEFAULT_PUBLIC_FQDN="$MATRIX_DOMAIN" \
    SYNAPSE_FORCE_EXTERNAL_REVERSE_PROXY=false \
      bash "$synapse_script"
  fi
  log "Synapse installer completed."
}

run_element() {
  local element_script
  element_script="$(resolve_script "$ELEMENT_SCRIPT_NAME")"
  log "Starting Element Web installer: ${element_script}"
  ELEMENT_DEFAULT_PUBLIC_FQDN="$ELEMENT_DOMAIN" \
  ELEMENT_DEFAULT_MATRIX_SERVER_NAME="$MATRIX_DOMAIN" \
  ELEMENT_DEFAULT_HOMESERVER_URL="https://${MATRIX_DOMAIN}" \
  ELEMENT_FORCE_EXTERNAL_REVERSE_PROXY="$EXTERNAL_REVERSE_PROXY" \
    bash "$element_script"
  log "Element Web installer completed."
}

main() {
  parse_args "$@"
  require_root
  command_exists curl || die "curl is required."
  command_exists bash || die "bash is required."

  validate_mode
  collect_domain_defaults
  prepare_workdir

  case "$MODE" in
    synapse)
      run_synapse
      ;;
    element)
      run_element
      ;;
    full)
      run_synapse
      run_element
      ;;
  esac

  printf '\n'
  log "Requested mode '${MODE}' finished."
  log "Wrapper done. Re-run this file anytime for another component."
}

main "$@"
