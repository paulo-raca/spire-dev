#!/bin/bash
# Integration tests for paulocosta56/spire-dev.
#
# Builds the image as paulocosta56/spire-dev:ci, stands up the compose
# stack, and verifies:
#   1. Each labelled workload receives the expected SPIFFE ID via the
#      Workload API socket.
#   2. An unlabelled workload receives no SVID (negative case).
#   3. The /jwks.json HTTP endpoint serves a valid JWKS document with at
#      least one signing key.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
COMPOSE="docker compose -f $HERE/docker-compose.yml -p spire-dev-test"

cleanup() { $COMPOSE down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Building image${SPIRE_VERSION:+ (SPIRE $SPIRE_VERSION)}"
BUILD_ARGS=()
[ -n "${SPIRE_VERSION:-}" ] && BUILD_ARGS+=(--build-arg "SPIRE_VERSION=$SPIRE_VERSION")
docker build "${BUILD_ARGS[@]}" -t paulocosta56/spire-dev:ci "$ROOT"

echo "==> Bringing up test stack"
$COMPOSE up -d --wait

# Fetch the JWT-SVID for a workload through its own container's view of the
# Workload API socket. The agent inside the spire container is what attests
# the caller, but we exec spire-agent in the test workload's own container
# so SO_PEERCRED reports its container's PID.
fetch_svid_in() {
    local svc="$1"
    $COMPOSE exec -T "$svc" /opt/spire/bin/spire-agent api fetch jwt \
        -audience test \
        -socketPath /run/spire/sockets/agent.sock 2>&1
}

echo "==> [1/3] alpha receives spiffe://test.local/alpha"
out=$(fetch_svid_in alpha) || { echo "$out"; exit 1; }
echo "$out" | grep -q "token(spiffe://test.local/alpha):" || {
    echo "FAIL: alpha did not receive its SPIFFE ID"
    echo "$out"
    exit 1
}
echo "OK"

echo "==> [2/3] beta receives spiffe://test.local/beta"
out=$(fetch_svid_in beta) || { echo "$out"; exit 1; }
echo "$out" | grep -q "token(spiffe://test.local/beta):" || {
    echo "FAIL: beta did not receive its SPIFFE ID"
    echo "$out"
    exit 1
}
# And not alpha's
echo "$out" | grep -q "token(spiffe://test.local/alpha):" && {
    echo "FAIL: beta also received alpha's SVID — selectors leaking"
    echo "$out"
    exit 1
}
echo "OK"

echo "==> [3/3] intruder (unlabelled) receives no SVID"
out=$(fetch_svid_in intruder 2>&1 || true)
echo "$out" | grep -q "token(spiffe://test.local/" && {
    echo "FAIL: unlabelled workload received an SVID"
    echo "$out"
    exit 1
}
echo "OK"

echo "==> [4/4] JWKS endpoint serves valid keys"
# Give the publisher a moment to write the first file (refresh interval is 1s in this stack).
for _ in $(seq 1 15); do
    jwks=$($COMPOSE exec -T spire wget -qO- http://127.0.0.1:8080/jwks.json 2>/dev/null || true)
    [ -n "$jwks" ] && break
    sleep 1
done

[ -n "$jwks" ] || { echo "FAIL: JWKS endpoint did not respond"; exit 1; }

# Use jq inside the container since we don't know whether the host has it.
nkeys=$($COMPOSE exec -T spire sh -c \
    "wget -qO- http://127.0.0.1:8080/jwks.json | jq '.keys | length'")
[ "$nkeys" -ge 1 ] || {
    echo "FAIL: JWKS document had no keys"
    echo "$jwks"
    exit 1
}
echo "OK ($nkeys signing key(s))"

echo
echo "All tests passed."
