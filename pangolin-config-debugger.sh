#!/usr/bin/env bash

set -euo pipefail

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
err() { printf '[ERR ] %s\n' "$*"; }

usage() {
  cat <<'EOF'
Read-only validator for Docker Compose stack + Traefik config.

This script ONLY validates:
  1) Docker Compose stack files
  2) Traefik static + dynamic config files

It does not modify anything.

Usage:
  ./pangolin-config-debugger.sh [options]

Options:
  --base PATH          Base path (default: /root)
  --compose PATH       Compose file (default: <base>/docker-compose.yml)
  --compose-backup PATH Optional extra compose file
                       (default: <base>/docker-compose.yml.backup if it exists)
  --traefik-dir PATH   Traefik config dir (default: <base>/config/traefik)
  -h, --help           Show help

Exit code:
  0 = no critical findings
  1 = one or more critical findings
EOF
}

BASE_DIR="/root"
COMPOSE_FILE=""
COMPOSE_BACKUP=""
TRAEFIK_DIR=""

while (($# > 0)); do
  case "$1" in
    --base)
      BASE_DIR="${2:-}"
      shift 2
      ;;
    --compose)
      COMPOSE_FILE="${2:-}"
      shift 2
      ;;
    --compose-backup)
      COMPOSE_BACKUP="${2:-}"
      shift 2
      ;;
    --traefik-dir)
      TRAEFIK_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$COMPOSE_FILE" ]]; then
  COMPOSE_FILE="$BASE_DIR/docker-compose.yml"
fi
if [[ -z "$COMPOSE_BACKUP" && -f "$BASE_DIR/docker-compose.yml.backup" ]]; then
  COMPOSE_BACKUP="$BASE_DIR/docker-compose.yml.backup"
fi
if [[ -z "$TRAEFIK_DIR" ]]; then
  TRAEFIK_DIR="$BASE_DIR/config/traefik"
fi

STATIC_CFG="$TRAEFIK_DIR/traefik_config.yml"
DYNAMIC_CFG="$TRAEFIK_DIR/dynamic_config.yml"

critical_count=0
warning_count=0

add_critical() {
  critical_count=$((critical_count + 1))
  err "$*"
}

add_warning() {
  warning_count=$((warning_count + 1))
  warn "$*"
}

validate_compose() {
  local compose_file="$1"
  local label="$2"

  if [[ -z "$compose_file" ]]; then
    return
  fi
  if [[ ! -f "$compose_file" ]]; then
    add_critical "${label} missing: $compose_file"
    return
  fi

  info "Validating ${label}: $compose_file"

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    if docker compose -f "$compose_file" config -q >/dev/null 2>&1; then
      ok "${label} is valid"
    else
      add_critical "${label} failed docker compose validation"
    fi
    return
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    if docker-compose -f "$compose_file" config -q >/dev/null 2>&1; then
      ok "${label} is valid"
    else
      add_critical "${label} failed docker-compose validation"
    fi
    return
  fi

  add_critical "Neither 'docker compose' nor 'docker-compose' is available"
}

validate_yaml_file() {
  local file_path="$1"
  local label="$2"

  if [[ ! -f "$file_path" ]]; then
    add_critical "${label} missing: $file_path"
    return 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    add_critical "python3 is required to validate ${label}"
    return 1
  fi

  local yaml_out
  yaml_out="$(python3 - "$file_path" <<'PY'
import json
import sys
path = sys.argv[1]
try:
    import yaml  # type: ignore
except Exception:
    print(json.dumps({"status": "no_pyyaml"}))
    raise SystemExit(0)

try:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
except Exception as ex:
    print(json.dumps({"status": "parse_error", "error": str(ex)}))
    raise SystemExit(0)

kind = type(data).__name__
print(json.dumps({"status": "ok", "kind": kind}))
PY
)"

  local yaml_status
  yaml_status="$(python3 - "$yaml_out" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("status", "unknown"))
PY
)"

  case "$yaml_status" in
    ok)
      ok "${label} YAML syntax is valid"
      return 0
      ;;
    no_pyyaml)
      add_critical "PyYAML is not installed; cannot validate ${label}"
      return 1
      ;;
    parse_error)
      local parse_error
      parse_error="$(python3 - "$yaml_out" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("error", "unknown parse error"))
PY
)"
      add_critical "${label} YAML parse error: ${parse_error}"
      return 1
      ;;
    *)
      add_critical "${label} unknown YAML validation result: ${yaml_status}"
      return 1
      ;;
  esac
}

validate_traefik_semantics() {
  if [[ ! -f "$DYNAMIC_CFG" ]]; then
    return
  fi

  info "Validating Traefik dynamic config semantics: $DYNAMIC_CFG"

  local check_out
  check_out="$(python3 - "$DYNAMIC_CFG" <<'PY'
import json
import re
import sys

path = sys.argv[1]
try:
    import yaml  # type: ignore
except Exception:
    print(json.dumps({"status": "no_pyyaml"}))
    raise SystemExit(0)

with open(path, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}

if not isinstance(data, dict):
    print(json.dumps({"status": "not_mapping"}))
    raise SystemExit(0)

http = data.get("http")
if not isinstance(http, dict):
    print(json.dumps({"status": "missing_http"}))
    raise SystemExit(0)

routers = http.get("routers")
services = http.get("services")
if not isinstance(routers, dict):
    routers = {}
if not isinstance(services, dict):
    services = {}

missing_services = []
missing_tls_domains = []
host_re = re.compile(r"HostRegexp\(`\{[^}]+\}\.([a-zA-Z0-9.-]+)`\)")

for rname, rdef in routers.items():
    if not isinstance(rdef, dict):
        continue

    svc = rdef.get("service")
    if isinstance(svc, str) and svc and "@" not in svc and svc not in services:
        missing_services.append({"router": rname, "service": svc})

    rule = rdef.get("rule")
    tls = rdef.get("tls")
    if isinstance(rule, str) and "HostRegexp(" in rule:
        has_domains = False
        if isinstance(tls, dict):
            domains = tls.get("domains")
            has_domains = isinstance(domains, list) and len(domains) > 0
        if not has_domains:
            m = host_re.search(rule)
            missing_tls_domains.append(
                {"router": rname, "domain": m.group(1) if m else ""}
            )

print(
    json.dumps(
        {
            "status": "ok",
            "routers": len(routers),
            "services": len(services),
            "missing_services": missing_services,
            "missing_tls_domains": missing_tls_domains,
        }
    )
)
PY
)"

  local status
  status="$(python3 - "$check_out" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("status", "unknown"))
PY
)"

  case "$status" in
    no_pyyaml)
      add_critical "PyYAML is not installed; cannot run Traefik semantic checks"
      ;;
    not_mapping)
      add_critical "Traefik dynamic config top-level YAML must be a mapping"
      ;;
    missing_http)
      add_warning "Traefik dynamic config has no top-level 'http' section"
      ;;
    ok)
      local routers_count services_count missing_svc_count missing_tls_count
      routers_count="$(python3 - "$check_out" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("routers", 0))
PY
)"
      services_count="$(python3 - "$check_out" <<'PY'
import json
import sys
print(json.loads(sys.argv[1]).get("services", 0))
PY
)"
      ok "Traefik dynamic config loaded: ${routers_count} routers, ${services_count} services"

      missing_svc_count="$(python3 - "$check_out" <<'PY'
import json
import sys
print(len(json.loads(sys.argv[1]).get("missing_services", [])))
PY
)"
      if [[ "$missing_svc_count" -gt 0 ]]; then
        add_critical "Found ${missing_svc_count} router(s) referencing missing service(s)"
        python3 - "$check_out" <<'PY'
import json
import sys
for item in json.loads(sys.argv[1]).get("missing_services", []):
    print(f"[ERR ] router '{item.get('router')}' -> missing service '{item.get('service')}'")
PY
      fi

      missing_tls_count="$(python3 - "$check_out" <<'PY'
import json
import sys
print(len(json.loads(sys.argv[1]).get("missing_tls_domains", [])))
PY
)"
      if [[ "$missing_tls_count" -gt 0 ]]; then
        add_warning "Found ${missing_tls_count} HostRegexp router(s) without tls.domains"
        python3 - "$check_out" <<'PY'
import json
import sys
for item in json.loads(sys.argv[1]).get("missing_tls_domains", []):
    print(f"[WARN] router '{item.get('router')}' missing tls.domains (domain: {item.get('domain') or 'unknown'})")
PY
      fi
      ;;
    *)
      add_critical "Unknown Traefik semantic validation status: ${status}"
      ;;
  esac
}

info "Starting validation (compose + Traefik only)"
validate_compose "$COMPOSE_FILE" "Compose file"
validate_compose "$COMPOSE_BACKUP" "Compose backup file"

validate_yaml_file "$STATIC_CFG" "Traefik static config"
validate_yaml_file "$DYNAMIC_CFG" "Traefik dynamic config"
validate_traefik_semantics

printf '\n'
info "Summary: ${critical_count} critical, ${warning_count} warning(s)"
if [[ "$critical_count" -gt 0 ]]; then
  err "Validation failed."
  exit 1
fi
ok "Validation passed."
exit 0
