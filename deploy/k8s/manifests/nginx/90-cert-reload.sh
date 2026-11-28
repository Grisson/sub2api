#!/bin/sh
# Runs from /docker-entrypoint.d before nginx starts. Starts a background loop
# that reloads nginx when the mounted TLS certificate changes (for example
# after cert-manager renews it), so renewals need no pod restart.
CERT=/etc/nginx/tls/tls.crt
(
    last=$(sha256sum "$CERT" 2>/dev/null | cut -d' ' -f1)
    while sleep 300; do
        cur=$(sha256sum "$CERT" 2>/dev/null | cut -d' ' -f1)
        if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
            echo "90-cert-reload: TLS certificate changed, reloading nginx"
            nginx -s reload && last=$cur
        fi
    done
) &
