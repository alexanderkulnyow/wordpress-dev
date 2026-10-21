#!/bin/bash
set -Eeuo pipefail

image="${1:?Usage: bash tests/docker/log-mount.sh IMAGE [apache|apache-fpm]}"
runtime="${2:-apache-fpm}"
case "$runtime" in apache|apache-fpm) ;; *) exit 2 ;; esac
prefix="wp-log-smoke-$(date +%s)-$$"
site="$prefix-site"
logs="$prefix-logs"

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        docker logs --tail 40 "$site" >&2 || true
    fi
    docker rm -fv "$site" >/dev/null 2>&1 || true
    docker volume rm "$logs" >/dev/null 2>&1 || true
}
trap cleanup EXIT

running() {
    local process="$1"
    docker exec "$site" supervisorctl -c /etc/supervisor/supervisord.conf status "$process" 2>/dev/null | grep -q RUNNING
}

docker volume create "$logs" >/dev/null
# nocopy reproduces an empty bind mount hiding the image's /var/log directories.
docker run -d --name "$site" --stop-timeout 70 \
    --mount "type=volume,source=$logs,target=/var/log,volume-nocopy" \
    -e WORDPRESS_DB_HOST=127.0.0.1 -e WORDPRESS_DB_PASSWORD=smoke-test-only \
    -e WORDPRESS_PLUGINS= "$image" >/dev/null

ready=false
for attempt in {1..30}; do
    if [ "$(docker inspect --format '{{.State.Running}}' "$site")" != true ]; then
        echo 'Container exited with an empty /var/log mount.' >&2
        exit 1
    fi
    if running apache2 && { [ "$runtime" = apache ] || running php-fpm; }; then
        ready=true
        break
    fi
    sleep 1
done
[ "$ready" = true ]
docker exec "$site" test -f /var/log/supervisor/supervisord.log
docker exec "$site" test -d /var/log/apache2
docker exec "$site" sh -c 'printf "%s\n" retained > /var/log/supervisor/smoke-retained.log'
docker restart "$site" >/dev/null
for attempt in {1..30}; do
    if running apache2 && { [ "$runtime" = apache ] || running php-fpm; }; then
        break
    fi
    sleep 1
done
running apache2
if [ "$runtime" = apache-fpm ]; then running php-fpm; fi
[ "$(docker exec "$site" cat /var/log/supervisor/smoke-retained.log)" = retained ]
echo "PASS: $image starts with an empty /var/log mount and preserves logs after restart"
