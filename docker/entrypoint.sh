#!/bin/bash
set -e

cd /var/www

if [ ! -f "vendor/autoload.php" ]; then
    echo "Installing composer dependencies..."
    composer install --no-progress --no-interaction --optimize-autoloader --no-dev
fi

if [ ! -f ".env" ]; then
    echo "Creating .env file..."
    cp .env.example .env
fi

mkdir -p storage/framework/{cache/data,sessions,views} storage/logs storage/app/public bootstrap/cache database
chown -R www-data:www-data storage bootstrap/cache database
chmod -R 775 storage bootstrap/cache database

if grep -qE '^APP_KEY=$|^APP_KEY=\s*$' .env; then
    echo "Generating application key..."
    php artisan key:generate --force
fi

# Default .env uses sqlite — create the file if missing
if grep -qE '^DB_CONNECTION=sqlite' .env; then
    if [ ! -f database/database.sqlite ]; then
        echo "Creating SQLite database..."
        touch database/database.sqlite
        chown www-data:www-data database/database.sqlite
        chmod 664 database/database.sqlite
    fi
fi

php artisan config:clear || true
CACHE_STORE=file php artisan cache:clear || true

echo "Running migrations..."
php artisan migrate --force --no-interaction || true

php-fpm -D
exec nginx -g "daemon off;"
