#!/bin/bash
set -Eeuo pipefail

image="${1:?Usage: bash tests/docker/wordpress.sh IMAGE [XDEBUG] [EXPECTED_XDEBUG] [AUTO_INSTALL] [RUNTIME] [EXISTING_SITE] [INSTALL_METHOD]}"
xdebug="${2:-false}"
expected_xdebug="${3:-$xdebug}"
auto_install="${4:-false}"
runtime="${5:-apache-fpm}"
existing_site="${6:-false}"
install_method="${7:-cli}"
case "$auto_install" in true|false) ;; *) exit 2 ;; esac
case "$existing_site" in true|false) ;; *) exit 2 ;; esac
case "$install_method" in cli|web) ;; *) exit 2 ;; esac
if [ "$existing_site" = true ] && [ "$auto_install" = true ]; then
    echo 'Existing-site scenario uses an installation prepared before provisioning.' >&2
    exit 2
fi
case "$runtime" in
    apache-fpm) ;;
    apache)
        if [ "$auto_install" = true ]; then
            echo "Auto-install is only supported by the FPM image." >&2
            exit 2
        fi
        ;;
    *) echo "Runtime must be apache or apache-fpm." >&2; exit 2 ;;
esac
prefix="wp-smoke-$(date +%s)-$$"
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
        docker inspect --format 'Container status={{.State.Status}}, exit={{.State.ExitCode}}, stop signal={{.Config.StopSignal}}' "$site" >&2 2>/dev/null || true
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

wait_for_http() {
    if [ "$runtime" = apache-fpm ]; then
        wait_for docker exec "$site" php-fpm-healthcheck
    else
        wait_for curl --fail --silent "$url/wp-admin/install.php"
    fi
}

wp() {
    docker exec "$site" wp --allow-root --path=/var/www/html "$@"
}

cron_has_run() {
    [ "$(wp option get smoke_cron_marker 2>/dev/null)" = completed ]
}

provision_done() {
    (docker exec "$site" supervisorctl -c /etc/supervisor/supervisord.conf status wp-provision || true) | grep -q EXITED
}

doctor_has_run() {
    docker exec "$site" grep -q 'exit_code=1' /var/www/html/wp-content/wp-doctor.log
}

docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run -d --name "$database" --network "$network" --network-alias database \
    -e MARIADB_DATABASE=wordpress -e MARIADB_USER=wordpress \
    -e MARIADB_PASSWORD=smoke-test-only -e MARIADB_ROOT_PASSWORD=smoke-root-only \
    mariadb:12.3.3 >/dev/null
docker create --name "$site" --network "$network" --stop-timeout 70 \
    -p "127.0.0.1:$port:80" --mount "type=volume,source=$volume,target=/var/www/html" \
    -e WORDPRESS_DB_HOST=database -e WORDPRESS_DB_NAME=wordpress \
    -e WORDPRESS_DB_USER=wordpress -e WORDPRESS_DB_PASSWORD=smoke-test-only \
    -e WORDPRESS_PLUGINS= -e WP_CRON_INTERVAL=2 \
    -e "WORDPRESS_CONFIG_EXTRA=define('DISABLE_WP_CRON', true);" \
    -e "WORDPRESS_AUTO_INSTALL=$auto_install" -e "WORDPRESS_URL=$url" \
    -e WORDPRESS_TITLE='WordPress smoke test' -e WORDPRESS_ADMIN_USER=smoke_admin \
    -e WORDPRESS_ADMIN_EMAIL=smoke@example.invalid \
    -e WORDPRESS_ADMIN_PASSWORD_FILE=/run/wordpress-admin-password \
    -e "XDEBUG=$xdebug" -e XDEBUG_MODE=off "$image" >/dev/null
docker cp "$password_file" "$site:/run/wordpress-admin-password"
docker start "$site" >/dev/null

wait_for docker exec "$database" healthcheck.sh --connect --innodb_initialized
wait_for_http
wp core verify-checksums
docker exec "$site" php -r 'foreach (["bcmath", "exif", "gd", "intl", "mysqli", "Zend OPcache", "zip", "imagick"] as $extension) { if (!extension_loaded($extension)) { throw new RuntimeException("Missing extension: " . $extension); } }'
if [ "$runtime" = apache-fpm ]; then
    docker exec "$site" apache2ctl -M 2>/dev/null | grep -q mpm_event_module
else
    docker exec "$site" apache2ctl -M 2>/dev/null | grep -q mpm_prefork_module
fi
docker exec "$site" wp package list --allow-root --format=csv | grep -q wp-cli/doctor-command
echo 'PASS: core checksums, extensions, Apache MPM and Doctor'

if [ "$existing_site" = true ]; then
    docker exec "$site" supervisorctl -c /etc/supervisor/supervisord.conf stop wp-provision >/dev/null
    docker exec "$site" rm /var/www/html/wp-content/mu-plugins/wordpress-docker-runtime.php
fi

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
    if [ "$install_method" = web ]; then
        docker exec -i "$site" sh -c 'cat > /var/www/html/wp-content/mu-plugins/smoke-no-mail.php' <<'PHP'
<?php
add_filter('pre_wp_mail', '__return_true');
PHP
        curl --fail --silent \
            --data-urlencode 'weblog_title=WordPress smoke test' \
            --data-urlencode 'user_name=smoke_admin' \
            --data-urlencode 'admin_email=smoke@example.invalid' \
            --data-urlencode 'admin_password=smoke-test-admin-only' \
            --data-urlencode 'admin_password2=smoke-test-admin-only' \
            --data-urlencode 'blog_public=1' \
            "$url/wp-admin/install.php?step=2" >/dev/null
        wp core is-installed
        docker exec "$site" rm /var/www/html/wp-content/mu-plugins/smoke-no-mail.php
    else
        wp core install --url="$url" --title='WordPress smoke test' --admin_user=smoke_admin \
            --admin_email=smoke@example.invalid --admin_password=smoke-test-admin-only --skip-email --quiet
    fi
fi

if [ "$existing_site" = true ]; then
    wp option update default_comment_status open >/dev/null
    wp option update users_can_register 1 >/dev/null
    docker restart "$site" >/dev/null
    wait_for_http
fi
wait_for provision_done
if [ "$existing_site" = true ]; then
    [ "$(wp option get default_comment_status)" = open ]
    [ "$(wp option get users_can_register)" = 1 ]
else
    [ "$(wp option get default_comment_status)" = closed ]
    [ "$(wp option get users_can_register)" = 0 ]
fi
if wp option get wordpress_docker_defaults_pending >/dev/null 2>&1; then
    echo 'Fresh-install defaults were not completed.' >&2
    exit 1
fi
wp option update timezone_string Europe/Istanbul >/dev/null
wp eval '$next = wp_next_scheduled("wordpress_docker_doctor"); if (!$next || $next <= time() || wp_date("H:i", $next) !== "03:00") { throw new RuntimeException("Doctor must be scheduled for the next 03:00 in the site timezone."); }'
echo 'PASS: fresh-install defaults, existing-site preservation and nightly Doctor schedule'

if [ "$runtime" = apache-fpm ]; then
    if [ "$install_method" = cli ]; then
        docker exec "$site" test ! -e /var/www/html/.htaccess
    fi
    wp rewrite structure '/%postname%/'
else
    docker exec "$site" sh -c 'printf "apache_modules:\n  - mod_rewrite\n" > /var/www/html/wp-cli.yml'
    wp rewrite structure '/%postname%/' --hard
fi
wp post create --post_type=page --post_status=publish --post_title='Smoke page' --post_name=smoke-page --porcelain >/dev/null
page=$(curl --fail --silent "$url/smoke-page/")
grep -q 'Smoke page' <<< "$page"
rest=$(curl --fail --silent "$url/wp-json/")
grep -q 'WordPress smoke test' <<< "$rest"
if [ "$runtime" = apache-fpm ]; then
    [ "$(curl --silent --output /dev/null --write-out '%{http_code}' "$url/_health/fpm")" = 403 ]
fi

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
printf '%s' "$result" | docker exec -i -e "EXPECTED_XDEBUG=$expected_xdebug" -e "EXPECTED_RUNTIME=$runtime" "$site" php -r '
$result = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
$isFpm = getenv("EXPECTED_RUNTIME") === "apache-fpm";
if ($result["sapi"] !== ($isFpm ? "fpm-fcgi" : "apache2handler")
    || ($isFpm && $result["php"] !== "8.3")
    || $result["database"] !== "database"
    || $result["authorization"] !== "Bearer smoke-test-only"
    || $result["xdebug"] !== (getenv("EXPECTED_XDEBUG") === "true")) {
    throw new RuntimeException("Unexpected HTTP response: " . json_encode($result));
}'
docker exec "$site" rm /var/www/html/runtime-smoke.php
echo 'PASS: install, permalinks, REST, PHP environment, Authorization and Xdebug'

# Exercise Doctor's matched-file branch without flushing the site's cache.
docker exec -i "$site" sh -c 'cat > /var/www/html/wp-content/mu-plugins/smoke-cache-flush.php' <<'PHP'
<?php
function wordpress_smoke_unused_cache_flush(): void {
    wp_cache_flush();
}
PHP
cache_flush_result=$(wp doctor check cache-flush --format=json)
printf '%s' "$cache_flush_result" | docker exec -i "$site" php -r '
$checks = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
if (count($checks) !== 1 || $checks[0]["status"] !== "warning"
    || strpos($checks[0]["message"], "mu-plugins/smoke-cache-flush.php") === false) {
    throw new RuntimeException("Doctor did not report the cache-flush fixture: " . json_encode($checks));
}'
echo 'PASS: Doctor reports a detected cache flush without a fatal error'

docker exec "$site" chown root:root /var/www/html/wp-content
docker exec --user www-data "$site" test -w /var/www/html/wp-content/wp-doctor.log
wp option update blog_public 0 >/dev/null
wp eval 'wp_clear_scheduled_hook("wordpress_docker_doctor"); wp_schedule_event(time() - 1, "daily", "wordpress_docker_doctor");'
wait_for doctor_has_run
doctor_checks=$(wp doctor list --config=/usr/local/share/wp-cli/doctor-command/doctor.yml --format=csv --fields=name | tail -n +2)
[ -n "$doctor_checks" ]
while IFS= read -r check; do
    docker exec "$site" grep -Fq -- "$check" /var/www/html/wp-content/wp-doctor.log
done <<< "$doctor_checks"
docker exec "$site" grep -Fq 'mu-plugins/smoke-cache-flush.php' /var/www/html/wp-content/wp-doctor.log
if docker exec "$site" grep -q 'Fatal error' /var/www/html/wp-content/wp-doctor.log; then
    echo 'Doctor crashed during the scheduled checks.' >&2
    exit 1
fi
docker exec "$site" rm /var/www/html/wp-content/mu-plugins/smoke-cache-flush.php
[ "$(curl --silent --output /dev/null --write-out '%{http_code}' "$url/wp-content/wp-doctor.log")" = 403 ]
doctor_log_size=$(docker exec "$site" stat -c %s /var/www/html/wp-content/wp-doctor.log)
wp cron event run wordpress_docker_doctor --quiet
[ "$doctor_log_size" = "$(docker exec "$site" stat -c %s /var/www/html/wp-content/wp-doctor.log)" ]
wp option update blog_public 1 >/dev/null
docker exec "$site" chown www-data:www-data /var/www/html/wp-content
echo 'PASS: background Doctor runs all standard checks, logs errors, denies HTTP access and runs once per day'

docker exec -i "$site" sh -c 'mkdir -p /var/www/html/wp-content/mu-plugins; cat > /var/www/html/wp-content/mu-plugins/smoke-cron.php' <<'PHP'
<?php
add_action('smoke_cron_hook', function () {
    update_option('smoke_cron_marker', 'completed');
});
PHP
wp eval 'wp_schedule_single_event(time() - 1, "smoke_cron_hook");'
wait_for cron_has_run
docker exec "$site" rm /var/www/html/wp-content/mu-plugins/smoke-cron.php
wp option update default_comment_status open >/dev/null
wp option update users_can_register 1 >/dev/null
config_hash=$(docker exec "$site" sha256sum /var/www/html/wp-config.php)
docker restart "$site" >/dev/null
wait_for_http
wait_for provision_done
[ "$(wp option get default_comment_status)" = open ]
[ "$(wp option get users_can_register)" = 1 ]
docker exec "$site" grep -q 'exit_code=1' /var/www/html/wp-content/wp-doctor.log
[ "$config_hash" = "$(docker exec "$site" sha256sum /var/www/html/wp-config.php)" ]
[ "$(wp option get blogname)" = 'WordPress smoke test' ]
page=$(curl --fail --silent "$url/smoke-page/")
grep -q 'Smoke page' <<< "$page"
echo 'PASS: cron, persistence and administrator settings preserved after restart'

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

if [ "$runtime" = apache-fpm ]; then
    docker exec "$site" supervisorctl -c /etc/supervisor/supervisord.conf stop php-fpm >/dev/null
    if docker exec "$site" php-fpm-healthcheck >/dev/null 2>&1; then
        echo 'Healthcheck succeeded with FPM stopped.' >&2
        exit 1
    fi
    docker exec "$site" supervisorctl -c /etc/supervisor/supervisord.conf start php-fpm >/dev/null
    wait_for_http
fi
docker stop "$site" >/dev/null
exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$site")
if [ "$exit_code" -ne 0 ]; then
    echo "Container stopped with exit code $exit_code instead of 0." >&2
    exit 1
fi
echo "PASS: $image (XDEBUG=$xdebug; extension=$expected_xdebug; auto-install=$auto_install; existing-site=$existing_site; install-method=$install_method)"
