# Apache + PHP-FPM WordPress images

This image runs Apache with `mpm_event` and PHP-FPM 8.3 in one container. It includes WordPress,
WP-CLI, Doctor, Composer, plugin provisioning and scheduled cron. The prod image has no Xdebug;
the dev image includes it and loads it only when `XDEBUG=true`.

## Published images

| Environment | Docker Hub | GHCR |
|---|---|---|
| dev | `alexanderkulnyow/wordpress-apache-fpm-dev` | `ghcr.io/alexanderkulnyow/wordpress-apache-fpm-dev` |
| prod | `alexanderkulnyow/wordpress-apache-fpm-prod` | `ghcr.io/alexanderkulnyow/wordpress-apache-fpm-prod` |

Both support amd64 and arm64, with `latest` and published commit SHA tags. CI builds on PRs to
`main` and publishes on pushes or manual runs from `main`, pulling current base images. The separate `wordpress-dev` / `wordpress-prod` image
names continue to use Apache + mod_php.

## Run a published image

Requires Docker Engine or Docker Desktop with Docker Compose. In a new directory, save the
following two files as `compose.yaml` and `.env`. Downloadable copies are available as
[compose.yaml](../examples/apache-fpm/compose.yaml) and
[.env.example](../examples/apache-fpm/.env.example); rename `.env.example` to `.env` when copying it.
This setup pulls the published image and needs no repository checkout or local build.

`compose.yaml`:

```yaml
name: ${PROJECT_NAME:-my-wordpress-apache-fpm}

services:
    database:
        image: mariadb:12.3.3
        restart: unless-stopped
        environment:
            MARIADB_DATABASE: ${WORDPRESS_DB_NAME:-wordpress}
            MARIADB_USER: ${WORDPRESS_DB_USER:-wordpress}
            MARIADB_PASSWORD: ${WORDPRESS_DB_PASSWORD:?Set WORDPRESS_DB_PASSWORD in .env}
            MARIADB_RANDOM_ROOT_PASSWORD: "1"
        volumes:
            - db-data:/var/lib/mysql
        healthcheck:
            test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
            interval: 5s
            timeout: 5s
            retries: 30
        mem_limit: ${DB_MEM_LIMIT:-512m}
        cpus: ${DB_CPUS:-1}

    wordpress:
        image: alexanderkulnyow/wordpress-apache-fpm-${APP_ENV:-prod}:${IMAGE_TAG:-latest}
        restart: unless-stopped
        depends_on:
            database:
                condition: service_healthy
        ports:
            - "127.0.0.1:${WORDPRESS_PORT:-8083}:80"
        environment:
            WORDPRESS_DB_HOST: database
            WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME:-wordpress}
            WORDPRESS_DB_USER: ${WORDPRESS_DB_USER:-wordpress}
            WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD:?Set WORDPRESS_DB_PASSWORD in .env}
            WORDPRESS_TABLE_PREFIX: ${WORDPRESS_TABLE_PREFIX:-wp_}
            WORDPRESS_DEBUG: ${WORDPRESS_DEBUG:-0}
            WORDPRESS_PLUGINS: ${WORDPRESS_PLUGINS-}
            WP_CRON_INTERVAL: ${WP_CRON_INTERVAL:-60}
            XDEBUG: ${XDEBUG:-false}
            PHP_FPM_MAX_CHILDREN: ${PHP_FPM_MAX_CHILDREN:-2}
            WORDPRESS_AUTO_INSTALL: ${WORDPRESS_AUTO_INSTALL:-false}
            WORDPRESS_URL: ${WORDPRESS_URL:-}
            WORDPRESS_TITLE: ${WORDPRESS_TITLE:-}
            WORDPRESS_ADMIN_USER: ${WORDPRESS_ADMIN_USER:-}
            WORDPRESS_ADMIN_EMAIL: ${WORDPRESS_ADMIN_EMAIL:-}
            WORDPRESS_ADMIN_PASSWORD: ${WORDPRESS_ADMIN_PASSWORD:-}
        volumes:
            - wp-data:/var/www/html
        extra_hosts:
            - "host.docker.internal:host-gateway"
        stop_grace_period: 70s
        mem_limit: ${WORDPRESS_MEM_LIMIT:-1g}
        cpus: ${WORDPRESS_CPUS:-2}

volumes:
    db-data:
    wp-data:
```

`.env`:

```dotenv
PROJECT_NAME=my-wordpress-apache-fpm
APP_ENV=prod
IMAGE_TAG=latest
WORDPRESS_PORT=8083

WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wordpress
# Set a password before starting. Single quotes preserve literal $ and # characters.
WORDPRESS_DB_PASSWORD=
WORDPRESS_TABLE_PREFIX=wp_
WORDPRESS_DEBUG=0

# Comma-separated plugin slugs; empty installs no extra plugins.
WORDPRESS_PLUGINS=
WP_CRON_INTERVAL=60
# To debug locally, select APP_ENV=dev and XDEBUG=true.
XDEBUG=false
PHP_FPM_MAX_CHILDREN=2

# false: use the web installer; true: install a fresh site using the values below.
WORDPRESS_AUTO_INSTALL=false
# Match the address visitors use, including WORDPRESS_PORT for localhost.
WORDPRESS_URL=http://localhost:8083
WORDPRESS_TITLE='My WordPress site'
WORDPRESS_ADMIN_USER=site_admin
WORDPRESS_ADMIN_EMAIL=admin@example.com
# Required only when WORDPRESS_AUTO_INSTALL=true; set your own password.
WORDPRESS_ADMIN_PASSWORD=

WORDPRESS_MEM_LIMIT=1g
WORDPRESS_CPUS=2
DB_MEM_LIMIT=512m
DB_CPUS=1
```

Set `WORDPRESS_DB_PASSWORD` to your own password. Then run from this directory:

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
```

Open `http://localhost:8083` and complete the WordPress web installer. The example defaults to
`APP_ENV=prod` and `WORDPRESS_AUTO_INSTALL=false`. Site files and MariaDB data persist in named volumes.
The database and FPM have no published ports; HTTP is bound to localhost.

Set `WORDPRESS_PORT` to use a different host port. If enabling auto-install, update `WORDPRESS_URL`
to the address visitors use. For a remote deployment, configure the HTTP binding or a reverse proxy
and set `WORDPRESS_URL` to the public site URL.

### Automatic installation

Before starting a fresh site, set these values in `.env`:

```dotenv
WORDPRESS_AUTO_INSTALL=true
WORDPRESS_URL=http://localhost:8083
WORDPRESS_TITLE='My WordPress site'
WORDPRESS_ADMIN_USER=site_admin
WORDPRESS_ADMIN_EMAIL=admin@example.com
WORDPRESS_ADMIN_PASSWORD='replace-with-your-own-admin-password'
```

Use your own administrator email and password. Run `docker compose up -d` to apply the settings.
The first startup installs WordPress before serving HTTP; check progress with
`docker compose logs --tail=100 wordpress`. Existing installed sites retain their settings and
administrator credentials. Missing parameters and non-empty uninstalled databases stop auto-install.

### Development and registries

For Xdebug, set `APP_ENV=dev` and `XDEBUG=true` in `.env`, then run `docker compose pull` and
`docker compose up -d`. Set `WORDPRESS_DEBUG=1` if needed. Configure your IDE to listen on port
`9003`; Xdebug connects to `host.docker.internal:9003`, so no FPM or debugger port mapping is needed.
The [main README](../README.md#working-on-your-own-plugin-or-theme) shows how to mount your own code.

The example uses Docker Hub. For GHCR, prefix its WordPress `image` with `ghcr.io/`.
Set `IMAGE_TAG` to `latest` or a published commit SHA. To fetch a newer image, run
`docker compose pull` followed by `docker compose up -d`. The site and database volumes are retained;
WordPress core in an existing site volume is preserved rather than replaced from the image.

## Site lifecycle

On the first HTTP-service startup, the entrypoint copies the prepared core into `/var/www/html` and
creates `wp-config.php`. Existing core and configuration are preserved. Existing theme/plugin
directories are preserved when populating a new site's core. A visibly incomplete
core (only one of `index.php` and `wp-includes/version.php` exists) fails startup instead of being overwritten.

With `WORDPRESS_AUTO_INSTALL=false` (the default), complete the web installer or install the site
explicitly with WP-CLI:

```bash
docker compose exec --user www-data wordpress wp core install \
    --url=http://localhost:8083 --title='My site' --admin_user=admin \
    --admin_email=admin@example.com --prompt=admin_password --skip-email
```

Set `WORDPRESS_AUTO_INSTALL=true` to install a fresh site before starting the HTTP processes.
Supply `WORDPRESS_URL`, `WORDPRESS_TITLE`, `WORDPRESS_ADMIN_USER`, `WORDPRESS_ADMIN_EMAIL` and
`WORDPRESS_ADMIN_PASSWORD` at runtime; `_FILE` counterparts are supported. Secret files must be
readable by the account that uses them. The published-image example passes the plain variables;
use your project's secret mounts and `_FILE` variables to pass credentials as files.

Auto-install waits up to 120 seconds for database connectivity. An already installed site is preserved
without resetting administrator credentials or site settings. A non-empty database without a recognized
WordPress installation fails startup, as do missing installation parameters. No installation email is sent.
Initialize each site from one container when using multiple replicas.

The core rewrite rules live in the Apache vhost, so the image needs no seeded `.htaccess` file.
Existing per-site `.htaccess` files remain supported, and WP-CLI can regenerate them when requested.

Cron and plugin provisioning wait for the site to be installed. Provisioning reuses the existing
`WORDPRESS_PLUGINS` behavior, including its default plugin cleanup. Cron runs as the FPM user.
`DISABLE_WP_CRON` is enabled through the image's default `WORDPRESS_CONFIG_EXTRA`.
If you override that variable, include `define('DISABLE_WP_CRON', true);` to retain one cron runner.

Fresh installations receive the [initial comment/registration settings](../README.md#defaults-for-new-installations)
once through WP-CLI. Existing installations and subsequent administrator changes are preserved.
The [nightly Doctor event](../README.md#nightly-wp-doctor) runs all standard checks at 03:00 in the
site timezone and appends its output and exit code to `wp-content/wp-doctor.log`.
This log is stored in the site volume and cannot be downloaded through Apache.

The configuration reads `WORDPRESS_DB_*`, `WORDPRESS_TABLE_PREFIX`, `WORDPRESS_DEBUG`, salt/key
variables and `WORDPRESS_CONFIG_EXTRA` at runtime. Their `_FILE` counterparts are supported for secrets.
Generated salts persist in `wp-config.php`. An existing custom configuration is not regenerated.

Updating the image does not update core files already present in the site volume. Core/plugin updates
and any `wp core update-db` operation need a separate deployment procedure and an appropriate backup.
Credentials must be supplied at runtime; do not bake them into the image.

## Runtime checks and resources

`PHP_FPM_MAX_CHILDREN` defaults to **2** and accepts a positive integer. PHP retains the existing
512 MB per-request memory limit. Choose concurrency using actual process memory and the container's
total budget, including Apache, OPcache and cron. Two workers do not guarantee fitting within 1 GB.
`WP_CRON_INTERVAL` defaults to 60 seconds. Keep one cron runner per site when using multiple replicas.

FPM listens on `/run/php/wordpress.sock`. The HTTP healthcheck requests the local-only FPM ping endpoint
through Apache; it fails if either Apache or FPM is unavailable. It does not verify database readiness
or completed WordPress installation. PHP errors go to stderr; Apache logs default to stdout/stderr.

Supervisor stops Apache gracefully before stopping FPM. Allow at least 70 seconds for container
shutdown, as in the provided Compose file. The image expects root for startup/provisioning and runs
Apache/FPM request workers as `www-data` by default. `APACHE_RUN_USER` and `APACHE_RUN_GROUP` set
the shared worker identity; the selected users/groups must exist in the image.

## Local source builds

For changes to the image itself, run these commands from the repository root:

```bash
docker build --build-arg APP_ENV=prod -t wordpress-apache-fpm:prod .docker/apache-fpm
docker build --build-arg APP_ENV=dev -t wordpress-apache-fpm:dev .docker/apache-fpm
```

PHP is pinned to the 8.3 branch and Debian Bookworm. WordPress defaults to **7.1.3**; override it
with `--build-arg WORDPRESS_VERSION=<release>`. WP-CLI downloads the versioned ZIP archive during
the build and verifies the extracted core against WordPress checksums. Startup needs no core download.
ZIP extraction avoids PHP PharData truncating long filenames in bundled libraries from the tar archive.
Both variants include WP-CLI 2.12.0, Doctor 2.3.1, Composer and the PHP extensions needed by WordPress.

The root `compose.apache-fpm.yaml` builds locally. Set `WORDPRESS_DB_PASSWORD` in your shell or local
`.env`, then run from the repository root:

```bash
docker compose -f compose.apache-fpm.yaml up --build -d
```

That source-build setup uses `FPM_WORDPRESS_PORT` (default `8083`) and a separate Compose project,
site volume and database volume. Run its WP-CLI commands with
`docker compose -f compose.apache-fpm.yaml exec ...`. For published images, use the standalone
example above, which uses `WORDPRESS_PORT` and `docker compose exec ...`.

The CI workflow reuses `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` and `GITHUB_TOKEN` for registry login
and builds dev/prod for `linux/amd64` and `linux/arm64/v8`.

## Smoke test

Requires Docker, Bash, curl and Python 3. Run against locally built images; each invocation creates and removes its own test containers,
network and volumes. Existing projects are not used:

```bash
bash tests/docker/apache-fpm.sh wordpress-apache-fpm:prod true false
bash tests/docker/apache-fpm.sh wordpress-apache-fpm:prod false false true
bash tests/docker/apache-fpm.sh wordpress-apache-fpm:dev false false
bash tests/docker/apache-fpm.sh wordpress-apache-fpm:dev true true
```

The fourth argument enables the auto-install scenario, including `_FILE` credentials, preservation of
installed sites and rejection of missing parameters or non-empty uninstalled databases.
The test covers core checksums, required extensions, Apache's MPM, HTTP via FPM, runtime environment,
Authorization forwarding, web installer availability, installation via WP-CLI, permalinks without
`.htaccess`, REST, cron execution, persistence after restart, Xdebug loading, FPM failure detection
and normal shutdown. It sends no installation email.
