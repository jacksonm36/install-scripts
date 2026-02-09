#!/usr/bin/env bash

set -euo pipefail

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[ OK ] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
err() { printf '[ERR ] %s\n' "$*"; }

usage() {
  cat <<'EOF'
Read-only debugger for Pangolin/Traefik config layout.

This script ONLY checks files and reports findings.
It does not modify any file.

Usage:
  ./pangolin-config-debugger.sh [--base /root]

Options:
  --base PATH   Base directory containing:
                config.tar.gz, docker-compose.yml, docker-compose.yml.backup,
                GeoLite2-Country_20260116, installer, config/
                (default: /root)
  -h, --help    Show help

Exit code:
  0 = no critical findings
  1 = one or more critical findings
EOF
}

BASE_DIR="/root"
while (($# > 0)); do
  case "$1" in
    --base)
      BASE_DIR="${2:-}"
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

if [[ ! -d "$BASE_DIR" ]]; then
  err "Base directory does not exist: $BASE_DIR"
  exit 1
fi

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

check_path() {
  local path="$1"
  local expected="$2"
  local label="$3"

  if [[ ! -e "$path" ]]; then
    add_critical "Missing ${label}: $path"
    return
  fi

  case "$expected" in
    file)
      if [[ -f "$path" ]]; then
        ok "${label} exists (file): $path"
      else
        add_critical "${label} is not a file: $path"
      fi
      ;;
    dir)
      if [[ -d "$path" ]]; then
        ok "${label} exists (dir): $path"
      else
        add_critical "${label} is not a directory: $path"
      fi
      ;;
    file_or_dir)
      if [[ -f "$path" || -d "$path" ]]; then
        ok "${label} exists: $path"
      else
        add_critical "${label} exists but has unexpected type: $path"
      fi
      ;;
    *)
      add_warning "Internal check error: unsupported expected type '$expected' for $path"
      ;;
  esac
}

info "Checking root-level files under: $BASE_DIR"
check_path "$BASE_DIR/config.tar.gz" "file" "Archive"
check_path "$BASE_DIR/docker-compose.yml" "file" "Docker Compose file"
check_path "$BASE_DIR/docker-compose.yml.backup" "file" "Docker Compose backup"
check_path "$BASE_DIR/GeoLite2-Country_20260116" "dir" "GeoLite extraction directory"
check_path "$BASE_DIR/installer" "file_or_dir" "Installer"
check_path "$BASE_DIR/config" "dir" "Config directory"

CONFIG_DIR="$BASE_DIR/config"
TRAEFIK_DIR="$CONFIG_DIR/traefik"

if [[ -d "$CONFIG_DIR" ]]; then
  info "Checking expected entries in $CONFIG_DIR"
  check_path "$CONFIG_DIR/config.yml" "file" "Main config.yml"
  check_path "$CONFIG_DIR/crowdsec" "dir" "crowdsec directory"
  check_path "$CONFIG_DIR/crowdsec_logs" "dir" "crowdsec_logs directory"
  check_path "$CONFIG_DIR/db" "dir" "db directory"
  check_path "$CONFIG_DIR/GeoLite2-Country.mmdb" "file" "GeoLite2 mmdb"
  check_path "$CONFIG_DIR/grafana" "dir" "grafana directory"
  check_path "$CONFIG_DIR/letsencrypt" "dir" "letsencrypt directory"
  check_path "$CONFIG_DIR/logs" "dir" "logs directory"
  check_path "$CONFIG_DIR/prometheus" "dir" "prometheus directory"
  check_path "$CONFIG_DIR/traefik" "dir" "traefik directory"
fi

if [[ -d "$TRAEFIK_DIR" ]]; then
  info "Checking Traefik directory structure"
  check_path "$TRAEFIK_DIR/dynamic_config.yml" "file" "Traefik dynamic config"
  check_path "$TRAEFIK_DIR/traefik_config.yml" "file" "Traefik static config"
  check_path "$TRAEFIK_DIR/logs" "dir" "Traefik logs directory"
fi

if [[ -f "$BASE_DIR/config.tar.gz" ]]; then
  if tar -tzf "$BASE_DIR/config.tar.gz" >/dev/null 2>&1; then
    ok "config.tar.gz is readable and not corrupted"
  else
    add_critical "config.tar.gz is not readable as a gzip tar archive"
  fi
fi

if [[ -f "$CONFIG_DIR/GeoLite2-Country.mmdb" ]]; then
  mmdb_size="$(wc -c <"$CONFIG_DIR/GeoLite2-Country.mmdb" | tr -d ' ')"
  if [[ "$mmdb_size" -gt 0 ]]; then
    ok "GeoLite2-Country.mmdb is present and non-empty (${mmdb_size} bytes)"
  else
    add_critical "GeoLite2-Country.mmdb exists but is empty"
  fi
fi

validate_compose() {
  local compose_file="$1"
  if [[ ! -f "$compose_file" ]]; then
    return
  fi

  info "Validating docker-compose syntax: $compose_file"

  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      if docker compose -f "$compose_file" config -q >/dev/null 2>&1; then
        ok "docker compose validation passed: $compose_file"
      else
        add_critical "docker compose validation failed: $compose_file"
      fi
      return
    fi
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    if docker-compose -f "$compose_file" config -q >/dev/null 2>&1; then
      ok "docker-compose validation passed: $compose_file"
    else
      add_critical "docker-compose validation failed: $compose_file"
    fi
    return
  fi

  add_warning "Docker compose CLI not available; skipped compose validation for: $compose_file"
}

validate_compose "$BASE_DIR/docker-compose.yml"
validate_compose "$BASE_DIR/docker-compose.yml.backup"

if [[ -f "$TRAEFIK_DIR/dynamic_config.yml" ]]; then
  info "Running Traefik dynamic config semantic checks (read-only)"
  if command -v python3 >/dev/null 2>&1; then
    py_out="$(python3 - "$TRAEFIK_DIR/dynamic_config.yml" <<'PY'
import json
import re
import sys

path = sys.argv[1]
try:
    import yaml  # type: ignore
except Exception:
    print(json.dumps({"status": "no_pyyaml"}))
    raise SystemExit(0)

try:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
except Exception as ex:
    print(json.dumps({"status": "yaml_parse_error", "error": str(ex)}))
    raise SystemExit(0)

if not isinstance(data, dict):
    print(json.dumps({"status": "yaml_not_object"}))
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
hostregexp_missing_tls_domains = []
host_re = re.compile(r"HostRegexp\(`\{[^}]+\}\.([a-zA-Z0-9.-]+)`\)")

for rname, rdef in routers.items():
    if not isinstance(rdef, dict):
        continue
    svc = rdef.get("service")
    if (
        isinstance(svc, str)
        and svc
        and "@" not in svc
        and svc not in services
    ):
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
            hostregexp_missing_tls_domains.append(
                {"router": rname, "domain": m.group(1) if m else "", "rule": rule}
            )

print(
    json.dumps(
        {
            "status": "ok",
            "routers": len(routers),
            "services": len(services),
            "missing_services": missing_services,
            "hostregexp_missing_tls_domains": hostregexp_missing_tls_domains,
        }
    )
)
PY
)"

    py_status="$(python3 - "$py_out" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
print(data.get("status", "unknown"))
PY
)"

    case "$py_status" in
      no_pyyaml)
        add_warning "python3-yaml (PyYAML) not available; skipped deep YAML semantic checks"
        ;;
      yaml_parse_error)
        parse_err="$(python3 - "$py_out" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
print(data.get("error", "unknown parse error"))
PY
)"
        add_critical "dynamic_config.yml YAML parse error: $parse_err"
        ;;
      yaml_not_object)
        add_critical "dynamic_config.yml parsed but top-level object is not a mapping"
        ;;
      missing_http)
        add_warning "dynamic_config.yml has no top-level 'http' section"
        ;;
      ok)
        routers_count="$(python3 - "$py_out" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
print(data.get("routers", 0))
PY
)"
        services_count="$(python3 - "$py_out" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
print(data.get("services", 0))
PY
)"
        ok "dynamic_config.yml parsed: ${routers_count} routers, ${services_count} services"

        missing_count="$(python3 - "$py_out" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
print(len(data.get("missing_services", [])))
PY
)"
        if [[ "$missing_count" -gt 0 ]]; then
          add_critical "Found ${missing_count} router(s) referencing missing service(s)"
          python3 - "$py_out" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
for item in data.get("missing_services", []):
    print(f"[ERR ] router '{item.get('router')}' -> missing service '{item.get('service')}'")
PY
        fi

        hostregexp_count="$(python3 - "$py_out" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
print(len(data.get("hostregexp_missing_tls_domains", [])))
PY
)"
        if [[ "$hostregexp_count" -gt 0 ]]; then
          add_warning "Found ${hostregexp_count} HostRegexp router(s) without tls.domains"
          python3 - "$py_out" <<'PY'
import json
import sys
data = json.loads(sys.argv[1])
for item in data.get("hostregexp_missing_tls_domains", []):
    router = item.get("router")
    domain = item.get("domain") or "unknown"
    print(f"[WARN] router '{router}' missing tls.domains (derived domain: {domain})")
PY
        fi
        ;;
      *)
        add_warning "Unknown semantic check result: $py_status"
        ;;
    esac
  else
    add_warning "python3 not found; skipped Traefik semantic checks"
  fi
fi

if [[ -d "$TRAEFIK_DIR/logs" ]]; then
  info "Scanning Traefik logs for known warning/error patterns"
  # Shell glob patterns are intentional and read-only.
  shopt -s nullglob
  log_files=("$TRAEFIK_DIR"/logs/*.log "$TRAEFIK_DIR"/logs/*.txt)
  shopt -u nullglob
  if [[ "${#log_files[@]}" -eq 0 ]]; then
    add_warning "No .log/.txt files found in $TRAEFIK_DIR/logs"
  else
    if command -v rg >/dev/null 2>&1; then
      warn_count="$(rg -i --no-heading --line-number "No domain found in rule HostRegexp" "${log_files[@]}" 2>/dev/null | wc -l | tr -d ' ')"
      miss_count="$(rg -i --no-heading --line-number "service .* does not exist" "${log_files[@]}" 2>/dev/null | wc -l | tr -d ' ')"
      fetch_count="$(rg -i --no-heading --line-number "cannot fetch configuration data|context deadline exceeded" "${log_files[@]}" 2>/dev/null | wc -l | tr -d ' ')"
      tls_count="$(rg -i --no-heading --line-number "first record does not look like a TLS handshake" "${log_files[@]}" 2>/dev/null | wc -l | tr -d ' ')"
    else
      warn_count="$(grep -Eic "No domain found in rule HostRegexp" "${log_files[@]}" 2>/dev/null || true)"
      miss_count="$(grep -Eic "service .* does not exist" "${log_files[@]}" 2>/dev/null || true)"
      fetch_count="$(grep -Eic "cannot fetch configuration data|context deadline exceeded" "${log_files[@]}" 2>/dev/null || true)"
      tls_count="$(grep -Eic "first record does not look like a TLS handshake" "${log_files[@]}" 2>/dev/null || true)"
    fi

    if [[ "$warn_count" -gt 0 ]]; then
      add_warning "HostRegexp/TLS-domain warning occurrences in logs: $warn_count"
    fi
    if [[ "$miss_count" -gt 0 ]]; then
      add_critical "Missing service error occurrences in logs: $miss_count"
    fi
    if [[ "$fetch_count" -gt 0 ]]; then
      add_critical "Config fetch timeout/error occurrences in logs: $fetch_count"
    fi
    if [[ "$tls_count" -gt 0 ]]; then
      add_warning "TLS handshake mismatch occurrences in logs: $tls_count"
    fi
  fi
fi

printf '\n'
info "Summary: ${critical_count} critical, ${warning_count} warning(s)"
if [[ "$critical_count" -gt 0 ]]; then
  err "Config debugger found critical issues."
  exit 1
fi
ok "No critical issues found."
exit 0
