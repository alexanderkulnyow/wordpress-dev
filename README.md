## Docker image for WordPress with a preconfigured dev/prod environment

A ready-to-run Docker image for WordPress: Apache + mod_php, wp-cli, `wp-cli/doctor-command`, Composer,
a real cron replacing WP's pseudo-cron, and env-var-driven plugin provisioning — all baked in, so the
only thing you add is a database.

Published as:

* [`alexanderkulnyow/wordpress-dev`](https://hub.docker.com/repository/docker/alexanderkulnyow/wordpress-dev/general) / `ghcr.io/alexanderkulnyow/wordpress-dev` — built with `APP_ENV=dev` (adds Xdebug)
* `alexanderkulnyow/wordpress-prod` / `ghcr.io/alexanderkulnyow/wordpress-prod` — built with `APP_ENV=prod` (no Xdebug)

Both tags are built from the same [`.docker/Dockerfile`](.docker/Dockerfile) by
[`.github/workflows/docker-build.yml`](.github/workflows/docker-build.yml) on every push/PR to `main`.

This repository's [`docker-compose.yaml`](docker-compose.yaml) + `.env` are **local dev tooling only**.
Production deployments pull the published `wordpress-prod` image directly into their own orchestration
(a different compose file, Kubernetes, etc.) — that part lives outside this repo. Runtime environment
variables apply wherever the image runs; ports, volumes and resource limits are configured in Compose
or your other orchestration tool.

## Quick start (local dev)

Prerequisites: Docker, Docker Compose.

```bash
# .env is already committed with working defaults — edit it if you need different ports/credentials
make start   # docker-compose up --build --remove-orphans --force-recreate --detach
```

Then open `http://localhost:${WORDPRESS_PORT}` (default `8046`) and run through the WordPress installer
if the attached database doesn't already have WordPress installed. Once installed, plugin provisioning
and real cron kick in automatically (see below) — no extra manual step needed.

`make stop` stops the containers, `make kill` stops and removes them plus volumes, `make restart` does
both. Run `make help` for the full list of targets.

## Run a published image with Docker Compose

Save this as `compose.yaml` alongside a `.env` file (example below). It uses the published image and
includes the database, plugin list, PHP debugging, cron, storage and resource settings:

```yaml
name: ${PROJECT_NAME:-wordpress-dev}

services:
    database:
        image: mariadb:10.11
        restart: unless-stopped
        environment:
            MARIADB_DATABASE: ${WORDPRESS_DB_NAME:-wordpress}
            MARIADB_USER: ${WORDPRESS_DB_USER:-wordpress}
            MARIADB_PASSWORD: ${WORDPRESS_DB_PASSWORD:?Set WORDPRESS_DB_PASSWORD in .env}
            MARIADB_RANDOM_ROOT_PASSWORD: "1"
        ports:
            - "127.0.0.1:${DB_PORT:-3306}:3306"
        volumes:
            - db-data:/var/lib/mysql
        networks:
            - wp-network
        mem_limit: ${DB_MEM_LIMIT:-512m}
        cpus: ${DB_CPUS:-1}

    wordpress:
        image: alexanderkulnyow/wordpress-${APP_ENV:-dev}:${IMAGE_TAG:-latest}
        restart: unless-stopped
        depends_on:
            - database
        ports:
            - "${WORDPRESS_PORT:-8046}:80"
        environment:
            WORDPRESS_DB_HOST: ${WORDPRESS_DB_HOST:-database}
            WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME:-wordpress}
            WORDPRESS_DB_USER: ${WORDPRESS_DB_USER:-wordpress}
            WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD:?Set WORDPRESS_DB_PASSWORD in .env}
            WORDPRESS_TABLE_PREFIX: ${WORDPRESS_TABLE_PREFIX:-wp_}
            WORDPRESS_DEBUG: ${WORDPRESS_DEBUG:-0}
            WORDPRESS_CONFIG_EXTRA: "${WORDPRESS_CONFIG_EXTRA:-define('DISABLE_WP_CRON', true);}"
            WORDPRESS_PLUGINS: ${WORDPRESS_PLUGINS-contact-form-7}
            WP_CRON_INTERVAL: ${WP_CRON_INTERVAL:-60}
            XDEBUG: ${XDEBUG:-false}
            APACHE_RUN_USER: ${APACHE_RUN_USER:-www-data}
            APACHE_RUN_GROUP: ${APACHE_RUN_GROUP:-www-data}
        volumes:
            - wp-data:/var/www/html
            - ./wp-content:/var/www/html/wp-content
            - ./var/log:/var/log/apache2
        extra_hosts:
            - "host.docker.internal:host-gateway"
        networks:
            - wp-network
        mem_limit: ${WORDPRESS_MEM_LIMIT:-1g}
        cpus: ${WORDPRESS_CPUS:-2}

volumes:
    db-data:
    wp-data:

networks:
    wp-network:
```

Set `APP_ENV=dev` for `wordpress-dev` or `APP_ENV=prod` for `wordpress-prod`. `IMAGE_TAG` can be `latest`
or a published commit SHA. To use GHCR, prefix the image name with `ghcr.io/`.

```bash
mkdir -p wp-content var/log
docker compose up -d
```

Open `http://localhost:8046` (or your `WORDPRESS_PORT`) and complete the WordPress installer. Keep
`DISABLE_WP_CRON` enabled if you customize `WORDPRESS_CONFIG_EXTRA`, so the built-in cron runner is
responsible for scheduled jobs.

For Xdebug, use the dev image, set `XDEBUG=true`, and configure your IDE to listen on port `9003`.
Xdebug initiates the connection to `host.docker.internal:9003`; the example exposes the HTTP port and
the local database port. See [Xdebug step debugging](https://xdebug.org/docs/step_debug#configure).

## Environment configuration

### `.env`

This file is **committed to the repo with working defaults** on purpose — the goal is "clone, `make
start`, done," not a secrets-management exercise. Treat the committed values as throwaway local dev
defaults, not real credentials; change `WORDPRESS_DB_PASSWORD` etc. if you need isolation from other
local projects.

Example values for the Compose file above; adjust them locally as needed:

```dotenv
PROJECT_NAME=wordpress-dev
APP_ENV=dev
IMAGE_TAG=latest
XDEBUG=true

###> wordpress ###
WORDPRESS_PORT=8046
DB_PORT=3306
WORDPRESS_DB_HOST=database
WORDPRESS_DB_NAME=dds
WORDPRESS_DB_USER=user
WORDPRESS_DB_PASSWORD=replace-with-local-password
WORDPRESS_TABLE_PREFIX=dds_
WORDPRESS_DEBUG=0
APACHE_RUN_USER=www-data
APACHE_RUN_GROUP=www-data

# Comma-separated plugin slugs to install on startup; an empty value installs no extra plugins
WORDPRESS_PLUGINS=contact-form-7, query-monitor
# Interval in seconds between wp-cron runs (replaces WP's HTTP-triggered pseudo-cron)
WP_CRON_INTERVAL=60

###> resource limits (Compose) ###
WORDPRESS_MEM_LIMIT=1g
WORDPRESS_CPUS=2
DB_MEM_LIMIT=512m
DB_CPUS=1
```

### Plugin configuration

Set `WORDPRESS_PLUGINS` in Compose or pass it to the container at runtime. Use comma-separated slugs;
changing the list does not require rebuilding the image:

```yaml
environment:
  WORDPRESS_PLUGINS: contact-form-7,query-monitor
```

This repo's Compose file defaults to `contact-form-7` only when the variable is unset. An explicitly
empty value installs no extra plugins. Outside Compose, an unset variable also installs no extra
plugins. Recreate the container to apply a changed environment value.

The provisioning script lives in `/usr/local/share/wordpress/commands`, outside the site data
directory, so mounting `/var/www/html` does not hide it.
When provisioning runs as root, it gives selected plugins and existing upgrade work directories to
the web-server user/group (`APACHE_RUN_USER` / `APACHE_RUN_GROUP`, default `www-data`) so WordPress can
update them. This also repairs ownership of selected plugins that are already installed.

## Environment variables reference

### Baked into the image (apply wherever the image runs — dev compose or prod)

| Variable | Default | Purpose |
|---|---|---|
| `WORDPRESS_DB_HOST` / `_USER` / `_PASSWORD` / `_NAME` | — | Standard official `wordpress` image variables; generate `wp-config.php` on first boot. |
| `WORDPRESS_TABLE_PREFIX` | `wp_` in the example | Prefix for WordPress database tables. |
| `WORDPRESS_CONFIG_EXTRA` | `define('DISABLE_WP_CRON', true);` (set in `docker-compose.yaml`) | Raw PHP appended to `wp-config.php`. Set this when running the image outside this repo's compose too, so WP's pseudo-cron stays off in favor of the real one below. |
| `WORDPRESS_DEBUG` | `0` in the example | Set `1` to enable WordPress debug mode; `0` disables it. |
| `WORDPRESS_PLUGINS` | _(empty; Compose defaults to `contact-form-7` when unset)_ | Comma-separated plugin slugs to install/activate on startup. Empty means no extra plugins. |
| `WP_CRON_INTERVAL` | `60` | Seconds between `wp cron event run --due-now` calls. |
| `XDEBUG` | `false` | `true` loads Xdebug when a `dev` container starts; `false` or unset leaves the extension unloaded. No-op in `prod`, where Xdebug isn't installed. |
| `APACHE_RUN_USER` / `APACHE_RUN_GROUP` | `www-data` | Apache worker user/group; root provisioning gives selected plugin files to this user/group. |
| `APP_ENV` (build-arg) | `prod` in Dockerfile; `dev` in repo Compose | Selects whether Xdebug is installed when building. Changing a running container's `APP_ENV` does not change its build variant. |

### Compose configuration

| Variable | Default | Purpose |
|---|---|---|
| `PROJECT_NAME` | `wordpress-dev` | Prefixes the network/volume/container names. |
| `APP_ENV` / `IMAGE_TAG` | `dev` / `latest` in the published-image example | Select the published dev/prod image and tag. Repo Compose uses `APP_ENV` as a build argument and doesn't use `IMAGE_TAG`. |
| `WORDPRESS_PORT` | `8046` | Host port mapped to the container's port 80. |
| `DB_PORT` | `3306` in the example | Database port on localhost. Repo Compose currently fixes this to `3306`. |
| `UID` / `GID` | `1000` / `1000` in the legacy `.env` | Currently unused by the repo's Compose file and image; they do not change file ownership. |
| `WORDPRESS_MEM_LIMIT` / `WORDPRESS_CPUS` | `1g` / `2` | `wordpress` container's memory/CPU cap (`mem_limit`/`cpus`). |
| `DB_MEM_LIMIT` / `DB_CPUS` | `512m` / `1` | `database` container's memory/CPU cap. |

## What's running inside the container

The image's `CMD` doesn't run bare Apache — it runs `supervisord`
([`.docker/supervisor/wordpress.conf`](.docker/supervisor/wordpress.conf)), managing three processes.
The `phpdxdebug` entrypoint applies `XDEBUG`, then runs the official `wordpress` base image's
`docker-entrypoint.sh` (which generates `wp-config.php` from the `WORDPRESS_*` vars and copies in
WordPress core on first boot) —
our `CMD` is literally named `apache2-foreground-supervised` so it still matches that entrypoint's
`apache2*` guard before taking over.

| Process | What it does |
|---|---|
| `apache2` | The actual web server (`apache2-foreground`). |
| `wp-cron` | Loops forever, running `wp cron event run --due-now` every `WP_CRON_INTERVAL` seconds — a real cron replacing WP's HTTP-triggered pseudo-cron (disabled via `WORDPRESS_CONFIG_EXTRA`). |
| `wp-provision` | One-shot: waits (polling every 5s) until `wp core is-installed` succeeds, then runs `.docker/wp-cli/wpcli` once — installs plugins from `WORDPRESS_PLUGINS`, removes `akismet`/`hello`, deactivates `wps-hide-login`. Idempotent — safe to let it run on every container start. |

`supervisorctl status` showing `wp-provision` as `EXITED ... expected` is the **normal, successful**
end state for that one-shot process, not a failure — `autorestart=false` is intentional so it doesn't
loop forever after it's done.

```bash
docker-compose exec wordpress supervisorctl -c /etc/supervisor/supervisord.conf status
```

## Makefile targets

Run `make help` for the authoritative list (parsed from the `##` comments). Notable ones:

* `make start` / `make stop` / `make kill` / `make restart` — lifecycle.
* `make plugins` — installs/activates `wordpress-importer` (independent of the automatic `WORDPRESS_PLUGINS` provisioning above).
* `make postexport` / `make postimport` — wp-cli export/import against `data/export/test.xml`.
* `make user` — creates a WordPress user via wp-cli (currently hardcoded to `admin`/`admin`, administrator role — **change the password before using this against anything but a disposable local site**).
* `docker-compose exec wordpress wp <command> --allow-root` — run arbitrary wp-cli commands directly.
* `docker-compose exec wordpress bash /usr/local/share/wordpress/commands/wpcli` — run the provisioning script manually (same thing `wp-provision` runs automatically).

Known broken targets (pre-existing, not specific to this doc): `make composer` references an undefined
`$(COMPOSER)` variable; `make style` / `make blocks` call `npm run ...` but there's no `package.json`
anywhere in this repo — both only make sense once a theme/plugin with its own frontend build is added
under `wp-content/`.

## Known limitations

* **`.docker/fpm.Dockerfile`** (php-fpm base variant) exists but isn't wired into `docker-compose.yaml`
  or the CI workflow — neither is built/published anywhere today. Treat it as a dormant starting point
  for a future nginx+fpm setup, not something currently in use in dev or prod.
* **WP-CLI is pinned to `2.12.0` and `wp-cli/doctor-command` to `2.3.1`** in both Dockerfiles.
  Doctor `2.3.1` is compatible with this stable WP-CLI release; newer Doctor releases require newer
  WP-CLI versions. Update these pins together. Doctor is installed from its tagged source archive
  as a local Composer path repository, avoiding GitHub API calls to discover Doctor versions.
* There is no test suite, linter, or composer project in this repo to run.
