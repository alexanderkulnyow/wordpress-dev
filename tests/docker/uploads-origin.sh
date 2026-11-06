#!/bin/bash
set -Eeuo pipefail

image="${1:?Usage: bash tests/docker/uploads-origin.sh IMAGE [apache|apache-fpm]}"
runtime="${2:-apache-fpm}"
case "$runtime" in apache|apache-fpm) ;; *) exit 2 ;; esac
root=$(cd "$(dirname "$0")/../.." && pwd)
prefix="wp-uploads-smoke-$(date +%s)-$$"
network="$prefix-network"
site="$prefix-site"
upstream="$prefix-upstream"
work=$(mktemp -d)
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
url="http://127.0.0.1:$port"
cleanup() {
    status=$?
    if [ "$status" -ne 0 ]; then
        docker logs --tail 60 "$site" >&2 || true
        docker logs --tail 30 "$upstream" >&2 || true
        docker exec "$upstream" cat /tmp/upstream-requests.jsonl >&2 || true
        cat "$work/headers" "$work/body" >&2 2>/dev/null || true
    fi
    docker rm -fv "$site" "$upstream" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
wait_http() {
    for attempt in {1..60}; do
        if [ "$(curl -s --max-time 2 "$url/probe.txt" || true)" = ready ]; then return; fi
        sleep 1
    done
    echo 'Timed out waiting for Apache.' >&2; return 1
}
request() {
    code=$(curl --silent --show-error --max-time 15 -D "$work/headers" -o "$work/body" -w '%{http_code}' "$@")
}
restart_with() {
    printf '%s' "$1" | docker exec -i "$site" sh -c 'cat > /tmp/test-uploads-origin'
    docker restart "$site" >/dev/null
    wait_http
    docker exec "$site" apache2ctl -t
}

# Use the tested image as an isolated upstream too; no extra service image/download.
docker network create "$network" >/dev/null
docker create --name "$upstream" --network "$network" --network-alias upstream --network-alias wrong-host \
    --entrypoint bash "$image" /tmp/start-upstream >/dev/null
docker cp "$root/tests/docker/fixtures/uploads-upstream.php" "$upstream:/tmp/upstream.php"
cat > "$work/start-upstream" <<'UPSTREAM'
#!/bin/bash
set -e
# Trust only the root on the client; Apache must follow the served intermediate.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=uploads-test-root \
    -addext 'basicConstraints=critical,CA:TRUE,pathlen:1' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout /tmp/root.key -out /tmp/root.crt >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj /CN=uploads-test-intermediate \
    -keyout /tmp/intermediate.key -out /tmp/intermediate.csr >/dev/null 2>&1
cat > /tmp/intermediate.ext <<'EXT'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EXT
openssl x509 -req -days 1 -in /tmp/intermediate.csr -CA /tmp/root.crt -CAkey /tmp/root.key \
    -CAcreateserial -extfile /tmp/intermediate.ext -out /tmp/intermediate.crt >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj /CN=upstream \
    -keyout /tmp/upstream.key -out /tmp/upstream.csr >/dev/null 2>&1
cat > /tmp/upstream.ext <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:upstream
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EXT
openssl x509 -req -days 1 -in /tmp/upstream.csr -CA /tmp/intermediate.crt -CAkey /tmp/intermediate.key \
    -CAcreateserial -extfile /tmp/upstream.ext -out /tmp/upstream.crt >/dev/null 2>&1
cat /tmp/upstream.crt /tmp/intermediate.crt > /tmp/upstream-fullchain.pem
cat > /etc/apache2/sites-enabled/000-upstream.conf <<'APACHE'
Listen 443
<VirtualHost *:443>
    ServerName upstream
    SSLEngine On
    SSLCertificateFile /tmp/upstream-fullchain.pem
    SSLCertificateKeyFile /tmp/upstream.key
    ProxyPass / http://127.0.0.1:8080/
</VirtualHost>
APACHE
php -S 0.0.0.0:8080 /tmp/upstream.php >/tmp/php-upstream.log 2>&1 &
exec apache2-foreground
UPSTREAM
docker cp "$work/start-upstream" "$upstream:/tmp/start-upstream"
docker start "$upstream" >/dev/null

# Reload the environment from a test-only file on each actual container start.
# This lets one writable layer exercise stale config removal and site persistence.
cat > "$work/start-site" <<'SITE'
#!/bin/bash
set -e
export WORDPRESS_UPLOADS_ORIGIN="$(cat /tmp/test-uploads-origin 2>/dev/null || true)"
exec phpdxdebug "$1" apache2-foreground-supervised
SITE
entrypoint=docker-entrypoint.sh
if [ "$runtime" = apache-fpm ]; then entrypoint=wordpress-entrypoint; fi
docker create --name "$site" --network "$network" --stop-timeout 70 -p "127.0.0.1:$port:80" \
    -e WORDPRESS_DB_HOST=127.0.0.1 -e WORDPRESS_DB_PASSWORD=smoke-test-only \
    -e WORDPRESS_PLUGINS= --entrypoint bash "$image" /tmp/start-site "$entrypoint" >/dev/null
docker cp "$work/start-site" "$site:/tmp/start-site"
docker start "$site" >/dev/null
for attempt in {1..60}; do
    if docker exec "$site" test -f /var/www/html/wp-includes/version.php; then break; fi
    sleep 1
done
docker exec -i "$site" bash <<'SETUP'
set -e
cd /var/www/html
printf ready > probe.txt
printf '<?php echo "front-controller";' > index.php
printf '<?php echo $_SERVER["HTTP_AUTHORIZATION"] ?? "";' > auth-check.php
mkdir -p wp-content/uploads/private
printf local-media > wp-content/uploads/local.jpg
cat > .htaccess <<'HTACCESS'
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
HTACCESS
printf 'Require all denied\n' > wp-content/uploads/private/.htaccess
printf '<FilesMatch "\\.php$">\nRequire all denied\n</FilesMatch>\n' > wp-content/uploads/.htaccess
SETUP
wait_http
config_hash=$(docker exec "$site" sha256sum /var/www/html/wp-config.php)
request "$url/wp-content/uploads/remote.jpg"
[ "$code" = 200 ]
[ "$(cat "$work/body")" = front-controller ]
docker exec "$site" test ! -e /etc/apache2/conf-enabled/wordpress-uploads-origin.conf
echo 'PASS: disabled fallback preserves the existing front controller'

restart_with http://upstream:8080
request "$url/wp-content/uploads/local.jpg"
[ "$code" = 200 ]
[ "$(cat "$work/body")" = local-media ]
for path in remote.jpg 2026/11/remote.jpg thumb-150x150.png image.svg document.pdf video.mp4 'space%20%23%26%C3%A9.jpg'; do
    request -H 'Cookie: local-session=secret' -H 'Authorization: Bearer local-secret' "$url/wp-content/uploads/$path?size=1"
    [ "$code" = 200 ]
    [ "$(cat "$work/body")" = remote-media-0123456789 ]
    case "$path" in
        *.png) mime=image/png ;;
        *.svg) mime=image/svg+xml ;;
        *.pdf) mime=application/pdf ;;
        *.mp4) mime=video/mp4 ;;
        *) mime=image/jpeg ;;
    esac
    grep -qi "^Content-Type: $mime" "$work/headers"
    grep -qi '^X-Uploads-Upstream: yes' "$work/headers"
    if grep -qi '^Set-Cookie:' "$work/headers"; then echo 'Upstream cookie leaked.' >&2; exit 1; fi
done
request "$url/wp-content/uploads/missing.jpg"
[ "$code" = 404 ]
[ "$(cat "$work/body")" = upstream-404 ]
code=$(curl --silent --show-error --head --max-time 15 -o "$work/headers" -w '%{http_code}' "$url/wp-content/uploads/video.mp4")
[ "$code" = 200 ]
grep -qi '^Content-Length: 23' "$work/headers"
request -H 'Range: bytes=2-7' "$url/wp-content/uploads/video.mp4"
[ "$code" = 206 ]
[ "$(cat "$work/body")" = mote-m ]
grep -qi '^Content-Range: bytes 2-7/23' "$work/headers"
request "$url/wp-content/uploads/redirect.jpg"
[ "$code" = 302 ]
grep -qi "^Location: $url/wp-content/uploads/remote.jpg" "$work/headers"
for method in POST PUT PATCH DELETE OPTIONS; do
    request -X "$method" "$url/wp-content/uploads/blocked.jpg"
    [ "$code" = 404 ]
done
for path in other.jpg wp-content/plugins/remote.jpg wp-content/uploads-other/remote.jpg; do
    request "$url/$path"
    [ "$(cat "$work/body")" = front-controller ]
done
for path in private/remote.jpg denied.php .htaccess; do
    request "$url/wp-content/uploads/$path"
    [ "$code" = 403 ]
done
request -H 'Authorization: Bearer local-secret' "$url/auth-check.php"
[ "$code" = 200 ]
[ "$(cat "$work/body")" = 'Bearer local-secret' ]
# A new local upload wins immediately, without restarting Apache.
docker exec "$site" sh -c 'printf new-local > /var/www/html/wp-content/uploads/remote.jpg'
request "$url/wp-content/uploads/remote.jpg"
[ "$(cat "$work/body")" = new-local ]
docker exec "$site" rm /var/www/html/wp-content/uploads/remote.jpg
docker exec "$site" sh -c 'test "$(find /var/www/html/wp-content/uploads -type f ! -name .htaccess | wc -l)" -eq 1'
# The local uploads tree itself may be absent on a fresh development machine.
docker exec "$site" mv /var/www/html/wp-content/uploads /tmp/local-uploads
restart_with http://upstream:8080
docker exec --user www-data "$site" test -w /var/www/html/wp-content/uploads
request "$url/wp-content/uploads/absent-directory.jpg"
[ "$code" = 200 ]
[ "$(cat "$work/body")" = remote-media-0123456789 ]
docker exec "$site" rmdir /var/www/html/wp-content/uploads
docker exec "$site" mv /tmp/local-uploads /var/www/html/wp-content/uploads
echo 'PASS: local priority, media types, escaped filenames, 404, HEAD, Range, method/path boundaries, access checks and no disk writes'

restart_with https://upstream
request "$url/wp-content/uploads/untrusted.jpg"
case "$code" in 500|502) ;; *) echo "Expected TLS proxy failure, got $code." >&2; exit 1 ;; esac
grep -qi 'Error during SSL Handshake' "$work/body"
# Deliberately do not install the leaf or intermediate into the client's trust store.
docker cp "$upstream:/tmp/root.crt" "$work/root.crt"
docker cp "$work/root.crt" "$site:/usr/local/share/ca-certificates/uploads-test.crt"
docker exec "$site" update-ca-certificates >/dev/null
restart_with https://upstream
request "$url/wp-content/uploads/trusted.jpg"
if [ "$code" != 200 ]; then
    echo "Expected HTTPS 200 with a trusted root and served intermediate, got $code." >&2
    exit 1
fi
[ "$(cat "$work/body")" = remote-media-0123456789 ]
restart_with https://wrong-host
request "$url/wp-content/uploads/wrong-host.jpg"
case "$code" in 500|502) ;; *) echo "Expected TLS proxy failure, got $code." >&2; exit 1 ;; esac
grep -qi 'Error during SSL Handshake' "$work/body"
echo 'PASS: HTTPS follows the served intermediate to the trusted root and rejects untrusted chains and wrong hostnames'

restart_with ''
docker exec "$site" test ! -e /etc/apache2/conf-enabled/wordpress-uploads-origin.conf
request "$url/wp-content/uploads/remote.jpg"
[ "$(cat "$work/body")" = front-controller ]
[ "$config_hash" = "$(docker exec "$site" sha256sum /var/www/html/wp-config.php)" ]
restart_with http://upstream:8080/
request "$url/wp-content/uploads/re-enabled.jpg"
[ "$code" = 200 ]
# Validation is tested in the same image; an invalid value must clear stale config.
for origin in 'ftp://upstream' 'http://user:pass@upstream' 'https://upstream/path' 'https://upstream?x=1' 'https://upstream#fragment' 'http://upstream:0' 'http://upstream:65536' 'http://bad_host' $'http://upstream\nProxyRequests On'; do
    if docker exec -e "WORDPRESS_UPLOADS_ORIGIN=$origin" "$site" wp-uploads-origin-init > "$work/validation" 2>&1; then
        echo "Origin validation unexpectedly succeeded." >&2; exit 1
    fi
    grep -q 'must be an HTTP(S) origin' "$work/validation"
    docker exec "$site" test ! -e /etc/apache2/conf-enabled/wordpress-uploads-origin.conf
done

docker cp "$upstream:/tmp/upstream-requests.jsonl" "$work/requests.jsonl"
python3 - "$work/requests.jsonl" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
assert rows
assert all(r['method'] in ('GET', 'HEAD') for r in rows), rows
assert all(r['path'].startswith('/wp-content/uploads/') for r in rows), rows
assert all(not r['cookie'] and not r['authorization'] for r in rows), rows
assert not any(any(s in r['path'] for s in ('local.jpg', 'blocked', 'private', 'denied', '.htaccess', 'wrong-host', 'untrusted')) for r in rows), rows
assert any(r['method'] == 'HEAD' for r in rows), rows
assert any(r['path'].lower().endswith('/space%20%23%26%c3%a9.jpg') and r['query'] == 'size=1' for r in rows), rows
PY
echo "PASS: $image credentials stripped, origin validation, restart origin change/disable/re-enable and wp-config preservation"
