#!/usr/bin/env bash
set -eu

PROJECT_NAME="${1:?project name required}"
AWS_REGION="${2:?region required}"
DISTRIBUTION_ID="${3:?distribution id required}"
IMAGE_TAG="${4:-latest}"

IMAGE_URI="$(aws codebuild batch-get-projects \
  --names "$PROJECT_NAME" \
  --region "$AWS_REGION" \
  --query "projects[0].environment.environmentVariables[?name=='IMAGE_URI'].value | [0]" \
  --output text)"
REPO_NAME="${IMAGE_URI##*/}"

if ! aws ecr describe-images \
  --repository-name "$REPO_NAME" \
  --region "$AWS_REGION" \
  --image-ids "imageTag=${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "ERRO: imagem ${REPO_NAME}:${IMAGE_TAG} não encontrada no ECR (${AWS_REGION})."
  echo "Faça build e push antes de rodar run_front_deploy=true."
  echo "Exemplo:"
  echo "  IMAGE_URI=\$(terraform output -raw front_client_repository_uri)"
  echo "  docker build -t \"\$IMAGE_URI:${IMAGE_TAG}\" /caminho/do/app-front-client"
  echo "  docker push \"\$IMAGE_URI:${IMAGE_TAG}\""
  exit 1
fi

BUILD_ID="$(aws codebuild start-build \
  --project-name "$PROJECT_NAME" \
  --region "$AWS_REGION" \
  --query 'build.id' --output text)"

echo "CodeBuild iniciado: $BUILD_ID"

while true; do
  STATUS="$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region "$AWS_REGION" \
    --query 'builds[0].buildStatus' --output text)"
  echo "Status: $STATUS"

  case "$STATUS" in
    SUCCEEDED) break ;;
    FAILED|FAULT|STOPPED|TIMED_OUT)
      echo "CodeBuild falhou: $STATUS"
      aws codebuild batch-get-builds --ids "$BUILD_ID" --region "$AWS_REGION" \
        --query 'builds[0].phases[?phaseStatus==`FAILED`].[phaseType,contexts[0].message]' \
        --output text
      LOG_LINK="$(aws codebuild batch-get-builds --ids "$BUILD_ID" --region "$AWS_REGION" \
        --query 'builds[0].logs.deepLink' --output text)"
      if [[ -n "$LOG_LINK" && "$LOG_LINK" != "None" ]]; then
        echo "Logs: $LOG_LINK"
      fi
      exit 1
      ;;
  esac
  sleep 15
done

aws cloudfront create-invalidation \
  --distribution-id "$DISTRIBUTION_ID" \
  --paths "/*"

echo "Front publicado e cache do CloudFront invalidado."
