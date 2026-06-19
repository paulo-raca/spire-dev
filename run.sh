#!/bin/sh
# spire-dev: single-container SPIRE server + agent + bootstrap + JWKS HTTP.
#
# Required env:
#   SPIRE_TRUST_DOMAIN     e.g. "test.local"
#   SPIRE_WORKLOADS        space-separated workload names. For each <name>:
#                            - registration entry with selector
#                              docker:label:${SPIRE_WORKLOAD_LABEL}:<name>
#                            - SPIFFE ID spiffe://${SPIRE_TRUST_DOMAIN}/<name>
#                          Workloads opt in by setting that docker label.
# Optional env:
#   SPIRE_WORKLOAD_LABEL   docker label key. Default "io.spiffe.workload".
#   SPIRE_JWKS_PORT        HTTP port for /jwks.json. Default 8080.
#
# Exposes:
#   /run/spire/sockets/agent.sock   SPIFFE Workload API
#   http://<host>:${SPIRE_JWKS_PORT}/jwks.json   JWKS of the JWT trust bundle
set -eu

: "${SPIRE_TRUST_DOMAIN:?must be set, e.g. test.local}"
: "${SPIRE_WORKLOADS:?must be set, e.g. 'web api db'}"
SPIRE_WORKLOAD_LABEL="${SPIRE_WORKLOAD_LABEL:-io.spiffe.workload}"
SPIRE_JWKS_PORT="${SPIRE_JWKS_PORT:-8080}"

SOCK="/tmp/spire-server/private/api.sock"
export SOCK

mkdir -p /run/spire/server-data /run/spire/agent-data /run/spire/sockets /var/www
chmod 1777 /run/spire/sockets

sed "s|@TRUST_DOMAIN@|${SPIRE_TRUST_DOMAIN}|g" \
    /etc/spire/server.conf.tmpl >/etc/spire/server.conf
sed "s|@TRUST_DOMAIN@|${SPIRE_TRUST_DOMAIN}|g" \
    /etc/spire/agent.conf.tmpl >/etc/spire/agent.conf

# Start server in background; propagate signals.
/opt/spire/bin/spire-server run -config /etc/spire/server.conf &
SERVER_PID=$!
trap 'kill -TERM "$SERVER_PID" $(jobs -p) 2>/dev/null; wait' INT TERM

# Wait until the server's admin API returns a non-empty trust bundle.
i=0
while [ "$i" -lt 60 ]; do
    if [ -S "$SOCK" ]; then
        BUNDLE=$(/opt/spire/bin/spire-server bundle show -socketPath "$SOCK" 2>/dev/null || true)
        [ -n "$BUNDLE" ] && break
    fi
    i=$((i + 1))
    sleep 1
done
[ -n "${BUNDLE:-}" ] || { echo "spire-server never returned a bundle" >&2; exit 1; }
printf '%s' "$BUNDLE" >/run/spire/agent-data/bundle.crt

# Mint the agent's join token.
TOKEN=$(/opt/spire/bin/spire-server token generate -socketPath "$SOCK" \
        | awk '/Token:/{print $2}')
[ -n "$TOKEN" ] || { echo "failed to mint join token" >&2; exit 1; }
PARENT="spiffe://${SPIRE_TRUST_DOMAIN}/spire/agent/join_token/${TOKEN}"

# Register one entry per declared workload.
for workload in $SPIRE_WORKLOADS; do
    /opt/spire/bin/spire-server entry create -socketPath "$SOCK" \
        -parentID "$PARENT" \
        -spiffeID "spiffe://${SPIRE_TRUST_DOMAIN}/${workload}" \
        -selector "docker:label:${SPIRE_WORKLOAD_LABEL}:${workload}" \
        -x509SVIDTTL 300 \
        -jwtSVIDTTL 300 \
        || true
done

# Publish the JWKS as soon as we have it; busybox httpd serves /var/www.
/usr/local/bin/jwks-publish.sh &
httpd -f -h /var/www -p "0.0.0.0:${SPIRE_JWKS_PORT}" &

# Agent runs in the foreground.
exec /opt/spire/bin/spire-agent run \
    -config /etc/spire/agent.conf \
    -joinToken "${TOKEN}"
