# WordPress Docker images

WordPress on PHP 8.3: Apache + mod_php or Apache + PHP-FPM.
Includes WP-CLI, Doctor, Composer, cron and plugin provisioning.
`dev` includes Xdebug; `prod` does not. MariaDB runs separately.

[Compose examples](examples/)

## Images

| Runtime | Development | Production |
|---|---|---|
| Apache + mod_php | `alexanderkulnyow/wordpress-dev` | `alexanderkulnyow/wordpress-prod` |
| Apache + PHP-FPM | `alexanderkulnyow/wordpress-apache-fpm-dev` | `alexanderkulnyow/wordpress-apache-fpm-prod` |

Available on Docker Hub and GHCR (`ghcr.io/` prefix), for amd64 and arm64.
The examples use Docker Hub. For GHCR, set the full `ghcr.io/alexanderkulnyow/...` image name in Compose.
Tags: `latest` or full commit SHA to pin a build.
[CI](.github/workflows/docker-build.yml) runs manually and pulls current base images. In GitHub, open
**Actions → Build and push Docker image → Run workflow**, select `main`, then click **Run workflow**
to publish. Runs from another branch only build the images.

## Quick start

Requires Docker with Compose V2. Choose an example:

- [Apache + mod_php](examples/apache/compose.yaml): http://localhost:8046
- [Apache + PHP-FPM](examples/apache-fpm/compose.yaml): http://localhost:8083

```bash
cd examples/apache # or examples/apache-fpm
cp .env.example .env
```

Set `WORDPRESS_DB_PASSWORD` in `.env`, then start:

```bash
docker compose config --quiet
docker compose pull
docker compose up -d
```

Open the site and complete the WordPress installer.
The examples use `prod`, bind HTTP to localhost and store the site and database in named volumes.
For another site, use a separate directory, `PROJECT_NAME` and port.
For public access, configure the HTTP binding or a reverse proxy.

## Settings

Edit the example's `.env`, then run `docker compose up -d`.

| Variable | Default / purpose |
|---|---|
| `APP_ENV` | `prod`; use `dev` for Xdebug |
| `IMAGE_TAG` | `latest`; use a full commit SHA to pin a build |
| `PROJECT_NAME` / `WORDPRESS_PORT` | Project name and host HTTP port |
| `WORDPRESS_DB_NAME` / `WORDPRESS_DB_USER` | `wordpress` |
| `WORDPRESS_DB_PASSWORD` | Required; quote passwords containing `$` or `#` with single quotes |
| `WORDPRESS_TABLE_PREFIX` / `WORDPRESS_DEBUG` | `wp_` / `0` |
| `WORDPRESS_PLUGINS` | Comma-separated slugs; empty installs no extra plugins |
| `WORDPRESS_UPLOADS_ORIGIN` | Empty (disabled); optional HTTP(S) origin for missing uploads |
| `WP_CRON_INTERVAL` | `60` seconds |
| `XDEBUG` | `false`; requires `APP_ENV=dev` |
| `WORDPRESS_MEM_LIMIT` / `WORDPRESS_CPUS` | `1g` / `2` |
| `DB_MEM_LIMIT` / `DB_CPUS` | `512m` / `1` |

Full templates: [mod_php](examples/apache/.env.example), [FPM](examples/apache-fpm/.env.example).
[FPM settings and auto-install](docs/apache-fpm.md) are documented separately.

For debugging, set `APP_ENV=dev`, `XDEBUG=true` and `WORDPRESS_DEBUG=1`, then pull and recreate.
Your IDE should listen on `9003`; Xdebug connects to `host.docker.internal:9003`.

### Remote media fallback for local development

Both Apache runtimes and their dev/prod images support this optional setting in `.env`:

```dotenv
WORDPRESS_UPLOADS_ORIGIN=https://aigenis.by
```

Run `docker compose up -d` to recreate this service with the new environment.
Set `WORDPRESS_UPLOADS_ORIGIN=` and run the same command to disable it.
A plain `docker compose restart` does not apply changed Compose environment variables.
The generated Apache configuration is replaced or removed on every container start;
site files, `wp-config.php`, volumes and `.htaccess` files are preserved. When enabled,
startup creates an empty uploads directory owned by the web user if it is absent;
existing directories retain their ownership.

Use an HTTP(S) origin with a hostname or IP and optional port, for example
`https://aigenis.by` or `http://media.example.test:8080`. A trailing `/` is accepted;
credentials, other paths, query strings and fragments are rejected at startup.
HTTPS verifies the upstream certificate chain, expiry and hostname using the container's CA store.
Point the origin at a separate upstream, never back at the local fallback service.

For `/wp-content/uploads/` Apache serves an existing local file or directory normally.
For a missing file it proxies **GET/HEAD** to the same path and query string on the origin.
Other methods for missing uploads return 404 locally. Other URL paths keep their usual behavior.
The browser uses the local URL; Apache streams the response, including HEAD, Range/206,
content type and upstream 404, without writing the media or a cache to disk.
Local Cookie and Authorization headers are stripped only for fallback requests;
upstream Set-Cookie is also removed. Forward proxying stays disabled, and existing
Apache access and execution restrictions still apply. No WordPress plugin is needed.

Remote files depend on the availability of the upstream and its access rules; an upstream
failure cannot be served from a local cache. Use the upstream's canonical origin to avoid
redirects; redirects to the configured uploads origin are rewritten to the local address.
Media URLs must point through the **local site**: absolute production URLs in existing content
bypass this fallback. Configure those URLs separately when preparing your local database.
New WordPress uploads remain local and take priority immediately. PHP image processing,
editing and regenerating old thumbnails still require the **original file on local disk**.
Custom Apache aliases, rewrites or handlers inside uploads may need their own review;
the fallback uses the standard `/var/www/html/wp-content/uploads` directory.

### Working on your own plugin or theme

Add `compose.override.yaml` next to the example's `compose.yaml`:

```yaml
services:
    wordpress:
        volumes:
            - ./themes/my-theme:/var/www/html/wp-content/themes/my-theme
```

For a plugin, mount it under `/var/www/html/wp-content/plugins/` instead.
Run `docker compose up -d`, then activate it in WordPress.
The directory must be writable by the editor and container web user; `UID` / `GID` do not remap that user.

## Commands and updates

Run from the example's directory:

```bash
docker compose logs --tail=100 wordpress
docker compose exec wordpress wp plugin list --allow-root
docker compose exec wordpress supervisorctl -c /etc/supervisor/supervisord.conf status
docker compose stop
```

Update the WordPress service image:

```bash
docker compose pull wordpress
docker compose up -d --no-deps wordpress
docker compose exec wordpress php -v
```

`latest` does not update running containers automatically. Pull downloads the image; `up` recreates the service when it changes.
Site and database volumes remain. Existing WordPress core, plugins and themes require their own updates and backups.
`docker compose down --volumes`, `make kill` and `make restart` delete named volumes.

## Startup and cron

Supervisor runs Apache, cron and provisioning; the FPM image also runs PHP-FPM.
Keep the image's default entrypoint and command so these services start.
Existing WordPress core and configuration are preserved.

On each start, provisioning waits for WordPress installation, then installs missing `WORDPRESS_PLUGINS`.
It also deactivates and **deletes `akismet`, `hello` and `wps-hide-login`**, even with an empty plugin list.
The selected plugins and existing upgrade directories receive the web user's ownership.
`wp-provision` exiting after completion is normal.

Cron runs `wp cron event run --due-now` every `WP_CRON_INTERVAL` seconds as the web user.
Keep `define('DISABLE_WP_CRON', true);` in `wp-config.php` to avoid a second, HTTP-triggered runner.
The examples supply this setting; retain it when overriding `WORDPRESS_CONFIG_EXTRA`.

### Defaults for new installations

New sites start with comments closed and user registration disabled.
Existing sites retain their settings; administrators can change these defaults later.

### Nightly WP Doctor

Provisioning schedules `wordpress_docker_doctor` for **03:00 in the WordPress timezone**, once per day.
The event runs `wp doctor check --all`; overdue events run when cron resumes.
Both image variants pin WP-CLI `2.12.0` and Doctor `2.3.0`. Doctor `2.3.1` calls
`WP_CLI\Path`, which is unavailable in WP-CLI `2.12.0`, and crashes when a cache flush is detected.
Startup installs the runtime MU-plugin and creates `wp-content/wp-doctor.log`.
The log contains output, timestamps and exit codes, independently of `WP_DEBUG_LOG`; HTTP access is denied.

```bash
docker compose exec wordpress tail -n 100 wp-content/wp-doctor.log
docker compose exec wordpress wp cron event list --hook=wordpress_docker_doctor --allow-root
```

## Build and test

Build from the repository root. `--pull` fetches current base images, including PHP 8.3 patch releases:

```bash
docker build --pull --build-arg APP_ENV=prod -t wordpress-local:prod .docker/apache
docker build --pull --build-arg APP_ENV=prod -t wordpress-fpm-local:prod .docker/apache-fpm
```

Use `APP_ENV=dev` for Xdebug. Dockerfiles default to `prod`.
The root [mod_php](docker-compose.yaml) and [FPM](compose.apache-fpm.yaml) Compose files build locally and default to `dev`.
For mod_php, configure the root `.env`:

```dotenv
PROJECT_NAME=wordpress
WORDPRESS_PORT=8046
WORDPRESS_DB_HOST=database
WORDPRESS_DB_NAME=wordpress
WORDPRESS_DB_USER=wordpress
WORDPRESS_DB_PASSWORD='replace-with-your-own-password'
WORDPRESS_TABLE_PREFIX=wp_
```

```bash
docker compose -f docker-compose.yaml up --build -d
# FPM uses the same DB password; other settings have defaults:
docker compose -f compose.apache-fpm.yaml up --build -d
```

Choose one stack and keep its `-f` option for subsequent commands.
The root mod_php stack exposes MariaDB on `3306` and installs `contact-form-7` unless `WORDPRESS_PLUGINS` is explicitly empty.

Run [integration checks](tests/docker/all.sh) for mod_php/FPM × dev/prod:

```bash
bash tests/docker/all.sh
```

Requires Docker, Bash, curl and Python 3. Uses isolated test containers and volumes.
Checks installation, cron, Doctor, persistence, log mounts, uploads fallback and Xdebug; FPM also checks auto-install and failure detection.

The isolated [uploads checks](tests/docker/uploads-origin.sh) also run independently:

```bash
bash tests/docker/uploads-origin.sh wordpress-local:prod apache
bash tests/docker/uploads-origin.sh wordpress-fpm-local:prod apache-fpm
```

They use a controlled HTTP/HTTPS origin from the tested image, without contacting production.
They cover local priority, media responses, credentials, methods/paths, access restrictions,
HEAD/Range, 404, no downloads, certificate verification, validation and restart enable/disable.
The common initialization helper is mirrored across the standalone build contexts, like the
existing runtime scripts; `all.sh` checks that its two copies are identical.

Apache references: [proxy rewrite flag](https://httpd.apache.org/docs/2.4/rewrite/flags.html#flag_p),
[late header processing](https://httpd.apache.org/docs/2.4/mod/mod_headers.html#early)
and [upstream TLS verification](https://httpd.apache.org/docs/2.4/mod/mod_ssl.html#sslproxyverify).
