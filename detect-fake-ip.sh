#!/usr/bin/env bash
# Decide whether the Fake-IP DNS bridge is safe to enable, and cache the answer
# where the shell prelude can source it.
#
# Upstream's `configure_fake_ip_dns` requires BOTH the resolv.conf nameserver
# and a probe to land in RFC 2544 198.18.0.0/15. That holds when Clash runs its
# DNS listener inside WSL. A Clash TUN on the Windows side instead leaves
# resolv.conf pointing at the WSL2 NAT gateway (10.255.255.254) while public
# names still resolve into 198.18/15 -- so upstream's gate stays shut and every
# web_fetch is refused with "refusing to fetch a private/loopback/metadata
# address" for a perfectly ordinary domain.
#
# The probe is the decisive evidence: a catalogued public name resolving into
# the benchmarking range is Fake-IP by definition, whatever resolv.conf says.
# It decides here, and the resolver check survives only as a fast path that
# skips the lookup.
#
# This does not widen the bridge. webtools still accepts that range only for a
# hostname already in the egress catalogue, and never for an IP literal,
# loopback, link-local, metadata, or any other private range.
#
# Upstream calls the same shape "the narrower process flag"; measured here with
# cline-pass/deepseek-v4.1-flash, Crossref and OpenAlex both returned real
# records once it was on.
set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/.fake_ip.env"
RESOLV="${OPENAI4S_WSL_RESOLV_CONF:-/etc/resolv.conf}"
PROBE_HOST="${OPENAI4S_FAKE_IP_PROBE:-api.openalex.org}"

is_fake() {
    case "$1" in
        198.18.*|198.19.*) return 0 ;;
        *) return 1 ;;
    esac
}

resolver=""
if [ -r "$RESOLV" ]; then
    resolver="$(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2; exit}' "$RESOLV")"
fi

flag=0
reason=""
if is_fake "$resolver"; then
    flag=1
    reason="resolver is already in 198.18/15"
elif command -v getent >/dev/null 2>&1; then
    probe="$(getent ahostsv4 "$PROBE_HOST" 2>/dev/null | awk 'NR == 1 {print $1; exit}')"
    if is_fake "$probe"; then
        flag=1
        reason="probe $PROBE_HOST -> $probe"
    else
        reason="probe $PROBE_HOST -> ${probe:-unresolved}"
    fi
else
    reason="getent unavailable"
fi

printf 'export OPENAI4S_ALLOW_FAKE_IP_DNS=%s\n' "$flag" > "$OUT"

# Also record it in the checkout's .env. The prelude only reaches shells this
# launcher starts, and `openai4s run` is a separate process from the daemon --
# running it from a plain terminal left the bridge off and every web_fetch
# refused. config.py loads .env into os.environ at import for every entry
# point, so one write here covers the daemon, the CLI, and the tests alike.
ENV_FILE="${OPENAI4S_ENV_FILE:-$HOME/openai4s/.env}"
if [ -f "$ENV_FILE" ]; then
    if grep -q '^OPENAI4S_ALLOW_FAKE_IP_DNS=' "$ENV_FILE"; then
        sed -i "s|^OPENAI4S_ALLOW_FAKE_IP_DNS=.*|OPENAI4S_ALLOW_FAKE_IP_DNS=$flag|" "$ENV_FILE"
    else
        printf '\n# Fake-IP DNS bridge, decided by detect-fake-ip.sh on each start.\nOPENAI4S_ALLOW_FAKE_IP_DNS=%s\n' "$flag" >> "$ENV_FILE"
    fi
fi

echo "fake-ip: OPENAI4S_ALLOW_FAKE_IP_DNS=$flag  (resolver=${resolver:-none}; $reason)"
echo "fake-ip: written to $OUT and ${ENV_FILE}"
