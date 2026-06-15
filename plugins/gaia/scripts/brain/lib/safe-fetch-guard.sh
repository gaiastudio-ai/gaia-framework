#!/usr/bin/env bash
# safe-fetch-guard.sh — SSRF mitigation, scheme restriction, size cap, and
# timeout enforcement for the Brain's ingestion pipeline.
#
# SOURCEABLE ONLY — never execute directly.
#
# Exports (all prefixed _sfg_ to avoid namespace collision):
#   _sfg_check_ssrf URL           — reject if host resolves to a blocked address
#   _sfg_check_scheme URL         — reject if scheme is not http or https
#   _sfg_check_size_cap FILE      — reject if file exceeds 10 MB
#   _sfg_resolve_host HOSTNAME    — resolve hostname to IP (injectable seam)
#   _sfg_is_blocked_ip IP         — check if an IP is in a blocked range
#
# Test seam:
#   _SAFE_FETCH_RESOLVE_CMD — when set, this command is called instead of the
#   real DNS resolver.  Tests inject "echo 10.0.0.1" etc. to control resolution
#   without touching the network.
#
# Residual limitations (future hardening targets):
#   (a) The 30 s fetch timeout is defined here as a constant but enforced at the
#       orchestration layer (WebFetch / curl --max-time); this guard does not
#       perform the actual timed fetch.
#   (b) The SSRF blocklist covers IPv4 private/link-local/loopback/carrier-NAT
#       ranges plus IPv6 loopback (::1). IPv6 ULA (fc00::/7) and IPv6 link-local
#       (fe80::/10) are not yet blocked. A DNS-rebinding TOCTOU window exists
#       between the pre-check resolution and the orchestration-layer fetch.
#
# Portability: bash 3.2 (macOS default) clean. LC_ALL=C.

# Idempotent source guard.
if [ "${_SFG_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Maximum fetch size in bytes: 10 MB.
_SFG_MAX_SIZE_BYTES=$((10 * 1024 * 1024))

# Maximum fetch timeout in seconds.
_SFG_TIMEOUT_SECONDS=30

# ---------------------------------------------------------------------------
# _sfg_resolve_host HOSTNAME — resolve hostname to IP address(es).
#
# Honours the _SAFE_FETCH_RESOLVE_CMD test seam: when set, calls that command
# instead of the real DNS resolver.  This keeps the bats fully offline and
# deterministic.
# ---------------------------------------------------------------------------
_sfg_resolve_host() {
  local hostname="$1"

  if [ -n "${_SAFE_FETCH_RESOLVE_CMD:-}" ]; then
    # Test seam: use the injected resolver command. The command is expected to
    # produce the IP address(es) on stdout, one per line. The hostname is NOT
    # appended as an argument — the mock is self-contained.
    eval "$_SAFE_FETCH_RESOLVE_CMD" 2>/dev/null
    return $?
  fi

  # Production path: try getent, dig, host, nslookup in that order.
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$hostname" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short "$hostname" 2>/dev/null | grep -E '^[0-9.]+$|^[0-9a-f:]+$' | head -5
    return 0
  fi
  if command -v host >/dev/null 2>&1; then
    host "$hostname" 2>/dev/null | awk '/has address/{print $NF}; /has IPv6 address/{print $NF}' | head -5
    return 0
  fi
  if command -v nslookup >/dev/null 2>&1; then
    nslookup "$hostname" 2>/dev/null | awk '/^Address:/{if(NR>2) print $2}' | head -5
    return 0
  fi

  # No resolver available — fail closed (reject the URL).
  printf 'safe-fetch-guard: no DNS resolver available; failing closed\n' >&2
  return 1
}

# ---------------------------------------------------------------------------
# _sfg_is_blocked_ip IP — return 0 if the IP is in a blocked range, 1 otherwise.
#
# Blocked ranges (deterministic, no prompt drift):
#   - 10.0.0.0/8          (RFC 1918 private)
#   - 172.16.0.0/12       (RFC 1918 private)
#   - 192.168.0.0/16      (RFC 1918 private)
#   - 169.254.0.0/16      (link-local, includes cloud metadata at 169.254.169.254)
#   - 127.0.0.0/8         (loopback)
#   - ::1                 (IPv6 loopback)
#   - 100.64.0.0/10       (RFC 6598 carrier-grade NAT)
#   - 0.0.0.0/8           (current network)
# ---------------------------------------------------------------------------
_sfg_is_blocked_ip() {
  local ip="$1"

  # IPv6 loopback.
  case "$ip" in
    '::1'|'0:0:0:0:0:0:0:1'|'0000:0000:0000:0000:0000:0000:0000:0001')
      return 0
      ;;
  esac

  # IPv4 checks — extract octets.
  local o1 o2 o3 o4
  IFS='.' read -r o1 o2 o3 o4 <<EOF
$ip
EOF

  # Validate that we have numeric octets (not an IPv6 or garbage).
  case "$o1" in
    ''|*[!0-9]*) return 1 ;;  # Not a valid IPv4 — not blocked by this check
  esac

  # Loopback: 127.0.0.0/8
  [ "$o1" -eq 127 ] && return 0

  # RFC 1918: 10.0.0.0/8
  [ "$o1" -eq 10 ] && return 0

  # RFC 1918: 172.16.0.0/12 (172.16.0.0 – 172.31.255.255)
  if [ "$o1" -eq 172 ] && [ "$o2" -ge 16 ] && [ "$o2" -le 31 ]; then
    return 0
  fi

  # RFC 1918: 192.168.0.0/16
  if [ "$o1" -eq 192 ] && [ "$o2" -eq 168 ]; then
    return 0
  fi

  # Link-local: 169.254.0.0/16 (includes cloud metadata 169.254.169.254)
  if [ "$o1" -eq 169 ] && [ "$o2" -eq 254 ]; then
    return 0
  fi

  # RFC 6598: 100.64.0.0/10 (100.64.0.0 – 100.127.255.255)
  if [ "$o1" -eq 100 ] && [ "$o2" -ge 64 ] && [ "$o2" -le 127 ]; then
    return 0
  fi

  # Current network: 0.0.0.0/8
  [ "$o1" -eq 0 ] && return 0

  # Not in any blocked range.
  return 1
}

# ---------------------------------------------------------------------------
# _sfg_extract_host URL — extract the hostname from a URL.
# ---------------------------------------------------------------------------
_sfg_extract_host() {
  local url="$1"
  # Strip scheme.
  local after_scheme
  after_scheme="$(printf '%s' "$url" | sed 's|^[a-zA-Z]*://||')"
  # Strip path, query, fragment.
  local authority
  authority="$(printf '%s' "$after_scheme" | sed 's|[/?#].*||')"
  # Strip userinfo (user:pass@).
  local host_port
  host_port="$(printf '%s' "$authority" | sed 's|.*@||')"
  # Strip port.
  local host
  host="$(printf '%s' "$host_port" | sed 's|:[0-9]*$||')"
  printf '%s' "$host"
}

# ---------------------------------------------------------------------------
# _sfg_check_scheme SOURCE — reject if the source is a URL with a
# non-http(s) scheme. Non-URL sources (file paths, stdin) pass through.
# ---------------------------------------------------------------------------
_sfg_check_scheme() {
  local source="$1"

  # Only check URL sources.
  case "$source" in
    http://*|https://*)
      # Permitted schemes.
      return 0
      ;;
    *'://'*)
      # A URL with a scheme, but not http or https.
      printf 'safe-fetch-guard: rejected — scheme not permitted: %s\n' \
        "$(printf '%s' "$source" | sed 's|://.*||')" >&2
      return 1
      ;;
    *)
      # Not a URL (file path, stdin specifier, etc.) — pass through.
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# _sfg_check_ssrf SOURCE — reject if the URL's host resolves to a blocked
# address. Non-URL sources pass through.
# ---------------------------------------------------------------------------
_sfg_check_ssrf() {
  local source="$1"

  # Only check URL sources.
  case "$source" in
    http://*|https://*)
      ;;
    *)
      # Non-URL source — no SSRF risk. Pass through.
      return 0
      ;;
  esac

  local host
  host="$(_sfg_extract_host "$source")"

  if [ -z "$host" ]; then
    printf 'safe-fetch-guard: rejected — could not extract host from URL\n' >&2
    return 1
  fi

  # Resolve the host to IP address(es).
  local ips
  ips="$(_sfg_resolve_host "$host")"

  if [ -z "$ips" ]; then
    printf 'safe-fetch-guard: rejected — DNS resolution returned no addresses for: %s\n' "$host" >&2
    return 1
  fi

  # Check each resolved IP against the blocklist.
  local ip
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    # Trim whitespace.
    ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
    if _sfg_is_blocked_ip "$ip"; then
      printf 'safe-fetch-guard: rejected — host %s resolves to blocked address: %s\n' "$host" "$ip" >&2
      return 1
    fi
  done <<EOF
$ips
EOF

  return 0
}

# ---------------------------------------------------------------------------
# _sfg_check_size_cap FILE — reject if the file exceeds the 10 MB cap.
# ---------------------------------------------------------------------------
_sfg_check_size_cap() {
  local file="$1"

  if [ ! -f "$file" ]; then
    printf 'safe-fetch-guard: file not found for size check: %s\n' "$file" >&2
    return 1
  fi

  local size
  # Portable file size: wc -c (works on macOS and Linux).
  size="$(wc -c < "$file" | tr -d ' ')"

  if [ "$size" -gt "$_SFG_MAX_SIZE_BYTES" ]; then
    printf 'safe-fetch-guard: rejected — content exceeds %d byte size cap (actual: %d bytes)\n' \
      "$_SFG_MAX_SIZE_BYTES" "$size" >&2
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Module loaded flag.
# ---------------------------------------------------------------------------
_SFG_LOADED=1
export _SFG_LOADED

return 0 2>/dev/null || true
