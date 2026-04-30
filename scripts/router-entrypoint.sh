#!/bin/sh
# Router-profile entrypoint: starts corplink + gost without s6 to keep
# memory footprint low.  Uses backgrounded shells + `wait` so tini
# forwards signals correctly.

set -e

CONFFILE=/config/config.json

if [ ! -c /dev/net/tun ]; then
    echo "[entrypoint] warn: /dev/net/tun missing. Run with --device /dev/net/tun --cap-add NET_ADMIN"
fi

for f in /proc/sys/net/ipv4/ip_forward /proc/sys/net/ipv6/conf/all/forwarding; do
    [ -w "$f" ] && echo 1 > "$f" 2>/dev/null || true
done

while [ ! -e "$CONFFILE" ]; do
    echo "[entrypoint] waiting for $CONFFILE ..."
    sleep 5
done

# Start corplink-rs in the background
/app/corplink-rs "$CONFFILE" &
CORPLINK_PID=$!

# Wait briefly for the tun interface
tries=0
while [ "$tries" -lt 60 ]; do
    if ip link show 2>/dev/null | grep -qE '(^| )(corplink|utun|wg)[^ ]*:'; then
        break
    fi
    tries=$((tries + 1))
    sleep 2
done

# Launch gost
if [ -e /config/gost.yml ]; then
    /app/gost -C /config/gost.yml &
else
    SOCKS_PORT="${GOST_SOCKS_PORT:-1080}"
    HTTP_PORT="${GOST_HTTP_PORT:-8080}"
    if [ -n "$GOST_USER" ] && [ -n "$GOST_PASS" ]; then
        SOCKS_URL="socks5://${GOST_USER}:${GOST_PASS}@:${SOCKS_PORT}"
        HTTP_URL="http://${GOST_USER}:${GOST_PASS}@:${HTTP_PORT}"
    else
        SOCKS_URL="socks5://:${SOCKS_PORT}"
        HTTP_URL="http://:${HTTP_PORT}"
    fi
    /app/gost -L "$SOCKS_URL" -L "$HTTP_URL" &
fi
GOST_PID=$!

# Propagate exit of either process
trap 'kill -TERM $CORPLINK_PID $GOST_PID 2>/dev/null; wait' TERM INT
wait -n $CORPLINK_PID $GOST_PID
# If either child exits, terminate the other and surface the exit code
EXIT_CODE=$?
kill -TERM $CORPLINK_PID $GOST_PID 2>/dev/null || true
wait || true
exit "$EXIT_CODE"
