FROM php:apache-buster

# app version, set with docker build --build-arg version=v0.0.2
ARG version=main

RUN apt-get update

# 1. development packages
RUN apt-get install -y \
    git \
    zip \
    pkg-config \
    libcurl4-openssl-dev \
    curl \
    wget \
    sudo \
    unzip \
    libicu-dev \
    libbz2-dev \
    libpng-dev \
    libjpeg-dev \
    libmcrypt-dev \
    libreadline-dev \
    libfreetype6-dev \
    libssl-dev \
    g++ \
    supervisor \
   && apt-get clean \
   && rm -rf /var/lib/apt/lists/*

# 2. apache configs + document root
ENV APACHE_DOCUMENT_ROOT=/var/www/html/public
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf
RUN sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf
RUN sed -i 's/Require local/#Require local/g' /etc/apache2/mods-available/status.conf
RUN sed -i '/^<\/VirtualHost>/i AllowEncodedSlashes NoDecode' /etc/apache2/sites-available/*.conf

# 3. mod_rewrite for URL rewrite and mod_headers for .htaccess extra headers like Access-Control-Allow-Origin-
RUN a2enmod rewrite headers

# 4. start with base php config, then add extensions
RUN mv "$PHP_INI_DIR/php.ini-development" "$PHP_INI_DIR/php.ini"

RUN docker-php-ext-install \
    pdo_mysql \
    exif \
    sockets

# 4.1 install a third-party extension
RUN pecl install mongodb \
    && docker-php-ext-enable mongodb \
    && echo "extension=mongodb.so" >> "$PHP_INI_DIR/php.ini"

# 5. composer
ENV COMPOSER_HOME /composer
ENV PATH ./vendor/bin:/composer/vendor/bin:$PATH
ENV COMPOSER_ALLOW_SUPERUSER 1
RUN curl -s https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin/ --filename=composer

# so when we execute CLI commands, all the host file's ownership remains intact
# otherwise command from inside container will create root-owned files and directories
ARG uid
RUN useradd -G www-data,root -u 1000 -d /home/devuser devuser
RUN mkdir -p /home/devuser/.composer && \
    chown -R devuser:devuser /home/devuser

#RUN cd /var/www/html && wget https://github.com/prosanteconnect/psc-api-maj/archive/$version.tar.gz && \
#    tar -xzf $version.tar.gz --strip 1 && rm $version.tar.gz
COPY . /var/www/html/

# Setup working directory
WORKDIR /var/www/html

# Install dependencies
RUN composer install --optimize-autoloader --no-dev

RUN composer dump-autoload

# Configure Supervisor
SHELL ["/bin/bash", "-c"]

RUN echo $'[program:default]\n\
process_name=%(program_name)s\n\
command=php /var/www/html/artisan queue:work --sleep=3 --tries=3\n\
autostart=true\n\
autorestart=true\n\
numprocs=1\n\
redirect_stderr=true\n\
logfile=/dev/stdout\n\
stopwaitsecs=3600' > /etc/supervisor/conf.d/default.conf

RUN sed -i '/^exec.*/i mv \/secrets\/.env \/var\/www\/html\/.env' /usr/local/bin/apache2-foreground

# DANGER ZONE: DB migration on startup
RUN sed -i '/^exec.*/i php artisan migrate --force' /usr/local/bin/apache2-foreground

RUN sed -i '/^exec.*/i service supervisor start' /usr/local/bin/apache2-foreground
