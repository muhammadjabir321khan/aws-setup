param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "help", "setup", "install", "env", "build", "up", "down",
        "restart", "logs", "shell", "wait-db", "composer", "key",
        "migrate", "fresh", "seed", "assets", "test", "clean"
    )]
    [string]$Command = "setup"
)

$ErrorActionPreference = "Stop"
$Compose = "docker", "compose", "-f", "docker-compose.local.yml"
$AppUrl = "http://127.0.0.1:8000"

function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & docker compose -f docker-compose.local.yml @Args
    if ($LASTEXITCODE -ne 0) { throw "docker compose failed with exit code $LASTEXITCODE" }
}

function Invoke-Php {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
    & docker compose -f docker-compose.local.yml exec -T php @Args
    if ($LASTEXITCODE -ne 0) { throw "php command failed with exit code $LASTEXITCODE" }
}

function Show-Help {
    Write-Host ""
    Write-Host "  AWS-setup local development (PowerShell)"
    Write-Host ""
    Write-Host "  Usage: .\setup.ps1 [command]"
    Write-Host ""
    Write-Host "  setup      First-time local setup (default)"
    Write-Host "  env        Create .env with Docker-friendly defaults"
    Write-Host "  build      Build Docker images"
    Write-Host "  up         Start containers"
    Write-Host "  down       Stop containers"
    Write-Host "  restart    Restart containers"
    Write-Host "  logs       Tail container logs"
    Write-Host "  shell      Open a shell in the PHP container"
    Write-Host "  composer   Install PHP dependencies"
    Write-Host "  key        Generate application key"
    Write-Host "  migrate    Run database migrations"
    Write-Host "  fresh      Drop all tables and re-run migrations"
    Write-Host "  seed       Seed the database"
    Write-Host "  assets     Install and build frontend assets"
    Write-Host "  test       Run PHPUnit/Pest tests"
    Write-Host "  clean      Stop containers and remove volumes"
    Write-Host ""
}

function Ensure-Env {
    if (Test-Path ".env") {
        Write-Host ".env already exists"
        return
    }

    Copy-Item ".env.example" ".env"
    $content = Get-Content ".env" -Raw
    $content = $content -replace '(?m)^APP_URL=.*', 'APP_URL=http://localhost:8000'
    $content = $content -replace '(?m)^# DB_CONNECTION=sqlite', 'DB_CONNECTION=mysql'
    $content = $content -replace '(?m)^# DB_HOST=.*', 'DB_HOST=database'
    $content = $content -replace '(?m)^# DB_PORT=.*', 'DB_PORT=3306'
    $content = $content -replace '(?m)^# DB_DATABASE=.*', 'DB_DATABASE=aws-setup'
    $content = $content -replace '(?m)^# DB_USERNAME=.*', 'DB_USERNAME=aws-setup'
    $content = $content -replace '(?m)^# DB_PASSWORD=.*', 'DB_PASSWORD=aws-123'
    Set-Content -Path ".env" -Value $content -NoNewline
    Write-Host "Created .env"
}

function Wait-Database {
    Write-Host "Waiting for database..."
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        & docker compose -f docker-compose.local.yml exec -T database mysqladmin ping -h localhost --silent 2>$null
        if ($LASTEXITCODE -eq 0) {
            $ready = $true
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw "Database did not become ready in time." }
    Write-Host "Database is ready."
}

function Invoke-Setup {
    Ensure-Env
    Invoke-Compose build
    Invoke-Compose up -d
    Wait-Database
    Invoke-Php composer install --no-interaction --optimize-autoloader
    Invoke-Php php artisan key:generate --force
    Invoke-Php php artisan migrate --force
    npm ci
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed" }
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "npm run build failed" }
    Write-Host ""
    Write-Host "  Setup complete."
    Write-Host "  App: $AppUrl"
    Write-Host ""
}

switch ($Command) {
    "help"     { Show-Help }
    "setup"    { Invoke-Setup }
    "install"  { Invoke-Setup }
    "env"      { Ensure-Env }
    "build"    { Invoke-Compose build }
    "up"       { Invoke-Compose up -d }
    "down"     { Invoke-Compose down }
    "restart"  { Invoke-Compose down; Invoke-Compose up -d }
    "logs"     { & docker compose -f docker-compose.local.yml logs -f }
    "shell"    { & docker compose -f docker-compose.local.yml exec php bash }
    "wait-db"  { Wait-Database }
    "composer" { Invoke-Php composer install --no-interaction --optimize-autoloader }
    "key"      { Invoke-Php php artisan key:generate --force }
    "migrate"  { Invoke-Php php artisan migrate --force }
    "fresh"    { Invoke-Php php artisan migrate:fresh --force }
    "seed"     { Invoke-Php php artisan db:seed --force }
    "assets"   { npm ci; if ($LASTEXITCODE -ne 0) { throw "npm ci failed" }; npm run build }
    "test"     { Invoke-Php php artisan test }
    "clean"    { Invoke-Compose down -v }
}
