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
touch storage/logs/laravel.log

if grep -qE '^DB_CONNECTION=sqlite' .env 2>/dev/null || ! grep -qE '^DB_CONNECTION=' .env 2>/dev/null; then
    if [ ! -f database/database.sqlite ]; then
        echo "Creating SQLite database..."
        touch database/database.sqlite
    fi
fi

if grep -qE '^APP_KEY=$|^APP_KEY=\s*$' .env; then
    echo "Generating application key..."
    php artisan key:generate --force
fi

php artisan config:clear || true
CACHE_STORE=file php artisan cache:clear || true

echo "Running migrations..."
php artisan migrate --force --no-interaction || true

# Must run AFTER artisan — artisan runs as root and recreates files as root
chown -R www-data:www-data storage bootstrap/cache database .env
chmod -R 775 storage bootstrap/cache database
chmod 664 database/database.sqlite 2>/dev/null || true
chmod 664 storage/logs/laravel.log 2>/dev/null || true

php-fpm -D
exec nginx -g "daemon off;"
