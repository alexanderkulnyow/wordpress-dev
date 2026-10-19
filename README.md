# WordPress Docker images

Two WordPress runtimes: **Apache + mod_php** and **Apache + PHP-FPM 8.3**.
Each has a `dev` image with Xdebug and a `prod` image without it. Both include
WP-CLI 2.12.0, Doctor 2.3.1, Composer, scheduled cron and plugin provisioning.
MariaDB runs in a separate container.

## Choose an image

| Runtime | Development | Production | Build context |
|---|---|---|---|
| Apache + mod_php | `alexanderkulnyow/wordpress-dev` | `alexanderkulnyow/wordpress-prod` | [`.docker/apache`](.docker/apache/Dockerfile) |
| Apache + PHP-FPM 8.3 | `alexanderkulnyow/wordpress-apache-fpm-dev` | `alexanderkulnyow/wordpress-apache-fpm-prod` | [`.docker/apache-fpm`](.docker/apache-fpm/Dockerfile) |

The mod_php image extends `wordpress:php8.3-apache`. The FPM image uses
`php:8.3-fpm-bookworm`, Apache event MPM and a Unix socket between Apache and FPM;
WordPress is downloaded and verified during the build.

Both runtimes stay on PHP 8.3. Dependabot ignores minor and major version
updates for these base image tags. New builds can pick up PHP 8.3 patch releases
from the upstream tags; changing the PHP branch requires a manual change.

The [CI workflow](.github/workflows/docker-build.yml) builds all four images for
amd64 and arm64. Pushes to `main` publish to Docker Hub and GHCR with `latest`
and full commit SHA tags; pull requests only build. GHCR names have the prefix
`ghcr.io/`, for example `ghcr.io/alexanderkulnyow/wordpress-apache-fpm-prod:latest`.

## Quick start: use a published image

Requires Docker Engine or Docker Desktop with `docker compose`.

Choose one example. Its Compose file contains `image` without `build`, so no
Dockerfile or local image build is needed:

| Runtime | Compose file | Environment template | Default URL |
|---|---|---|---|
| Apache + mod_php | [examples/apache/compose.yaml](examples/apache/compose.yaml) | [.env.example](examples/apache/.env.example) | http://localhost:8046 |
| Apache + PHP-FPM | [examples/apache-fpm/compose.yaml](examples/apache-fpm/compose.yaml) | [.env.example](examples/apache-fpm/.env.example) | http://localhost:8083 |

From a checkout, choose **one** directory:

```bash
cd examples/apache
# Or: cd examples/apache-fpm
cp .env.example .env
```

You can also copy the selected `compose.yaml` and `.env.example` to a separate
directory and run there. Edit `.env`: set your own `WORDPRESS_DB_PASSWORD`,
project name and HTTP port. The defaults select `prod` with Xdebug disabled.

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
```

Open the URL from the table and complete the WordPress web installer.
FPM also supports [automatic installation](docs/apache-fpm.md#automatic-installation).

Both examples bind HTTP to localhost, keep MariaDB inside the Compose network,
and store the full site and database in named volumes. For another site, use a
separate directory, a different `PROJECT_NAME` and a free `WORDPRESS_PORT`.
For a public deployment, configure the HTTP binding or a reverse proxy.

## Configure an image

The following settings apply to the published-image examples. Change `.env`,
then run `docker compose up -d` to recreate containers with the new settings.

| Variable | Default | Purpose |
|---|---|---|
| `APP_ENV` | `prod` | Selects the `dev` or `prod` image. |
| `IMAGE_REGISTRY` | `docker.io` | Registry: `docker.io` or `ghcr.io`. |
| `IMAGE_TAG` | `latest` | Image tag; a published full commit SHA pins a specific build. |
| `PROJECT_NAME` | `my-wordpress-apache` / `my-wordpress-apache-fpm` | Prefix for Compose resources. |
| `WORDPRESS_PORT` | `8046` / `8083` | Host HTTP port for mod_php / FPM. |
| `WORDPRESS_DB_NAME` / `WORDPRESS_DB_USER` | `wordpress` | Database and application database user. |
| `WORDPRESS_DB_PASSWORD` | Required | Database user's password; set before starting. |
| `WORDPRESS_TABLE_PREFIX` | `wp_` | WordPress table prefix. |
| `WORDPRESS_DEBUG` | `0` | Set `1` for WordPress debug mode. |
| `WORDPRESS_PLUGINS` | Empty | Comma-separated plugin slugs to install and activate on startup. |
| `WP_CRON_INTERVAL` | `60` | Seconds between scheduled WP-CLI cron runs. |
| `XDEBUG` | `false` | Load Xdebug on startup; requires the `dev` image. |
| `WORDPRESS_MEM_LIMIT` / `WORDPRESS_CPUS` | `1g` / `2` | WordPress container resource limits. |
| `DB_MEM_LIMIT` / `DB_CPUS` | `512m` / `1` | MariaDB container resource limits. |

Use single quotes around passwords containing literal `$` or `#` in `.env`.
FPM-specific settings, including `PHP_FPM_MAX_CHILDREN` (default `2`),
`WORDPRESS_AUTO_INSTALL` (default `false`) and administrator credentials, are
documented in the [FPM guide](docs/apache-fpm.md).

### Local debugging

Set these values in the example's `.env`:

```dotenv
APP_ENV=dev
XDEBUG=true
WORDPRESS_DEBUG=1
```

Then run `docker compose pull` and `docker compose up -d`. Configure your IDE to
listen on port `9003`: Xdebug connects to `host.docker.internal:9003`.
Publishing the container's port `9003` is unnecessary. Setting `XDEBUG=true`
on a `prod` image does not install the extension.

### Working on your own plugin or theme

Add `compose.override.yaml` alongside the example's `compose.yaml` to mount
your code. For a theme:

```yaml
services:
    wordpress:
        volumes:
            - ./themes/my-theme:/var/www/html/wp-content/themes/my-theme
```

For a plugin, use `./plugins/my-plugin:/var/www/html/wp-content/plugins/my-plugin`.
Run `docker compose up -d`, then activate it in WordPress or with WP-CLI.
The host directory must be writable by your editor and the container's web user.
`UID` / `GID` variables do not remap the container user.

## Daily commands and updates

Run from the selected example's directory:

```bash
docker compose logs --tail=100 wordpress
docker compose exec wordpress wp core version --allow-root
docker compose exec wordpress wp plugin list --allow-root
docker compose exec wordpress supervisorctl -c /etc/supervisor/supervisord.conf status
docker compose stop
docker compose up -d
```

To fetch and apply a newer image, run `docker compose pull` followed by
`docker compose up -d`. Existing site and database volumes are retained.
Existing WordPress core in the site volume is preserved: core, plugin, theme
and database updates need a separate update procedure and backup.

`docker compose down` removes containers and the network while retaining named
volumes. **Adding `--volumes` deletes the stored site and database.**

## Startup, plugins and cron

Supervisor manages Apache, scheduled cron and plugin provisioning; the FPM
image also runs PHP-FPM. First boot populates the site directory and generates
`wp-config.php`. Existing core and configuration are preserved. The FPM
[lifecycle guide](docs/apache-fpm.md#site-lifecycle) describes its additional checks.

Cron and plugin provisioning wait until WordPress is installed. Provisioning
installs and activates `WORDPRESS_PLUGINS`, removes `akismet` / `hello`, and
deactivates `wps-hide-login`. An empty plugin list skips extra installations;
the default cleanup still runs. Selected plugin files and existing upgrade
work directories are assigned to the web user/group when provisioning runs as root.

Provisioning runs once per container start. `wp-provision` reaching an expected
`EXITED` state is normal. To run it manually:

```bash
# Apache + mod_php
docker compose exec wordpress bash /usr/local/share/wordpress/commands/wpcli
# Apache + PHP-FPM
docker compose exec wordpress wp-plugin-provision
```

Scheduled cron runs `wp cron event run --due-now` every `WP_CRON_INTERVAL` seconds.
The Apache Compose files and the FPM image default disable WordPress's HTTP-triggered
cron with `define('DISABLE_WP_CRON', true);`. Retain that setting if overriding
`WORDPRESS_CONFIG_EXTRA`; when running the mod_php image directly, supply it yourself.

### Defaults for new installations

After a fresh WordPress installation, provisioning uses WP-CLI to set
`default_comment_status=closed` and `users_can_register=0`. You can change these
later in **Settings → Discussion** and **Settings → General**. Existing posts
keep their individual comment settings.

An installation hook marks new sites, including web-installer and WP-CLI
installations. The marker is removed after the settings are applied. Existing
sites have no marker and retain their settings; container restarts and image
updates do not reset administrator changes.

### Nightly WP Doctor

Provisioning schedules the `wordpress_docker_doctor` WordPress cron event for
**03:00 in the site's timezone**. It runs once per day through the existing
`wp-cron` worker, including on existing sites. Timezone changes reschedule the
event; restarts retain its schedule. If the site is down overnight, WordPress
cron runs the overdue event when the worker returns.

The event executes `wp doctor check --all` with Doctor's bundled standard
configuration. The full output, timestamps and exit code are appended to
**`wp-content/wp-doctor.log`**, independently of `WP_DEBUG_LOG`. Doctor findings
are logged without stopping the cron worker. Apache denies HTTP access to this
file in both image variants.

Startup prepares this log for the web user without changing ownership of the
whole `wp-content` directory, including when it is a host bind-mount.
Read it from the container:

```bash
docker compose exec wordpress tail -n 100 wp-content/wp-doctor.log
```

Both runtimes install the image-managed
`wp-content/mu-plugins/wordpress-docker-runtime.php` before serving WordPress.
It supplies the installation marker and Doctor callback. Cron runs as the web
user, with Doctor's WP-CLI package available outside the site volume.

## Build and run from source

Use the root Compose files when changing the images themselves:

| Runtime | Compose file | Default HTTP port | Site and database storage |
|---|---|---|---|
| Apache + mod_php | [docker-compose.yaml](docker-compose.yaml) | `WORDPRESS_PORT` from root `.env` | Site volume, `./wp-content`, `./var/log`; DB in `.docker/dbData` |
| Apache + PHP-FPM | [compose.apache-fpm.yaml](compose.apache-fpm.yaml) | `FPM_WORDPRESS_PORT=8083` | Separate site and DB volumes in a project suffixed `-apache-fpm` |

Both files define `image` **and** `build`. `APP_ENV` defaults to `dev` and selects
both the image name and build argument. `IMAGE_REGISTRY` defaults to `docker.io`
and `IMAGE_TAG` to `latest`; local builds are tagged with that name. Use
`up --build` to build your local changes. For running published images, use
the standalone examples above.

For mod_php, set these values in the root `.env` to match your local setup:

```dotenv
PROJECT_NAME=wordpress
APP_ENV=dev
WORDPRESS_PORT=8046
WORDPRESS_DB_HOST=database
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD='replace-with-your-own-password'
WORDPRESS_TABLE_PREFIX=wp_
XDEBUG=false
```

```bash
docker compose -f docker-compose.yaml config --quiet
docker compose -f docker-compose.yaml up --build -d
```

This mod_php setup publishes MariaDB on host port `3306` and bind-mounts
`wp-content` for local editing. It defaults to installing `contact-form-7`
when `WORDPRESS_PLUGINS` is unset; explicitly empty disables extra installations.

For FPM, set `WORDPRESS_DB_PASSWORD` in the root `.env` or shell, then run:

```bash
docker compose -f compose.apache-fpm.yaml config --quiet
docker compose -f compose.apache-fpm.yaml up --build -d
```

Use the same `-f` option for subsequent commands against that stack.
FPM source builds accept `WORDPRESS_VERSION` (default `7.1.3`). For direct builds,
each Dockerfile uses its own directory as the build context:

```bash
docker build --build-arg APP_ENV=dev -t wordpress-local:dev .docker/apache
docker build --build-arg APP_ENV=dev -t wordpress-apache-fpm:dev .docker/apache-fpm
docker build --build-arg APP_ENV=prod -t wordpress-apache-fpm:prod .docker/apache-fpm
```

Dockerfiles default to `prod` when `APP_ENV` is omitted.
Run the [integration checks for all four images](tests/docker/all.sh) from the
repository root. Requires Docker, Bash, curl and Python 3:

```bash
bash tests/docker/all.sh
```

The script builds mod_php and FPM in both `dev` and `prod`, using local
`wordpress-smoke-*` image tags. Each scenario creates and removes its own test
containers, network and volumes; existing sites are not used. Checks cover
installation, permalinks, REST, cron, fresh-install defaults, existing-site
preservation, Doctor logging, persistence after restart, PHP runtime and Xdebug
enabled/disabled. FPM also checks auto-install and failure detection.
For individual FPM scenarios, see the [FPM guide](docs/apache-fpm.md#smoke-test).
There is no application test suite.

### Makefile

The Makefile targets use the root mod_php stack and the `docker-compose` command.
If only Compose V2 is installed, use `make DOCKER='docker compose' <target>`.

| Command | Effect |
|---|---|
| `make start` | Build and recreate the root stack. |
| `make stop` | Stop containers. |
| `make kill` / `make restart` | Remove volumes; restart then builds and starts again. Site volume data is deleted. |
| `make plugins` | Install and activate `wordpress-importer`. |
| `make postexport` / `make postimport` | Export/import `data/export/test.xml` with WP-CLI. |
| `make help` | List targets that have help comments. |

`make composer` references an undefined `COMPOSER` variable. `make style` /
`make blocks` require a frontend project absent from this repository.
