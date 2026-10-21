#!/bin/bash
set -Eeuo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
image_prefix="${1:-wordpress-smoke}"

for runtime in apache apache-fpm; do
    for variant in prod dev; do
        image="$image_prefix-$runtime:$variant"
        docker build --pull --build-arg "APP_ENV=$variant" -t "$image" "$root/.docker/$runtime"
    done
done

for runtime in apache apache-fpm; do
    for variant in prod dev; do
        bash "$root/tests/docker/log-mount.sh" "$image_prefix-$runtime:$variant" "$runtime"
    done
    # A prod image must ignore XDEBUG=true; dev must support both settings.
    bash "$root/tests/docker/wordpress.sh" "$image_prefix-$runtime:prod" true false false "$runtime" false web
    bash "$root/tests/docker/wordpress.sh" "$image_prefix-$runtime:dev" false false false "$runtime"
    bash "$root/tests/docker/wordpress.sh" "$image_prefix-$runtime:dev" true true false "$runtime"
    bash "$root/tests/docker/wordpress.sh" "$image_prefix-$runtime:prod" false false false "$runtime" true
done

bash "$root/tests/docker/wordpress.sh" "$image_prefix-apache-fpm:prod" false false true apache-fpm
echo 'PASS: all four images, log mounts, defaults, existing sites, Doctor, Xdebug settings and FPM auto-install'
