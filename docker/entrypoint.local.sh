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
    sed -i 's|^# DB_DATABASE=.*|DB_DATABASE=aws-setup|' .env
    sed -i 's|^# DB_USERNAME=.*|DB_USERNAME=aws-setup|' .env
    sed -i 's|^# DB_PASSWORD=.*|DB_PASSWORD=aws-123|' .env
fi

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
            '${DB_USERNAME:-aws-setup}',
            '${DB_PASSWORD:-aws-123}'
        );
        exit(0);
    } catch (Exception \$e) {
        exit(1);
    }
" 2>/dev/null; do
    sleep 2
done
echo "Database is ready."

mkdir -p storage/framework/{cache/data,sessions,views} storage/logs bootstrap/cache
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true
chmod -R 775 storage bootstrap/cache 2>/dev/null || true

php artisan config:clear || true
# Use file cache for this boot step so missing DB cache tables do not spam errors.
CACHE_STORE=file php artisan cache:clear || true

php-fpm -D
exec nginx -g "daemon off;"
