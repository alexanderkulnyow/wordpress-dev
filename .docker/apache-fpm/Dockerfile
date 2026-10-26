FROM composer:latest AS composer

FROM php:8.3-fpm-bookworm

ARG WORDPRESS_VERSION=7.1.3
ARG WP_CLI_VERSION=2.12.0
ARG WP_DOCTOR_VERSION=2.3.0
ARG IMAGICK_VERSION=3.8.1
ENV WP_CLI_PACKAGES_DIR=/usr/local/share/wp-cli/packages

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apache2 bash-completion bindfs ghostscript less mariadb-client \
        sudo supervisor unzip nano htop zip \
        libavif-dev libfreetype6-dev libicu-dev libjpeg-dev \
        libmagickwand-dev libpng-dev libwebp-dev libzip-dev \
    && docker-php-ext-configure gd --with-avif --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j"$(nproc)" bcmath exif gd intl mysqli opcache zip \
    && pecl install "imagick-${IMAGICK_VERSION}" \
    && docker-php-ext-enable imagick \
    && rm -rf /var/lib/apt/lists/* \
    && a2dissite 000-default \
    && a2enmod mpm_event proxy proxy_fcgi rewrite expires headers \
    && mkdir -p /run/php \
    && ln -sf /dev/stdout /var/log/apache2/access.log \
    && ln -sf /dev/stderr /var/log/apache2/error.log

COPY --from=composer /usr/bin/composer /usr/bin/composer
COPY usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/

RUN curl -fsSL --retry 3 "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar" -o /usr/local/bin/wp \
    && chmod +x /usr/local/bin/wp \
    && wp --info --allow-root \
    && mkdir -p /usr/local/share/wp-cli/doctor-command \
    && curl -fsSL --retry 3 "https://codeload.github.com/wp-cli/doctor-command/tar.gz/refs/tags/v${WP_DOCTOR_VERSION}" -o /tmp/doctor-command.tar.gz \
    && tar -xzf /tmp/doctor-command.tar.gz --strip-components=1 -C /usr/local/share/wp-cli/doctor-command \
    && WP_DOCTOR_VERSION="$WP_DOCTOR_VERSION" php -r '$path = "/usr/local/share/wp-cli/doctor-command/composer.json"; $package = json_decode(file_get_contents($path), true, 512, JSON_THROW_ON_ERROR); $package["version"] = getenv("WP_DOCTOR_VERSION"); file_put_contents($path, json_encode($package, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . PHP_EOL);' \
    && for attempt in 1 2 3; do \
        wp package install /usr/local/share/wp-cli/doctor-command --allow-root && break; \
        if [ "$attempt" -eq 3 ]; then exit 1; fi; \
        sleep 5; \
    done \
    && rm /tmp/doctor-command.tar.gz

# ZIP avoids PharData truncating long paths in the tar archive's bundled libraries.
RUN case "$WORDPRESS_VERSION" in ''|latest|nightly) echo 'WORDPRESS_VERSION must be a release number.' >&2; exit 1 ;; esac \
    && wp core download "https://downloads.wordpress.org/release/wordpress-${WORDPRESS_VERSION}.zip" --path=/usr/src/wordpress --allow-root \
    && wp core verify-checksums --version="$WORDPRESS_VERSION" --path=/usr/src/wordpress --allow-root \
    && chown -R www-data:www-data /usr/src/wordpress

COPY --chmod=0755 bin/ /usr/local/bin/
COPY usr/local/share/ /usr/local/share/
COPY usr/local/etc/php-fpm.d/ /usr/local/etc/php-fpm.d/
COPY etc/apache2/ /etc/apache2/
COPY etc/supervisor/ /etc/supervisor/
RUN a2ensite wordpress

ARG APP_ENV=prod
ARG XDEBUG_VERSION=3.5.3
ENV APP_ENV=${APP_ENV} \
    WP_CLI_CONFIG_PATH=/usr/local/share/wordpress/wp-cli.yml \
    APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    PHP_FPM_USER=www-data \
    PHP_FPM_GROUP=www-data \
    PHP_FPM_MAX_CHILDREN=2 \
    WORDPRESS_AUTO_INSTALL=false \
    WORDPRESS_CONFIG_EXTRA="define('DISABLE_WP_CRON', true);"

RUN case "$APP_ENV" in \
        dev) pecl install "xdebug-${XDEBUG_VERSION}" \
            && docker-php-ext-enable xdebug \
            && phpdxdebug ;; \
        prod) ;; \
        *) echo 'APP_ENV must be dev or prod.' >&2; exit 1 ;; \
    esac

WORKDIR /var/www/html
VOLUME /var/www/html
EXPOSE 80
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=6s --start-period=30s --retries=3 CMD ["php-fpm-healthcheck"]
ENTRYPOINT ["phpdxdebug", "wordpress-entrypoint"]
CMD ["apache2-foreground-supervised"]
