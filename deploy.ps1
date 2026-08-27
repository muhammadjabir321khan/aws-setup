# Deploy production image to ECR and force a new ECS deployment
$ErrorActionPreference = "Stop"

$AWS_REGION = if ($env:AWS_REGION) { $env:AWS_REGION } else { "eu-north-1" }
$AWS_ACCOUNT = if ($env:AWS_ACCOUNT) { $env:AWS_ACCOUNT } else { "161327178744" }
$ECR_REPO = if ($env:ECR_REPO) { $env:ECR_REPO } else { "laravel-app" }
$IMAGE_TAG = if ($env:IMAGE_TAG) { $env:IMAGE_TAG } else { "latest" }
$ECS_CLUSTER = if ($env:ECS_CLUSTER) { $env:ECS_CLUSTER } else { "awsapp" }
$ECS_SERVICE = if ($env:ECS_SERVICE) { $env:ECS_SERVICE } else { "awsapp" }
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

Write-Host "==> Forcing new ECS deployment ($ECS_CLUSTER / $ECS_SERVICE)..."
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$ecsOut = aws ecs update-service `
    --cluster $ECS_CLUSTER `
    --service $ECS_SERVICE `
    --force-new-deployment `
    --region $AWS_REGION 2>&1
$ecsCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap

if ($ecsCode -ne 0) {
    Write-Host ""
    Write-Host "Pushed: $ECR_IMAGE"
    Write-Host "WARNING: Image pushed OK, but ECS auto-redeploy failed."
    Write-Host ($ecsOut | Out-String)
    Write-Host "Fix: IAM -> Users -> jabir -> Permissions boundary -> edit policy -> allow ecs:UpdateService"
    Write-Host "Or manually: ECS -> awsapp -> awsapp -> Update -> Force new deployment"
    Write-Host ""
    exit 0
}

Write-Host ""
Write-Host "Pushed: $ECR_IMAGE"
Write-Host "ECS redeploy started. Wait for a new Running task, then use its Public IP."
Write-Host ""
