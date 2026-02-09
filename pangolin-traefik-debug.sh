#!/usr/bin/env bash

set -euo pipefail

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
err() { printf '[ERR ] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Validate Pangolin -> Traefik dynamic configuration fetch health.

Usage:
  ./pangolin-traefik-debug.sh [options]

Options:
  --url URL            Pangolin base URL (default: $PANGOLIN_URL or http://pangolin:3001)
  --endpoint PATH      Config endpoint path (default: $ENDPOINT or /api/v1/traefik-config)
  --timeout SECONDS    Curl max time per request (default: $TIMEOUT_SECONDS or 20)
  --body-out PATH      Save fetched body to PATH
  -h, --help           Show this help

Environment:
  PANGOLIN_URL, ENDPOINT, TIMEOUT_SECONDS, BODY_OUT

Exit codes:
  0 => fetch succeeded and no critical validation issue
  1 => fetch failed or critical validation issue found
EOF
}

PANGOLIN_URL="${PANGOLIN_URL:-http://pangolin:3001}"
ENDPOINT="${ENDPOINT:-/api/v1/traefik-config}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-20}"
BODY_OUT="${BODY_OUT:-}"

while (($# > 0)); do
  case "$1" in
    --url)
      PANGOLIN_URL="${2:-}"
      shift 2
      ;;
    --endpoint)
      ENDPOINT="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --body-out)
      BODY_OUT="${2:-}"
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

if ! command -v curl >/dev/null 2>&1; then
  err "curl is required"
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  err "python3 is required"
  exit 1
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  err "--timeout must be an integer"
  exit 1
fi

BASE_URL="${PANGOLIN_URL%/}"
PATH_URL="${ENDPOINT#/}"
CONFIG_URL="${BASE_URL}/${PATH_URL}"

tmp_body="$(mktemp)"
tmp_analysis="$(mktemp)"
cleanup() {
  rm -f "$tmp_body" "$tmp_analysis"
}
trap cleanup EXIT

info "Fetching ${CONFIG_URL}"

curl_exit=0
http_code=""
if ! http_code="$(
  curl \
    --silent \
    --show-error \
    --connect-timeout 5 \
    --max-time "${TIMEOUT_SECONDS}" \
    --output "$tmp_body" \
    --write-out '%{http_code}' \
    "$CONFIG_URL"
)"; then
  curl_exit=$?
fi

if ((curl_exit != 0)); then
  err "Could not fetch config (curl exit ${curl_exit})."
  err "This matches your 'context deadline exceeded while awaiting headers' symptom."
  err "Check that Pangolin is healthy and reachable from the Traefik container/network."
  exit 1
fi

bytes="$(wc -c <"$tmp_body" | tr -d ' ')"
if [[ "$http_code" != "200" ]]; then
  err "Endpoint returned HTTP ${http_code} (${bytes} bytes)."
  err "Expected HTTP 200 from ${CONFIG_URL}"
  exit 1
fi

if [[ "$bytes" -eq 0 ]]; then
  err "Endpoint returned HTTP 200 but body is empty."
  err "Traefik cannot build routers/services from an empty config."
  exit 1
fi

info "Fetch OK (HTTP ${http_code}, ${bytes} bytes)."

python3 - "$tmp_body" >"$tmp_analysis" <<'PY'
import json
import re
import sys

path = sys.argv[1]
raw = open(path, "r", encoding="utf-8", errors="replace").read()
text = raw.strip()

def out(line: str) -> None:
    print(line)

if not text:
    out("FORMAT=empty")
    raise SystemExit(0)

try:
    data = json.loads(text)
except Exception:
    out("FORMAT=non_json")
    raise SystemExit(0)

if not isinstance(data, dict):
    out("FORMAT=json_non_object")
    raise SystemExit(0)

http = data.get("http")
if not isinstance(http, dict):
    out("FORMAT=json_no_http")
    raise SystemExit(0)

routers = http.get("routers")
services = http.get("services")
if not isinstance(routers, dict):
    routers = {}
if not isinstance(services, dict):
    services = {}

out("FORMAT=json")
out(f"ROUTERS={len(routers)}")
out(f"SERVICES={len(services)}")

host_re = re.compile(r"HostRegexp\(`\{[^}]+\}\.([a-zA-Z0-9.-]+)`\)")
missing_services = []
hostregexp_missing_tls_domain = []

for router_name, router_def in routers.items():
    if not isinstance(router_def, dict):
        continue

    service_name = router_def.get("service")
    if (
        isinstance(service_name, str)
        and service_name
        and "@" not in service_name
        and service_name not in services
    ):
        missing_services.append((router_name, service_name))

    rule = router_def.get("rule")
    tls = router_def.get("tls")
    if isinstance(rule, str) and "HostRegexp(" in rule:
        has_domains = False
        if isinstance(tls, dict):
            domains = tls.get("domains")
            has_domains = isinstance(domains, list) and len(domains) > 0
        if not has_domains:
            match = host_re.search(rule)
            domain = match.group(1) if match else ""
            hostregexp_missing_tls_domain.append((router_name, domain, rule))

out(f"MISSING_SERVICES={len(missing_services)}")
for router_name, service_name in missing_services:
    out(f"MISSING::{router_name}::{service_name}")

out(f"HOSTREGEXP_WITHOUT_TLS_DOMAIN={len(hostregexp_missing_tls_domain)}")
for router_name, domain, rule in hostregexp_missing_tls_domain:
    out(f"HOSTREGEXP::{router_name}::{domain}::{rule}")
PY

analysis_format="$(awk -F= '/^FORMAT=/{print $2; exit}' "$tmp_analysis")"

if [[ "$analysis_format" != "json" ]]; then
  warn "Response format is '${analysis_format}'."
  warn "Static deep validation skipped (tool validates JSON payloads only)."
  warn "If this endpoint serves YAML/TOML, check it manually for missing router services."
  if [[ -n "$BODY_OUT" ]]; then
    cp "$tmp_body" "$BODY_OUT"
    info "Saved raw config body to ${BODY_OUT}"
  fi
  exit 0
fi

router_count="$(awk -F= '/^ROUTERS=/{print $2; exit}' "$tmp_analysis")"
service_count="$(awk -F= '/^SERVICES=/{print $2; exit}' "$tmp_analysis")"
missing_count="$(awk -F= '/^MISSING_SERVICES=/{print $2; exit}' "$tmp_analysis")"
hostregexp_count="$(awk -F= '/^HOSTREGEXP_WITHOUT_TLS_DOMAIN=/{print $2; exit}' "$tmp_analysis")"

info "Parsed config summary: ${router_count} routers, ${service_count} services."

has_critical=0
if [[ "$missing_count" != "0" ]]; then
  has_critical=1
  err "${missing_count} router(s) reference missing service(s):"
  while IFS= read -r line; do
    router_name="$(printf '%s' "$line" | awk -F:: '{print $2}')"
    service_name="$(printf '%s' "$line" | awk -F:: '{print $3}')"
    err "  - router '${router_name}' -> service '${service_name}'"
  done < <(awk '/^MISSING::/' "$tmp_analysis")
  err "For redirect-only routers, set: service: noop@internal"
  err "Otherwise ensure the missing service is generated in the same dynamic config."
fi

if [[ "$hostregexp_count" != "0" ]]; then
  warn "${hostregexp_count} HostRegexp router(s) are missing tls.domains (warning from your logs)."
  while IFS= read -r line; do
    router_name="$(printf '%s' "$line" | awk -F:: '{print $2}')"
    domain_name="$(printf '%s' "$line" | awk -F:: '{print $3}')"
    warn "  - ${router_name} (domain: ${domain_name:-unknown})"
    if [[ -n "$domain_name" ]]; then
      warn "    suggested tls block:"
      warn "      tls:"
      warn "        domains:"
      warn "          - main: ${domain_name}"
      warn "            sans:"
      warn "              - *.${domain_name}"
    fi
  done < <(awk '/^HOSTREGEXP::/' "$tmp_analysis")
fi

if [[ -n "$BODY_OUT" ]]; then
  cp "$tmp_body" "$BODY_OUT"
  info "Saved raw config body to ${BODY_OUT}"
fi

if ((has_critical == 1)); then
  err "Validation found critical issues."
  err "The 'tls: first record does not look like a TLS handshake' error is usually separate:"
  err "  - client sent plain HTTP to :443, or"
  err "  - backend URL scheme is wrong (http vs https)."
  exit 1
fi

info "Validation passed: no critical router/service mismatch found."
exit 0
