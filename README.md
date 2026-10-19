# WordPress Docker images for development and deployment

Ready-to-run WordPress images with WP-CLI, `wp-cli/doctor-command`, Composer, scheduled cron and
plugin provisioning. Choose Apache + mod_php or Apache + PHP-FPM 8.3, then add a MariaDB database.

## Choose an image

| Runtime | Development (includes Xdebug) | Deployment (no Xdebug) |
|---|---|---|
| Apache + mod_php | `alexanderkulnyow/wordpress-dev` | `alexanderkulnyow/wordpress-prod` |
| Apache + PHP-FPM 8.3 | `alexanderkulnyow/wordpress-apache-fpm-dev` | `alexanderkulnyow/wordpress-apache-fpm-prod` |

All four images support amd64 and arm64. Use `latest` or a published commit SHA as the tag.
Docker Hub uses the names above; GHCR uses the same names prefixed with `ghcr.io/`.
CI builds on PRs to `main` and publishes on pushes to `main`.

## Run a published image with Docker Compose

Requires Docker Engine or Docker Desktop with the `docker compose` command. Choose one pair of files:

| Runtime | Compose file | Environment template | Default site URL |
|---|---|---|---|
| Apache + mod_php | [compose.yaml](examples/apache/compose.yaml) | [.env.example](examples/apache/.env.example) | http://localhost:8046 |
| Apache + PHP-FPM | [compose.yaml](examples/apache-fpm/compose.yaml) | [.env.example](examples/apache-fpm/.env.example) | http://localhost:8083 |

Download the selected `compose.yaml` and `.env.example` into a new directory, then run commands from
that directory. You can also copy them from a checkout of this repository. These examples pull
published images and need no Dockerfile or local build.

```bash
cp .env.example .env
```

Edit `.env` and set `WORDPRESS_DB_PASSWORD` to your own password, for example
`WORDPRESS_DB_PASSWORD='replace-with-your-own-password'`. The default selects the prod image with
Xdebug disabled. Then start the site:

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
```

Open the URL from the table and complete the WordPress web installer. Choose your site title,
administrator account and password there. Plugin provisioning and scheduled cron start once the
site is installed. For FPM auto-install and runtime settings, see the [FPM guide](docs/apache-fpm.md).

The examples keep both the database and the full site in named Docker volumes. They bind HTTP to
localhost and keep MariaDB inside the Compose network. For another site, use a separate directory,
a different `PROJECT_NAME` and a free `WORDPRESS_PORT`. For a remote deployment, configure the HTTP
binding or a reverse proxy for the site's public address.

### Complete Apache + mod_php example

Save this as `compose.yaml`. The downloadable [Apache example](examples/apache/compose.yaml) contains
the same configuration. The [FPM guide](docs/apache-fpm.md#run-a-published-image) includes a complete
Apache + PHP-FPM example.

```yaml
name: ${PROJECT_NAME:-my-wordpress-apache}

services:
    database:
        image: mariadb:10.11
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
        image: ${IMAGE_REGISTRY:-docker.io}/alexanderkulnyow/wordpress-${APP_ENV:-prod}:${IMAGE_TAG:-latest}
        restart: unless-stopped
        depends_on:
            database:
                condition: service_healthy
        ports:
            - "127.0.0.1:${WORDPRESS_PORT:-8046}:80"
        environment:
            WORDPRESS_DB_HOST: database
            WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME:-wordpress}
            WORDPRESS_DB_USER: ${WORDPRESS_DB_USER:-wordpress}
            WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD:?Set WORDPRESS_DB_PASSWORD in .env}
            WORDPRESS_TABLE_PREFIX: ${WORDPRESS_TABLE_PREFIX:-wp_}
            WORDPRESS_DEBUG: ${WORDPRESS_DEBUG:-0}
            WORDPRESS_CONFIG_EXTRA: "${WORDPRESS_CONFIG_EXTRA:-define('DISABLE_WP_CRON', true);}"
            WORDPRESS_PLUGINS: ${WORDPRESS_PLUGINS-}
            WP_CRON_INTERVAL: ${WP_CRON_INTERVAL:-60}
            XDEBUG: ${XDEBUG:-false}
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

### Environment configuration

Save this as `.env` alongside `compose.yaml`, and fill in the database password:

```dotenv
PROJECT_NAME=my-wordpress-apache
IMAGE_REGISTRY=docker.io
APP_ENV=prod
IMAGE_TAG=latest
WORDPRESS_PORT=8046

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

WORDPRESS_MEM_LIMIT=1g
WORDPRESS_CPUS=2
DB_MEM_LIMIT=512m
DB_CPUS=1
```

The FPM template has additional auto-install and worker settings. Use its
[.env.example](examples/apache-fpm/.env.example) with the FPM Compose file.
Compose reads `.env` for the values referenced in `compose.yaml`; see the
[Docker interpolation guide](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/).
Keep your filled `.env` local to your deployment.

### Development, registries and image updates

For local development, change these values in `.env`, then run `docker compose pull` and
`docker compose up -d`:

```dotenv
APP_ENV=dev
XDEBUG=true
WORDPRESS_DEBUG=1
WORDPRESS_PLUGINS=contact-form-7,query-monitor
```

`APP_ENV` selects the dev/prod image in these examples. Xdebug requires the dev image and
`XDEBUG=true`; configure your IDE to listen on port `9003`. The debugger connects to
`host.docker.internal:9003`, so no container port mapping for `9003` is needed. See
[Xdebug step debugging](https://xdebug.org/docs/step_debug#configure).

For GHCR, set `IMAGE_REGISTRY=ghcr.io`. For Docker Hub, use `IMAGE_REGISTRY=docker.io`.
Set `IMAGE_TAG` to `latest` or a commit SHA that has been published by CI. To fetch a newer image:

```bash
docker compose pull
docker compose up -d
```

These commands replace the containers and retain their named volumes. Updating an image preserves
existing WordPress core, configuration and content in the site volume. Update WordPress core,
plugins, themes and the WordPress database separately, with a backup.

### Working on your own plugin or theme

For development, add a `compose.override.yaml` beside the selected Compose file. For example,
to mount an existing theme from `./themes/my-theme`:

```yaml
services:
    wordpress:
        volumes:
            - ./themes/my-theme:/var/www/html/wp-content/themes/my-theme
```

For a plugin, use `./plugins/my-plugin:/var/www/html/wp-content/plugins/my-plugin` instead.
Run `docker compose up -d`, then activate the theme/plugin in WordPress or with WP-CLI.
Use a directory your editor and the container's `www-data` user can both write to; `UID`/`GID`
variables do not remap the container's user.

### Inspecting and stopping a site

Run these commands from the directory containing your Compose file:

```bash
docker compose logs --tail=100 wordpress
docker compose exec wordpress wp core version --allow-root
docker compose exec wordpress wp plugin list --allow-root
docker compose stop
```

Start it again with `docker compose up -d`. `docker compose down` removes the containers and network
while retaining the named volumes; adding `--volumes` also deletes the stored site and database.

### Plugin configuration

Set `WORDPRESS_PLUGINS` in Compose or pass it to the container at runtime. Use comma-separated slugs;
changing the list does not require rebuilding the image:

```yaml
environment:
  WORDPRESS_PLUGINS: contact-form-7,query-monitor
```

The published-image examples default to no extra plugins. An explicitly empty `WORDPRESS_PLUGINS`
value also installs no extra plugins. The repository's local Apache Compose file defaults to
`contact-form-7` when the variable is unset. Recreate the container to apply a changed environment value.

The provisioning script lives outside the site data directory, so mounting `/var/www/html` does not
hide it: `/usr/local/share/wordpress/commands/wpcli` in the Apache image and
`/usr/local/bin/wp-plugin-provision` in the FPM image.
When provisioning runs as root, it gives selected plugins and existing upgrade work directories to
the web-server user/group (`APACHE_RUN_USER` / `APACHE_RUN_GROUP`, default `www-data`) so WordPress can
update them. This also repairs ownership of selected plugins that are already installed.

## Environment variables reference

### Apache + mod_php runtime variables

For FPM-specific behavior, auto-install and worker settings, see the [FPM guide](docs/apache-fpm.md).

| Variable | Default | Purpose |
|---|---|---|
| `WORDPRESS_DB_HOST` / `_USER` / `_PASSWORD` / `_NAME` | — | Standard official `wordpress` image variables; generate `wp-config.php` on first boot. |
| `WORDPRESS_TABLE_PREFIX` | `wp_` in the example | Prefix for WordPress database tables. |
| `WORDPRESS_CONFIG_EXTRA` | `define('DISABLE_WP_CRON', true);` (set in the Apache Compose files) | Raw PHP appended to `wp-config.php`. Set this when running the image outside this repo's compose too, so WP's pseudo-cron stays off in favor of the real one below. |
| `WORDPRESS_DEBUG` | `0` in the example | Set `1` to enable WordPress debug mode; `0` disables it. |
| `WORDPRESS_PLUGINS` | Empty in the published-image examples | Comma-separated plugin slugs to install/activate on startup. Empty means no extra plugins. |
| `WP_CRON_INTERVAL` | `60` | Seconds between `wp cron event run --due-now` calls. |
| `XDEBUG` | `false` | `true` loads Xdebug when a `dev` container starts; `false` or unset leaves the extension unloaded. No-op in `prod`, where Xdebug isn't installed. |
| `APACHE_RUN_USER` / `APACHE_RUN_GROUP` | `www-data` | Apache worker user/group; root provisioning gives selected plugin files to this user/group. |
| `APP_ENV` (build-arg) | `prod` in Dockerfile; `dev` in repo Compose | Selects whether Xdebug is installed when building. Changing a running container's `APP_ENV` does not change its build variant. |

### Compose configuration

| Variable | Default | Purpose |
|---|---|---|
| `PROJECT_NAME` | `my-wordpress-apache` / `my-wordpress-apache-fpm` | Selects the Compose project and prefixes its network/volume/container names. |
| `APP_ENV` / `IMAGE_TAG` | `prod` / `latest` in the published-image examples | Select the published dev/prod image and tag. Repo Compose uses `APP_ENV` as a build argument and doesn't use `IMAGE_TAG`. |
| `IMAGE_REGISTRY` | `docker.io` | Selects Docker Hub or `ghcr.io` in the published-image examples. |
| `WORDPRESS_PORT` | `8046` (Apache) / `8083` (FPM) | HTTP port on localhost mapped to the container's port 80. The database has no published port in these examples. |
| `UID` / `GID` | `1000` / `1000` in the legacy `.env` | Currently unused by the repo's Compose file and image; they do not change file ownership. |
| `WORDPRESS_MEM_LIMIT` / `WORDPRESS_CPUS` | `1g` / `2` | `wordpress` container's memory/CPU cap (`mem_limit`/`cpus`). |
| `DB_MEM_LIMIT` / `DB_CPUS` | `512m` / `1` | `database` container's memory/CPU cap. |

## What's running inside the Apache + mod_php container

The image's `CMD` doesn't run bare Apache — it runs `supervisord`
([`.docker/apache/etc/supervisor/conf.d/wordpress.conf`](.docker/apache/etc/supervisor/conf.d/wordpress.conf)), managing three processes.
The `phpdxdebug` entrypoint applies `XDEBUG`, then runs the official `wordpress` base image's
`docker-entrypoint.sh` (which generates `wp-config.php` from the `WORDPRESS_*` vars and copies in
WordPress core on first boot) —
our `CMD` is literally named `apache2-foreground-supervised` so it still matches that entrypoint's
`apache2*` guard before taking over.

| Process | What it does |
|---|---|
| `apache2` | The actual web server (`apache2-foreground`). |
| `wp-cron` | Loops forever, running `wp cron event run --due-now` every `WP_CRON_INTERVAL` seconds — a real cron replacing WP's HTTP-triggered pseudo-cron (disabled via `WORDPRESS_CONFIG_EXTRA`). |
| `wp-provision` | One-shot: waits (polling every 5s) until `wp core is-installed` succeeds, then runs the baked-in plugin provisioning script once — installs plugins from `WORDPRESS_PLUGINS`, removes `akismet`/`hello`, deactivates `wps-hide-login`. Idempotent — safe to let it run on every container start. |

`supervisorctl status` showing `wp-provision` as `EXITED ... expected` is the **normal, successful**
end state for that one-shot process, not a failure — `autorestart=false` is intentional so it doesn't
loop forever after it's done.

```bash
docker compose exec wordpress supervisorctl -c /etc/supervisor/supervisord.conf status
```

## Building and running this repository locally

The root `docker-compose.yaml` and `compose.apache-fpm.yaml` build from source. The standalone
published-image examples above use their own `.env` and volumes.

Each image has its own build context:

* `.docker/apache/Dockerfile` — Apache + mod_php.
* `.docker/apache-fpm/Dockerfile` — Apache + PHP-FPM 8.3.

Build with `docker build .docker/apache` or `docker build .docker/apache-fpm`. Add
`--build-arg APP_ENV=dev` for Xdebug; the Dockerfiles default to `prod`.

For the root Apache Compose setup, adjust the local `.env` for your database settings and ports, then
run `make start`. For FPM, see [local source builds](docs/apache-fpm.md#local-source-builds).
The [Docker workflow](.github/workflows/docker-build.yml) builds both contexts for amd64 and arm64
and publishes each dev/prod variant. Docker integration checks live in `tests/docker/`.

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

* **The Apache + FPM variant** has its own build context in `.docker/apache-fpm` and separate
  published image names. The unused standalone FPM Dockerfile has been removed.
* **WP-CLI is pinned to `2.12.0` and `wp-cli/doctor-command` to `2.3.1`** in both variants.
  Doctor `2.3.1` is compatible with this stable WP-CLI release; newer Doctor releases require newer
  WP-CLI versions. Update these pins together. Doctor is installed from its tagged source archive
  as a local Composer path repository, avoiding GitHub API calls to discover Doctor versions.
* There is no application test suite, linter, or composer project. The new image has an isolated
  Docker integration check at `tests/docker/apache-fpm.sh`; see its [guide](docs/apache-fpm.md).
