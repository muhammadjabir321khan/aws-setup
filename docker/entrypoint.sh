#!/bin/bash
set -e

cd /var/www

set_env_file() {
    local key="$1"
    local value="$2"
    if [ -f .env ] && grep -qE "^${key}=" .env; then
        local escaped
        escaped=$(printf '%s' "$value" | sed -e 's/[&|\\]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${escaped}|" .env
    else
        echo "${key}=${value}" >> .env
    fi
}

env_get() {
    local key="$1"
    local default="${2-}"
    # Prefer real process environment (ECS task env)
    if [ -n "${!key+x}" ] && [ -n "${!key}" ]; then
        printf '%s' "${!key}"
        return
    fi
    if [ -f .env ]; then
        local from_file
        from_file=$(grep -E "^${key}=" .env | tail -1 | cut -d= -f2- || true)
        if [ -n "$from_file" ]; then
            printf '%s' "$from_file"
            return
        fi
    fi
    printf '%s' "$default"
}

fix_permissions() {
    mkdir -p \
        storage/framework/cache/data \
        storage/framework/sessions \
        storage/framework/views \
        storage/logs \
        storage/app/public \
        bootstrap/cache

    touch storage/logs/laravel.log
    chown -R www-data:www-data storage bootstrap/cache
    chmod -R 777 storage bootstrap/cache
}

# Preserve env so DB_PASSWORD from ECS reaches artisan
run_as_www() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u www-data --preserve-environment -- "$@"
    else
        su --preserve-environment -s /bin/sh -c 'exec "$@"' www-data -- "$@"
    fi
}

configure_env() {
    DB_CONNECTION_VAL="$(env_get DB_CONNECTION mysql)"
    if [ "$DB_CONNECTION_VAL" = "sqlite" ] || [ -z "$DB_CONNECTION_VAL" ]; then
        DB_CONNECTION_VAL="mysql"
    fi

    DB_HOST_VAL="$(env_get DB_HOST aws-setup.cn8iisiiszd1.eu-north-1.rds.amazonaws.com)"
    DB_PORT_VAL="$(env_get DB_PORT 3306)"
    DB_DATABASE_VAL="$(env_get DB_DATABASE awsapp)"
    DB_USERNAME_VAL="$(env_get DB_USERNAME admin)"
    DB_PASSWORD_VAL="$(env_get DB_PASSWORD)"
    MYSQL_SSL_CA_VAL="$(env_get MYSQL_ATTR_SSL_CA /var/www/global-bundle.pem)"

    set_env_file DB_CONNECTION "$DB_CONNECTION_VAL"
    set_env_file DB_HOST "$DB_HOST_VAL"
    set_env_file DB_PORT "$DB_PORT_VAL"
    set_env_file DB_DATABASE "$DB_DATABASE_VAL"
    set_env_file DB_USERNAME "$DB_USERNAME_VAL"
    set_env_file DB_PASSWORD "$DB_PASSWORD_VAL"
    set_env_file MYSQL_ATTR_SSL_CA "$MYSQL_SSL_CA_VAL"
    set_env_file APP_ENV "$(env_get APP_ENV production)"
    set_env_file APP_DEBUG "$(env_get APP_DEBUG false)"
    set_env_file LOG_CHANNEL "$(env_get LOG_CHANNEL stderr)"
    set_env_file LOG_STACK "$(env_get LOG_STACK stderr)"

    APP_URL_VAL="$(env_get APP_URL http://localhost:8000)"
    set_env_file APP_URL "$APP_URL_VAL"
    set_env_file ASSET_URL "$(env_get ASSET_URL "$APP_URL_VAL")"

    sed -i '/^# DB_CONNECTION=sqlite/d' .env 2>/dev/null || true
    sed -i '/^DB_CONNECTION=sqlite/d' .env 2>/dev/null || true
    # Never keep a cached config with an empty password baked in
    rm -f database/database.sqlite bootstrap/cache/config.php

    export DB_CONNECTION="$DB_CONNECTION_VAL"
    export DB_HOST="$DB_HOST_VAL"
    export DB_PORT="$DB_PORT_VAL"
    export DB_DATABASE="$DB_DATABASE_VAL"
    export DB_USERNAME="$DB_USERNAME_VAL"
    export DB_PASSWORD="$DB_PASSWORD_VAL"
    export MYSQL_ATTR_SSL_CA="$MYSQL_SSL_CA_VAL"
    export LOG_CHANNEL="stderr"
    export LOG_STACK="stderr"

    echo "Database driver: DB_CONNECTION=${DB_CONNECTION_VAL}"
    echo "Database host: DB_HOST=${DB_HOST_VAL}"
    echo "Database name: DB_DATABASE=${DB_DATABASE_VAL}"
    echo "Database user: DB_USERNAME=${DB_USERNAME_VAL}"
    echo "App URL: APP_URL=${APP_URL_VAL}"
    if [ -n "$DB_PASSWORD_VAL" ]; then
        echo "Database password: SET (length=${#DB_PASSWORD_VAL})"
    else
        echo "ERROR: DB_PASSWORD is EMPTY."
        echo "Set DB_PASSWORD in ECS Task Definition -> Container -> Environment variables,"
        echo "create a new revision, update the service to that revision, Force new deployment."
    fi
}

if [ ! -f "vendor/autoload.php" ]; then
    echo "Installing composer dependencies..."
    composer install --no-progress --no-interaction --optimize-autoloader --no-dev
fi

if [ ! -f ".env" ]; then
    echo "Creating .env file..."
    cp .env.example .env
fi

# Configure MySQL BEFORE starting php-fpm
configure_env
fix_permissions
chown www-data:www-data .env 2>/dev/null || true
chmod 664 .env 2>/dev/null || true

# Do NOT config:cache — it freezes empty DB_PASSWORD when ECS env is missing.
# Runtime env() + .env must stay live so ECS task env vars work.
php artisan config:clear || true
rm -f bootstrap/cache/config.php

if grep -qE '^APP_KEY=$|^APP_KEY=\s*$' .env; then
    echo "Generating application key..."
    php artisan key:generate --force || true
fi

if [ ! -f /var/www/global-bundle.pem ]; then
    echo "Downloading RDS CA bundle..."
    curl -fsSL -o /var/www/global-bundle.pem \
        https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem || true
fi

php-fpm -D
nginx

echo "Waiting for MySQL at ${DB_HOST}:${DB_PORT}..."
for i in $(seq 1 30); do
    if [ -z "$DB_PASSWORD" ]; then
        echo "Skipping MySQL wait: DB_PASSWORD is empty"
        break
    fi
    if php -r "
        try {
            \$opts = [];
            \$ca = getenv('MYSQL_ATTR_SSL_CA');
            if (\$ca && file_exists(\$ca)) {
                \$opts[PDO::MYSQL_ATTR_SSL_CA] = \$ca;
            }
            new PDO(
                sprintf('mysql:host=%s;port=%s', getenv('DB_HOST'), getenv('DB_PORT') ?: '3306'),
                getenv('DB_USERNAME') ?: '',
                getenv('DB_PASSWORD') ?: '',
                \$opts
            );
            exit(0);
        } catch (Throwable \$e) {
            fwrite(STDERR, \$e->getMessage() . PHP_EOL);
            exit(1);
        }
    "; then
        echo "MySQL is ready."
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "Warning: MySQL not reachable yet; continuing anyway."
    fi
    sleep 2
done

if [ -n "$DB_PASSWORD" ]; then
    CACHE_STORE=file php artisan cache:clear || true
    echo "Running migrations..."
    php artisan migrate --force --no-interaction || true
fi

fix_permissions

exec tail -f /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null || exec sleep infinity
