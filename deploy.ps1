# Deploy production image to ECR (Windows PowerShell — no make required)
$ErrorActionPreference = "Stop"

$AWS_REGION = if ($env:AWS_REGION) { $env:AWS_REGION } else { "eu-north-1" }
$AWS_ACCOUNT = if ($env:AWS_ACCOUNT) { $env:AWS_ACCOUNT } else { "161327178744" }
$ECR_REPO = if ($env:ECR_REPO) { $env:ECR_REPO } else { "laravel-app" }
$IMAGE_TAG = if ($env:IMAGE_TAG) { $env:IMAGE_TAG } else { "latest" }
$ECR_REGISTRY = "$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
$ECR_IMAGE = "$ECR_REGISTRY/${ECR_REPO}:$IMAGE_TAG"

Write-Host "==> Building frontend assets..."
npm ci
npm run build

Write-Host "==> Logging in to ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY

Write-Host "==> Building image (no cache)..."
docker build --no-cache -t "laravel-app:$IMAGE_TAG" .

Write-Host "==> Tagging $ECR_IMAGE ..."
docker tag "laravel-app:$IMAGE_TAG" $ECR_IMAGE

Write-Host "==> Pushing $ECR_IMAGE ..."
docker push $ECR_IMAGE

Write-Host ""
Write-Host "Pushed: $ECR_IMAGE"
Write-Host "Next: ECS -> your service -> Update -> Force new deployment"
Write-Host "Confirm the new task has a NEW Public IP (old IP means old task)."
Write-Host ""
