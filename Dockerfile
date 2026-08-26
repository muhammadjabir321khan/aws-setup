FROM php:8.2-fpm AS php

ENV PHP_OPCACHE_ENABLE=1
ENV PHP_OPCACHE_CLI=0
ENV PHP_OPCACHE_VALIDATE_TIMESTAMPS=0
ENV PHP_OPCACHE_REVALIDATE_FREQ=0

# Baked into the image — php-fpm/Laravel must not fall back to sqlite
ENV APP_ENV=production
ENV APP_DEBUG=false
ENV DB_CONNECTION=mysql
ENV DB_HOST=aws-setup.cn8iisiiszd1.eu-north-1.rds.amazonaws.com
ENV DB_PORT=3306
ENV DB_DATABASE=awssetup
ENV DB_USERNAME=admin
ENV MYSQL_ATTR_SSL_CA=/var/www/global-bundle.pem
ENV LOG_CHANNEL=stderr
ENV LOG_STACK=stderr
ENV LOG_LEVEL=error

RUN usermod -u 1000 www-data

RUN apt-get update && apt-get install -y \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    libzip-dev \
    libcurl4-openssl-dev \
    libicu-dev \
    zip \
    unzip \
    git \
    curl \
    nginx \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql bcmath gd zip curl intl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www

COPY docker/php/php.ini /usr/local/etc/php/conf.d/app.ini
COPY docker/php/php-fpm.conf /usr/local/etc/php-fpm.d/www.conf
COPY docker/nginx/nginx.config /etc/nginx/nginx.conf
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh \
    && chmod +x /usr/local/bin/entrypoint.sh

# Ensure php-fpm workers always see MySQL (not sqlite)
RUN printf '%s\n' \
    'env[APP_ENV] = $APP_ENV' \
    'env[APP_DEBUG] = $APP_DEBUG' \
    'env[DB_CONNECTION] = $DB_CONNECTION' \
    'env[DB_HOST] = $DB_HOST' \
    'env[DB_PORT] = $DB_PORT' \
    'env[DB_DATABASE] = $DB_DATABASE' \
    'env[DB_USERNAME] = $DB_USERNAME' \
    'env[DB_PASSWORD] = $DB_PASSWORD' \
    'env[MYSQL_ATTR_SSL_CA] = $MYSQL_ATTR_SSL_CA' \
    'env[LOG_CHANNEL] = $LOG_CHANNEL' \
    'env[LOG_STACK] = $LOG_STACK' \
    > /usr/local/etc/php-fpm.d/zz-docker-env.conf

COPY --from=composer:2.3.5 /usr/bin/composer /usr/bin/composer
COPY --chown=www-data:www-data . .

# Ensure Laravel writable dirs exist and are owned by PHP-FPM user (www-data).
# Note: docker-compose bind mounts (.:/var/www) override these at runtime —
# entrypoint.sh re-applies the same ownership on every container start.
RUN curl -fsSL -o /var/www/global-bundle.pem \
        https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
    && mkdir -p \
        storage/framework/cache/data \
        storage/framework/sessions \
        storage/framework/views \
        storage/logs \
        storage/app/public \
        bootstrap/cache \
        database \
    && touch storage/logs/laravel.log \
    && rm -f database/database.sqlite bootstrap/cache/config.php \
    && (php artisan config:clear || true) \
    && chown -R www-data:www-data storage bootstrap/cache \
    && find storage bootstrap/cache -type d -exec chmod 775 {} \; \
    && find storage bootstrap/cache -type f -exec chmod 664 {} \;

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
