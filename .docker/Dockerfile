FROM composer:latest as composer

FROM wordpress:latest

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

RUN pecl install "xdebug" \
    && docker-php-ext-enable xdebug \
    && { \
        echo 'memory_limit = 512M'; \
        echo 'upload_max_filesize = 50M'; \
        echo 'post_max_size = 100M'; \
        echo 'max_input_vars=2000'; \
    } > /usr/local/etc/php/php.ini \
    && { \
        echo 'opcache.memory_consumption = 128'; \
        echo 'opcache.interned_strings_buffer = 8'; \
        echo 'opcache.max_accelerated_files = 4000'; \
        echo 'opcache.revalidate_freq = 2'; \
        echo 'opcache.fast_shutdown = 1'; \
        echo 'opcache.enable_cli = 1'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini \
    && sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf \
    && echo 'ServerName localhost' > /etc/apache2/conf-available/fqdn.conf \
    && { \
        echo "zend_extension=$(find /usr/local/lib/php/extensions/ -name xdebug.so)"; \
        echo "xdebug.mode=develop,debug"; \
        echo "xdebug.client_host=host.docker.internal"; \
        echo "xdebug.remote_enable=1"; \
        echo "xdebug.idekey=PHPSTORM"; \
    } > /usr/local/etc/php/conf.d/xdebug.ini


RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && php wp-cli.phar --info --allow-root \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp \
    && a2enconf fqdn \
    && a2enmod rewrite expires

COPY --from=composer /usr/bin/composer /usr/bin/composer

EXPOSE 9003
