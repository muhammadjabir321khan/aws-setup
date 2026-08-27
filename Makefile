.PHONY: help setup install env up down build restart logs shell composer migrate fresh seed assets key test clean \
	ecr-login prod-build prod-tag push

COMPOSE  := docker compose -f docker-compose.local.yml
PHP      := $(COMPOSE) exec -T php
APP_URL  := http://127.0.0.1:8000

# ECR / production image
AWS_REGION   ?= eu-north-1
AWS_ACCOUNT  ?= 161327178744
ECR_REPO     ?= laravel-app
IMAGE_NAME   ?= laravel-app
IMAGE_TAG    ?= latest
ECS_CLUSTER  ?= awsapp
ECS_SERVICE  ?= awsapp
ECR_REGISTRY := $(AWS_ACCOUNT).dkr.ecr.$(AWS_REGION).amazonaws.com
ECR_IMAGE    := $(ECR_REGISTRY)/$(ECR_REPO):$(IMAGE_TAG)

help: ## Show available commands
	@echo ""
	@echo "  AWS-setup"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Production push: make push"
	@echo "  Image: $(ECR_IMAGE)"
	@echo ""

setup: env build up wait-db composer key migrate assets ## First-time local setup (run once)
	@echo ""
	@echo "  Setup complete."
	@echo "  App: $(APP_URL)"
	@echo ""

install: setup ## Alias for setup

env: ## Create .env with Docker-friendly defaults
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		sed -i 's|^APP_URL=.*|APP_URL=http://localhost:8000|' .env; \
		sed -i 's|^# DB_CONNECTION=sqlite|DB_CONNECTION=mysql|' .env; \
		sed -i 's|^# DB_HOST=.*|DB_HOST=database|' .env; \
		sed -i 's|^# DB_PORT=.*|DB_PORT=3306|' .env; \
		sed -i 's|^# DB_DATABASE=.*|DB_DATABASE=aws-setup|' .env; \
		sed -i 's|^# DB_USERNAME=.*|DB_USERNAME=aws-setup|' .env; \
		sed -i 's|^# DB_PASSWORD=.*|DB_PASSWORD=aws-123|' .env; \
		echo "Created .env"; \
	else \
		echo ".env already exists"; \
	fi

build: ## Build Docker images
	$(COMPOSE) build

up: ## Start containers
	$(COMPOSE) up -d

down: ## Stop containers
	$(COMPOSE) down

restart: down up ## Restart containers

logs: ## Tail container logs
	$(COMPOSE) logs -f

shell: ## Open a shell in the PHP container
	$(COMPOSE) exec php bash

wait-db: ## Wait until MySQL is ready
	@echo "Waiting for database..."
	@until $(COMPOSE) exec -T database mysqladmin ping -h localhost --silent 2>/dev/null; do sleep 2; done
	@echo "Database is ready."

composer: ## Install PHP dependencies
	$(PHP) composer install --no-interaction --optimize-autoloader

key: ## Generate application key
	$(PHP) php artisan key:generate --force

migrate: ## Run database migrations
	$(PHP) php artisan migrate --force

fresh: ## Drop all tables and re-run migrations
	$(PHP) php artisan migrate:fresh --force

seed: ## Seed the database
	$(PHP) php artisan db:seed --force

assets: ## Install and build frontend assets
	npm ci
	npm run build

test: ## Run PHPUnit/Pest tests
	$(PHP) php artisan test

clean: ## Stop containers and remove volumes
	$(COMPOSE) down -v

ecr-login: ## Authenticate Docker to AWS ECR
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(ECR_REGISTRY)

prod-build: assets ## Build production Docker image (Dockerfile)
	docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .

prod-tag: ## Tag local image for ECR
	docker tag $(IMAGE_NAME):$(IMAGE_TAG) $(ECR_IMAGE)

push: ecr-login prod-build prod-tag ## Build, tag, push to ECR, and force ECS redeploy
	docker push $(ECR_IMAGE)
	aws ecs update-service --cluster $(ECS_CLUSTER) --service $(ECS_SERVICE) --force-new-deployment --region $(AWS_REGION)
	@echo ""
	@echo "  Pushed: $(ECR_IMAGE)"
	@echo "  ECS redeploy started ($(ECS_CLUSTER) / $(ECS_SERVICE))."
	@echo ""
