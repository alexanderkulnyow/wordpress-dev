FROM composer:latest AS composer

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
    && sed -i 's/AllowOverride None/AllowOverride All/g' /etc/apache2/apache2.conf \
    && echo 'ServerName localhost' > /etc/apache2/conf-available/fqdn.conf


RUN curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    && php wp-cli.phar --info --allow-root \
    && chmod +x wp-cli.phar \
    && mv wp-cli.phar /usr/local/bin/wp \
    && a2enconf fqdn \
    && a2enmod rewrite expires

ADD php.d /usr/local/etc/php/conf.d/


COPY --from=composer /usr/bin/composer /usr/bin/composer

EXPOSE 9003
