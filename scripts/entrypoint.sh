#!/bin/sh
# Container entrypoint.
#
# 1. Makes sure /dev/net/tun is usable (warn but continue if not).
# 2. Enables IPv4 forwarding when the container is privileged enough.
# 3. Delegates PID 1 to whatever CMD was passed in (s6-svscan by default).

set -e

if [ ! -c /dev/net/tun ]; then
    echo "[entrypoint] warn: /dev/net/tun is missing."
    echo "             Run the container with --device /dev/net/tun --cap-add NET_ADMIN"
fi

# Best-effort: enable forwarding so gost can relay traffic. Ignore failures
# on hosts where /proc/sys is read-only (e.g. some rootless setups).
for f in /proc/sys/net/ipv4/ip_forward /proc/sys/net/ipv6/conf/all/forwarding; do
    [ -w "$f" ] && echo 1 > "$f" 2>/dev/null || true
done

# Merge CORPLINK_* env vars into /config/config.json (preserves any runtime-
# generated fields like device_id/public_key/private_key/state).
if [ -x /app/render-config.sh ]; then
    /app/render-config.sh || echo "[entrypoint] warn: render-config.sh exited non-zero"
fi

exec "$@"
