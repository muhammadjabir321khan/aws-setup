#!/bin/bash
set -e

cd /var/www

echo "Starting local development environment..."

if [ ! -f ".env" ]; then
    echo "Creating .env from .env.example..."
    cp .env.example .env
    sed -i 's|^APP_URL=.*|APP_URL=http://localhost:8000|' .env
    sed -i 's|^# DB_CONNECTION=sqlite|DB_CONNECTION=mysql|' .env
    sed -i 's|^# DB_HOST=.*|DB_HOST=database|' .env
    sed -i 's|^# DB_PORT=.*|DB_PORT=3306|' .env
    sed -i 's|^# DB_DATABASE=.*|DB_DATABASE=awssetup|' .env
    sed -i 's|^# DB_USERNAME=.*|DB_USERNAME=admin|' .env
    sed -i 's|^# DB_PASSWORD=.*|DB_PASSWORD=jabir321|' .env
fi

fix_permissions() {
    mkdir -p storage/framework/{cache/data,sessions,views} storage/logs storage/app/public bootstrap/cache
    touch storage/logs/laravel.log
    chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true
    find storage bootstrap/cache -type d -exec chmod 775 {} \; 2>/dev/null || true
    find storage bootstrap/cache -type f -exec chmod 664 {} \; 2>/dev/null || true
}

fix_permissions

# Start web stack immediately — Docker maps :8000 before setup finishes.
php-fpm -D
nginx

if [ ! -f "vendor/autoload.php" ]; then
    echo "Installing Composer dependencies..."
    composer install --no-progress --no-interaction
fi

if grep -q '^APP_KEY=$' .env || grep -q '^APP_KEY=\s*$' .env; then
    echo "Generating application key..."
    php artisan key:generate --force
fi

echo "Waiting for database..."
until php -r "
    try {
        new PDO(
            'mysql:host=${DB_HOST:-database};port=${DB_PORT:-3306}',
            '${DB_USERNAME:-admin}',
            '${DB_PASSWORD:-jabir321}'
        );
        exit(0);
    } catch (Exception \$e) {
        exit(1);
    }
" 2>/dev/null; do
    sleep 2
done
echo "Database is ready."

php artisan config:clear || true
rm -f bootstrap/cache/config.php
CACHE_STORE=file php artisan cache:clear || true

echo "Running migrations..."
php artisan migrate --force --no-interaction || true

fix_permissions

# nginx runs as a background daemon; keep container alive in foreground
exec tail -f /var/log/nginx/access.log /var/log/nginx/error.log 2>/dev/null || exec sleep infinity
