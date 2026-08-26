#!/bin/bash
set -e

cd /var/www

# Update or append a key in .env
set_env_file() {
    local key="$1"
    local value="$2"
    if [ -f .env ] && grep -qE "^${key}=" .env; then
        # Escape sed replacement specials in value
        local escaped
        escaped=$(printf '%s' "$value" | sed -e 's/[&|\\]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${escaped}|" .env
    else
        echo "${key}=${value}" >> .env
    fi
}

# Prefer process env (ECS task), else existing .env, else default
env_get() {
    local key="$1"
    local default="${2-}"
    local val="${!key-}"
    if [ -n "$val" ]; then
        printf '%s' "$val"
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

    # Create log file if missing so open(append) does not fail on create perms
    touch storage/logs/laravel.log

    # PHP-FPM runs as www-data (see docker/php/php-fpm.conf)
    chown -R www-data:www-data storage bootstrap/cache
    chmod -R 777 storage bootstrap/cache
}

# Run Artisan as www-data so new files are not left root-owned
run_as_www() {
    if command -v runuser >/dev/null 2>&1; then
        runuser -u www-data -- "$@"
    else
        su -s /bin/sh -c 'exec "$@"' www-data -- "$@"
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

fix_permissions

# Start web stack early so ECS health checks don't get empty responses during boot
php-fpm -D
nginx

# www-data must be able to update .env (key:generate) and write storage
chown www-data:www-data .env 2>/dev/null || true
chmod 664 .env 2>/dev/null || true

# --- Force MySQL (never sqlite) into .env so php-fpm/Laravel cannot fall back ---
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

# Remove sqlite default line if commented remnants cause confusion
sed -i '/^# DB_CONNECTION=sqlite/d' .env 2>/dev/null || true
rm -f database/database.sqlite

echo "Database driver: $(grep -E '^DB_CONNECTION=' .env)"
echo "Database host: $(grep -E '^DB_HOST=' .env)"

export DB_CONNECTION="$DB_CONNECTION_VAL"
export DB_HOST="$DB_HOST_VAL"
export DB_PORT="$DB_PORT_VAL"
export DB_DATABASE="$DB_DATABASE_VAL"
export DB_USERNAME="$DB_USERNAME_VAL"
export DB_PASSWORD="$DB_PASSWORD_VAL"
export MYSQL_ATTR_SSL_CA="$MYSQL_SSL_CA_VAL"

if grep -qE '^APP_KEY=$|^APP_KEY=\s*$' .env; then
    echo "Generating application key..."
    run_as_www php artisan key:generate --force || true
fi

if [ ! -f /var/www/global-bundle.pem ]; then
    echo "Downloading RDS CA bundle..."
    curl -fsSL -o /var/www/global-bundle.pem \
        https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem || true
fi

echo "Waiting for MySQL at ${DB_HOST}:${DB_PORT}..."
for i in $(seq 1 30); do
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

# Drop any cached config that might still say sqlite
run_as_www php artisan config:clear || true
rm -f bootstrap/cache/config.php
run_as_www env CACHE_STORE=file php artisan cache:clear || true

echo "Running migrations..."
run_as_www php artisan migrate --force --no-interaction || true

# Re-apply after any root-owned files from earlier steps
fix_permissions
chown www-data:www-data .env 2>/dev/null || true

exec tail -f /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null || exec sleep infinity
