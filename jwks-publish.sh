#!/bin/sh
# Periodically extract the JWT signing keys from the SPIRE trust bundle and
# write them to /var/www/jwks.json in plain JWKS format. busybox httpd serves
# the directory; consumers fetch http://<host>:8080/jwks.json.
set -eu

SOCK="${SOCK:-/tmp/spire-server/private/api.sock}"
DEST="/var/www/jwks.json"
INTERVAL="${SPIRE_JWKS_REFRESH_INTERVAL:-30}"

publish() {
    BUNDLE=$(/opt/spire/bin/spire-server bundle show \
                 -format spiffe \
                 -socketPath "$SOCK" 2>/dev/null || true)
    [ -n "$BUNDLE" ] || return 1

    # SPIRE's SPIFFE bundle (`bundle show -format spiffe`) puts every key
    # in a top-level `keys` array tagged either `use: x509-svid` or
    # `use: jwt-svid`. Filter to the JWT signing keys and relabel `use`
    # to the standard JWKS `sig` so generic JWT libraries are happy.
    printf '%s' "$BUNDLE" \
        | jq '{keys: [.keys[] | select(.use == "jwt-svid") | .use = "sig"]}' \
        >"${DEST}.tmp" \
        && mv "${DEST}.tmp" "$DEST"
}

# Wait for the first bundle to land before serving, so consumers don't hit
# an empty file.
while ! publish; do sleep 1; done

while sleep "$INTERVAL"; do
    publish || true
done
