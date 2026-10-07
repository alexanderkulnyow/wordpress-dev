FROM composer:latest AS composer

FROM wordpress:latest

ARG APP_ENV=prod
ENV APP_ENV=${APP_ENV}

RUN echo "deb http://ftp.debian.org/debian $(sed -n 's/^VERSION=.*(\(.*\)).*/\1/p' /etc/os-release)-backports main" >> /etc/apt/sources.list \
&& apt-get update \
&& apt-get install -y --no-install-recommends \
        bash-completion \
        bindfs \
        ghostscript \
        less \
        libjpeg-dev \
        libmagickwand-dev \
        libpng-dev \
        libxml2-dev \
        libzip-dev \
        mariadb-client \
        sudo \
        supervisor \
        unzip \
        nano \
        htop \
        zip

    RUN curl -fsSL --retry 3 https://github.com/wp-cli/wp-cli/releases/download/v2.12.0/wp-cli-2.12.0.phar -o wp-cli.phar \
        && php wp-cli.phar --info --allow-root \
        && chmod +x wp-cli.phar \
        && mv wp-cli.phar /usr/local/bin/wp \
        && sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf \
        && echo 'ServerName localhost' > /etc/apache2/conf-available/fqdn.conf \
        && a2enconf fqdn \
        && a2enmod rewrite expires

    COPY --chmod=0755 bin/ /usr/local/bin/

    COPY --chmod=0644 supervisor/wordpress.conf /etc/supervisor/conf.d/wordpress.conf

    COPY php.d /usr/local/etc/php/conf.d/

    COPY --from=composer /usr/bin/composer /usr/bin/composer

    # Install a tagged archive without GitHub API version discovery. Keep the path repository in the image.
    RUN mkdir -p /usr/local/share/wp-cli/doctor-command \
        && curl -fsSL --retry 3 https://codeload.github.com/wp-cli/doctor-command/tar.gz/refs/tags/v2.3.1 -o /tmp/doctor-command.tar.gz \
        && tar -xzf /tmp/doctor-command.tar.gz --strip-components=1 -C /usr/local/share/wp-cli/doctor-command \
        && php -r '$path = "/usr/local/share/wp-cli/doctor-command/composer.json"; $package = json_decode(file_get_contents($path), true, 512, JSON_THROW_ON_ERROR); $package["version"] = "2.3.1"; file_put_contents($path, json_encode($package, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . PHP_EOL);' \
        && wp package install /usr/local/share/wp-cli/doctor-command --allow-root \
        && rm /tmp/doctor-command.tar.gz

    COPY --chmod=0755 wp-cli/wpcli /usr/local/share/wordpress/commands/

    RUN sed -i 's/\r$//' /usr/local/share/wordpress/commands/wpcli

    RUN if [ "$APP_ENV" = "dev" ]; then \
        pecl install "xdebug" \
            && docker-php-ext-enable xdebug \
            && sed -i 's/\r$//' /usr/local/bin/phpdxdebug \
            && phpdxdebug \
            && echo "Xdebug installed"; \
        else \
            echo "Production build, Xdebug disabled"; \
        fi

WORKDIR /var/www/html

ENTRYPOINT ["phpdxdebug", "docker-entrypoint.sh"]

# Name starts with "apache2" on purpose: the base image's docker-entrypoint.sh only runs its
# wp-config.php/WORDPRESS_* setup when $1 matches "apache2*", before exec'ing into this wrapper.
CMD ["apache2-foreground-supervised"]
