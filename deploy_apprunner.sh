#!/usr/bin/env bash
# Build, push to ECR, and create/update the App Runner service.
# Secrets are read from Secrets Manager; this script never handles their values.
#
# Prereq (one time, values entered by you, not this script):
#   aws secretsmanager create-secret --name sony-sync/atlan-api-key  --secret-string '<key>'
#   aws secretsmanager create-secret --name sony-sync/github-token   --secret-string '<ghp>'
#   aws secretsmanager create-secret --name sony-sync/sync-token     --secret-string "$(openssl rand -hex 32)"
set -euo pipefail

: "${AWS_REGION:?set AWS_REGION}"
SERVICE=sony-glossary-sync
REPO=sony-glossary-sync
ACCT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="$ACCT.dkr.ecr.$AWS_REGION.amazonaws.com"
TAG=$(git rev-parse --short HEAD)
IMAGE="$REGISTRY/$REPO:$TAG"

aws ecr describe-repositories --repository-names "$REPO" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$REPO" \
       --image-scanning-configuration scanOnPush=true >/dev/null

aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"

secret_arn() { aws secretsmanager describe-secret --secret-id "$1" --query ARN --output text; }

# Roles (idempotent)
ACCESS_ROLE=AppRunnerSonyECRAccess
INSTANCE_ROLE=AppRunnerSonyInstance
if ! aws iam get-role --role-name "$ACCESS_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ACCESS_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"build.apprunner.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ACCESS_ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess
fi
if ! aws iam get-role --role-name "$INSTANCE_ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$INSTANCE_ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"tasks.apprunner.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam put-role-policy --role-name "$INSTANCE_ROLE" --policy-name read-sony-sync-secrets \
    --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"secretsmanager:GetSecretValue\",\"Resource\":\"arn:aws:secretsmanager:$AWS_REGION:$ACCT:secret:sony-sync/*\"}]}"
  sleep 10  # IAM propagation
fi
ACCESS_ARN=$(aws iam get-role --role-name "$ACCESS_ROLE" --query Role.Arn --output text)
INSTANCE_ARN=$(aws iam get-role --role-name "$INSTANCE_ROLE" --query Role.Arn --output text)

SRC=$(cat <<JSON
{
  "ImageRepository": {
    "ImageIdentifier": "$IMAGE",
    "ImageRepositoryType": "ECR",
    "ImageConfiguration": {
      "Port": "8080",
      "RuntimeEnvironmentVariables": {
        "ATLAN_BASE_URL": "https://dsm.atlan.com",
        "GITHUB_REPO": "sony-telemetry/schema-registry",
        "GLOSSARY_NAME": "sony_telemetry"
      },
      "RuntimeEnvironmentSecrets": {
        "ATLAN_API_KEY": "$(secret_arn sony-sync/atlan-api-key)",
        "GITHUB_TOKEN": "$(secret_arn sony-sync/github-token)",
        "SYNC_TOKEN": "$(secret_arn sony-sync/sync-token)"
      }
    }
  },
  "AuthenticationConfiguration": {"AccessRoleArn": "$ACCESS_ARN"},
  "AutoDeploymentsEnabled": false
}
JSON
)
HC='{"Protocol":"HTTP","Path":"/health","Interval":10,"Timeout":5,"HealthyThreshold":1,"UnhealthyThreshold":5}'

ARN=$(aws apprunner list-services --query "ServiceSummaryList[?ServiceName=='$SERVICE'].ServiceArn | [0]" --output text)
if [ "$ARN" = "None" ] || [ -z "$ARN" ]; then
  aws apprunner create-service --service-name "$SERVICE" \
    --source-configuration "$SRC" \
    --instance-configuration "Cpu=1024,Memory=2048,InstanceRoleArn=$INSTANCE_ARN" \
    --health-check-configuration "$HC"
else
  aws apprunner update-service --service-arn "$ARN" --source-configuration "$SRC"
fi
