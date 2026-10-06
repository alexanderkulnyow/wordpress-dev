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
(a different compose file, Kubernetes, etc.) — that part lives outside this repo. Everything described
below under "Baked into the image" applies there too, since it's part of the image itself; everything
under "Local dev compose" only applies when you run `docker-compose` from this repo.

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

## Example files needed to initialize the project

### `.env`

This file is **committed to the repo with working defaults** on purpose — the goal is "clone, `make
start`, done," not a secrets-management exercise. Treat the committed values as throwaway local dev
defaults, not real credentials; change `WORDPRESS_DB_PASSWORD` etc. if you need isolation from other
local projects.

This is the actual committed content — adjust it locally as needed, it doesn't need to stay in sync with this doc:

```dotenv
PROJECT_NAME=wordpress-dev
XDEBUG=true

###> wordpress ###
WORDPRESS_PORT=8046
WORDPRESS_DB_HOST=database
WORDPRESS_DB_NAME=dds
WORDPRESS_DB_USER=user
WORDPRESS_DB_PASSWORD=password
WORDPRESS_TABLE_PREFIX=dds_
UID=1000
GID=1000

# Comma-separated plugin slugs to install on startup (overrides .docker/plugins/plugins.txt when set)
WORDPRESS_PLUGINS=contact-form-7, query-monitor
# Interval in seconds between wp-cron runs (replaces WP's HTTP-triggered pseudo-cron)
WP_CRON_INTERVAL=60

###> resource limits (local dev compose only) ###
WORDPRESS_MEM_LIMIT=1g
WORDPRESS_CPUS=2
DB_MEM_LIMIT=512m
DB_CPUS=1
```

### `.docker/plugins/plugins.txt`

The plugin list baked into the image at **build time** (one slug per line), used as the fallback when
`WORDPRESS_PLUGINS` isn't set at runtime:

```
contact-form-7
```

The provisioning script and plugin list live in `/usr/local/share/wordpress/commands`, outside the
site data directory, so mounting `/var/www/html` does not hide them.
When provisioning runs as root, it gives selected plugins and existing upgrade work directories to
the web-server user/group (`APACHE_RUN_USER` / `APACHE_RUN_GROUP`, default `www-data`) so WordPress can
update them. This also repairs ownership of selected plugins that are already installed.

Don't confuse this with `.docker/wp-cli/plugins.txt` / `pluginsDev.txt` — those are stale, unused leftovers
in the same directory tree and aren't read by anything.

## Environment variables reference

### Baked into the image (apply wherever the image runs — dev compose or prod)

| Variable | Default | Purpose |
|---|---|---|
| `WORDPRESS_DB_HOST` / `_USER` / `_PASSWORD` / `_NAME` / `_TABLE_PREFIX` | — | Standard official `wordpress` image variables; generate `wp-config.php` on first boot. |
| `WORDPRESS_CONFIG_EXTRA` | `define('DISABLE_WP_CRON', true);` (set in `docker-compose.yaml`) | Raw PHP appended to `wp-config.php`. Set this when running the image outside this repo's compose too, so WP's pseudo-cron stays off in favor of the real one below. |
| `WORDPRESS_PLUGINS` | _(empty → falls back to `.docker/plugins/plugins.txt`)_ | Comma-separated plugin slugs to install/activate on startup. |
| `WP_CRON_INTERVAL` | `60` | Seconds between `wp cron event run --due-now` calls. |
| `XDEBUG` | `false` | `true` loads Xdebug when a `dev` container starts; `false` or unset leaves the extension unloaded. No-op in `prod`, where Xdebug isn't installed. |
| `APP_ENV` (build-arg, not runtime env) | `dev` | `dev` installs Xdebug at build time; `prod` doesn't. Set via `docker-compose.yaml`'s `build.args` or `--build-arg` directly. |

### Local dev compose only (`docker-compose.yaml` / `.env` in this repo)

| Variable | Default | Purpose |
|---|---|---|
| `PROJECT_NAME` | `wordpress-dev` | Prefixes the network/volume/container names. |
| `WORDPRESS_PORT` | `8046` | Host port mapped to the container's port 80. |
| `UID` / `GID` | `1000` / `1000` | Host user/group for file ownership (see `docker-compose.yaml`). |
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
| `wp-provision` | One-shot: waits (polling every 5s) until `wp core is-installed` succeeds, then runs `.docker/wp-cli/wpcli` once — installs `WORDPRESS_PLUGINS` (or the baked-in list), removes `akismet`/`hello`, deactivates `wps-hide-login`. Idempotent — safe to let it run on every container start. |

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
