#!/bin/bash
set -Eeuo pipefail

image="${1:?Usage: bash tests/docker/apache-fpm.sh IMAGE [XDEBUG] [EXPECTED_XDEBUG] [AUTO_INSTALL]}"
xdebug="${2:-false}"
expected_xdebug="${3:-$xdebug}"
auto_install="${4:-false}"
case "$auto_install" in true|false) ;; *) exit 2 ;; esac
prefix="wp-fpm-smoke-$(date +%s)-$$"
network="$prefix-network"
database="$prefix-db"
site="$prefix-site"
volume="$prefix-data"
password_file=$(mktemp)
printf '%s\n' 'smoke-test-admin-only' > "$password_file"
port=$(python3 -c 'import socket; sock = socket.socket(); sock.bind(("127.0.0.1", 0)); print(sock.getsockname()[1]); sock.close()')
url="http://127.0.0.1:$port"

cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        docker logs --tail 50 "$site" >&2 2>/dev/null || true
    fi
    docker rm -fv "$site" "$database" >/dev/null 2>&1 || true
    docker volume rm "$volume" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -f "$password_file"
}
trap cleanup EXIT

wait_for() {
    for attempt in {1..60}; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "Timed out waiting for: $*" >&2
    return 1
}

wp() {
    docker exec "$site" wp --allow-root --path=/var/www/html "$@"
}

docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run -d --name "$database" --network "$network" --network-alias database \
    -e MARIADB_DATABASE=wordpress -e MARIADB_USER=wordpress \
    -e MARIADB_PASSWORD=smoke-test-only -e MARIADB_ROOT_PASSWORD=smoke-root-only \
    mariadb:10.11 >/dev/null
docker create --name "$site" --network "$network" --stop-timeout 70 \
    -p "127.0.0.1:$port:80" --mount "type=volume,source=$volume,target=/var/www/html" \
    -e WORDPRESS_DB_HOST=database -e WORDPRESS_DB_NAME=wordpress \
    -e WORDPRESS_DB_USER=wordpress -e WORDPRESS_DB_PASSWORD=smoke-test-only \
    -e WORDPRESS_PLUGINS= -e WP_CRON_INTERVAL=2 \
    -e "WORDPRESS_AUTO_INSTALL=$auto_install" -e "WORDPRESS_URL=$url" \
    -e WORDPRESS_TITLE='FPM smoke test' -e WORDPRESS_ADMIN_USER=smoke_admin \
    -e WORDPRESS_ADMIN_EMAIL=smoke@example.invalid \
    -e WORDPRESS_ADMIN_PASSWORD_FILE=/run/wordpress-admin-password \
    -e "XDEBUG=$xdebug" -e XDEBUG_MODE=off "$image" >/dev/null
docker cp "$password_file" "$site:/run/wordpress-admin-password"
docker start "$site" >/dev/null

wait_for docker exec "$database" healthcheck.sh --connect --innodb_initialized
wait_for docker exec "$site" php-fpm-healthcheck
wp core verify-checksums
docker exec "$site" php -r 'foreach (["bcmath", "exif", "gd", "intl", "mysqli", "Zend OPcache", "zip", "imagick"] as $extension) { if (!extension_loaded($extension)) { throw new RuntimeException("Missing extension: " . $extension); } }'
docker exec "$site" apache2ctl -M 2>/dev/null | grep -q mpm_event_module
docker exec "$site" wp package list --allow-root --format=csv | grep -q wp-cli/doctor-command
echo 'PASS: core checksums, extensions, event MPM and Doctor'

if [ "$auto_install" = true ]; then
    wp core is-installed
    docker exec "$site" wordpress-install | grep 'existing WordPress installation preserved'
    if docker logs "$site" 2>&1 | grep -q 'smoke-test-admin-only'; then
        echo 'Administrator password leaked in startup logs.' >&2
        exit 1
    fi
else
    if wp core is-installed >/dev/null 2>&1; then
        echo 'WordPress installed without opt-in.' >&2
        exit 1
    fi
    installer=$(curl --fail --silent "$url/wp-admin/install.php?step=1")
    grep -q 'name="weblog_title"' <<< "$installer"
    wp core install --url="$url" --title='FPM smoke test' --admin_user=smoke_admin \
        --admin_email=smoke@example.invalid --admin_password=smoke-test-admin-only --skip-email --quiet
fi
docker exec "$site" test ! -e /var/www/html/.htaccess
wp rewrite structure '/%postname%/'
wp post create --post_type=page --post_status=publish --post_title='Smoke page' --post_name=smoke-page --porcelain >/dev/null
page=$(curl --fail --silent "$url/smoke-page/")
grep -q 'Smoke page' <<< "$page"
rest=$(curl --fail --silent "$url/wp-json/")
grep -q 'FPM smoke test' <<< "$rest"
[ "$(curl --silent --output /dev/null --write-out '%{http_code}' "$url/_health/fpm")" = 403 ]

docker exec -i "$site" sh -c 'cat > /var/www/html/runtime-smoke.php' <<'PHP'
<?php
header('Content-Type: application/json');
echo json_encode([
    'sapi' => PHP_SAPI,
    'php' => PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION,
    'database' => getenv('WORDPRESS_DB_HOST'),
    'authorization' => $_SERVER['HTTP_AUTHORIZATION'] ?? '',
    'xdebug' => extension_loaded('xdebug'),
]);
PHP
result=$(curl --fail --silent -H 'Authorization: Bearer smoke-test-only' "$url/runtime-smoke.php")
printf '%s' "$result" | docker exec -i -e "EXPECTED_XDEBUG=$expected_xdebug" "$site" php -r '$result = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR); if ($result["sapi"] !== "fpm-fcgi" || $result["php"] !== "8.3" || $result["database"] !== "database" || $result["authorization"] !== "Bearer smoke-test-only" || $result["xdebug"] !== (getenv("EXPECTED_XDEBUG") === "true")) { throw new RuntimeException("Unexpected FPM response: " . json_encode($result)); }'
docker exec "$site" rm /var/www/html/runtime-smoke.php
echo 'PASS: install, permalinks, REST, FPM environment, Authorization and Xdebug'

wait_for docker exec "$site" supervisorctl -c /etc/supervisor/supervisord.conf status wp-cron
docker exec --user www-data "$site" wp cron event run --due-now --path=/var/www/html --quiet
config_hash=$(docker exec "$site" sha256sum /var/www/html/wp-config.php)
docker restart "$site" >/dev/null
wait_for docker exec "$site" php-fpm-healthcheck
[ "$config_hash" = "$(docker exec "$site" sha256sum /var/www/html/wp-config.php)" ]
[ "$(wp option get blogname)" = 'FPM smoke test' ]
page=$(curl --fail --silent "$url/smoke-page/")
grep -q 'Smoke page' <<< "$page"
echo 'PASS: cron and persistence after restart'

if [ "$auto_install" = true ]; then
    docker exec -e MYSQL_PWD=smoke-root-only "$database" mariadb -uroot -e \
        "CREATE DATABASE missing_params; CREATE DATABASE foreign_tables; GRANT ALL ON missing_params.* TO 'wordpress'@'%'; GRANT ALL ON foreign_tables.* TO 'wordpress'@'%'; CREATE TABLE foreign_tables.unrelated (id INT);"
    for guard_db in missing_params foreign_tables; do
        if output=$(docker exec -e "WORDPRESS_DB_NAME=$guard_db" -e WORDPRESS_ADMIN_PASSWORD_FILE= \
            -e WORDPRESS_ADMIN_PASSWORD= -e WORDPRESS_URL= "$site" wordpress-install 2>&1); then
            echo "Auto-install unexpectedly accepted $guard_db." >&2
            exit 1
        fi
        if [ "$guard_db" = missing_params ]; then
            grep -q 'Auto-install requires' <<< "$output"
            [ -z "$(docker exec -e WORDPRESS_DB_NAME=missing_params "$site" wp db query 'SHOW TABLES' --skip-column-names --allow-root)" ]
        else
            grep -q 'database contains tables' <<< "$output"
            [ "$(docker exec -e WORDPRESS_DB_NAME=foreign_tables "$site" wp db query 'SHOW TABLES' --skip-column-names --allow-root)" = unrelated ]
        fi
    done
    echo 'PASS: auto-install preserves installed sites, rejects missing parameters and protects non-empty databases'
fi

docker exec "$site" supervisorctl -c /etc/supervisor/supervisord.conf stop php-fpm >/dev/null
if docker exec "$site" php-fpm-healthcheck >/dev/null 2>&1; then
    echo 'Healthcheck succeeded with FPM stopped.' >&2
    exit 1
fi
docker exec "$site" supervisorctl -c /etc/supervisor/supervisord.conf start php-fpm >/dev/null
wait_for docker exec "$site" php-fpm-healthcheck
docker stop "$site" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$site")" = 0 ]
echo "PASS: $image (XDEBUG=$xdebug; extension=$expected_xdebug; auto-install=$auto_install)"
