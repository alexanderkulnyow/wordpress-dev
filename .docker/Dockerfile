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
        unzip \
        nano \
        htop \
        zip

    RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        && php wp-cli.phar --info --allow-root \
        && chmod +x wp-cli.phar \
        && mv wp-cli.phar /usr/local/bin/wp \
        && sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf \
        && echo 'ServerName localhost' > /etc/apache2/conf-available/fqdn.conf \
        && a2enconf fqdn \
        && a2enmod rewrite expires

    COPY --chmod=0755 bin/ /usr/local/bin/

    COPY php.d /usr/local/etc/php/conf.d/

    COPY --from=composer /usr/bin/composer /usr/bin/composer

	RUN wp package install wp-cli/doctor-command:@stable --allow-root

    COPY --chmod=0755 wp-cli/wpcli /var/www/html/commands/

    COPY --chmod=0755 plugins /var/www/html/commands/plugins/

  	RUN sed -i 's/\r$//' /var/www/html/commands/wpcli

    RUN if [ "$APP_ENV" = "dev" ]; then \
        pecl install "xdebug" \
            && docker-php-ext-enable xdebug \
            && sed -i 's/\r$//' /usr/local/bin/phpdxdebug \
            && phpdxdebug \
            && echo "Xdebug enabled"; \
        else \
            echo "Production build, Xdebug disabled"; \
        fi

WORKDIR /var/www/html
