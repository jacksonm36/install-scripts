# Pangolin + Traefik: configuration fetching troubleshooting

This guide targets the exact log patterns you shared:

- `cannot fetch configuration data ... context deadline exceeded`
- `the service "...@http" does not exist`
- `No domain found in rule HostRegexp(...)`
- `tls: first record does not look like a TLS handshake`

## 1) Main failure: Pangolin config endpoint timeout

Traefik is trying to fetch dynamic config from:

`http://pangolin:3001/api/v1/traefik-config`

A timeout means Traefik cannot get a response in time from Pangolin.

### Quick checks

From inside the Traefik container/network:

```bash
curl -v --connect-timeout 5 --max-time 20 http://pangolin:3001/api/v1/traefik-config
```

You should get **HTTP 200** and a non-empty response body.

### Common causes

- `pangolin` is not on the same Docker network as Traefik
- Pangolin service is up but not listening on port `3001`
- Pangolin process is overloaded/unhealthy and misses Traefik timeout window
- Wrong scheme or target (HTTP vs HTTPS, wrong host/port)

## 2) Router references missing service

Error example:

`routerName="17-chat-router-redirect@http" ... service "17-chat-service@http" does not exist`

This means the fetched dynamic config contains a router with a service name that was not generated in the same provider payload.

### Fix pattern

If router is only redirect middleware, use:

```yaml
service: noop@internal
```

If router should actually forward traffic, make sure the service exists under:

```yaml
http:
  services:
    17-chat-service:
      ...
```

## 3) HostRegexp TLS warning

Warning example:

`No domain found in rule HostRegexp(...)`

Traefik cannot infer certificate domains from regex rules alone.

### Fix pattern

Add explicit `tls.domains` on those routers:

```yaml
tls:
  certResolver: letsencrypt
  domains:
    - main: gamedns.hu
      sans:
        - "*.gamedns.hu"
```

Use the matching root + wildcard for each domain (`controller-dns.hu`, `proxmoxjeno.cloud`, etc.).

## 4) TLS handshake error

Error:

`tls: first record does not look like a TLS handshake`

Usually one of these:

- plain HTTP request sent to HTTPS entrypoint (`:443`)
- HTTPS configured to backend that only speaks HTTP (or opposite)

Verify router entrypoint and backend URL scheme (`http://` vs `https://`) are aligned.

## 5) Use included validator script

This repository includes:

`./pangolin-traefik-debug.sh`

Example:

```bash
chmod +x ./pangolin-traefik-debug.sh
./pangolin-traefik-debug.sh --url http://pangolin:3001 --endpoint /api/v1/traefik-config
```

It validates:

- endpoint reachability and response status/body
- router -> service references (missing services)
- `HostRegexp` routers missing `tls.domains`
