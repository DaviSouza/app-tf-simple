# =============================================================================
# CODEBUILD — deploy do front-client (ECR → S3)
# =============================================================================
# Entrevista: "Por que CodeBuild e não terraform provisioner direto no S3?"
# → Build roda em ambiente isolado Linux com Docker; extrai assets do container e invalida CloudFront.
# null_resource + local-exec dispara o build apenas quando run_front_deploy=true.
# =============================================================================

variable "front_client_image_tag" {
  description = "Tag da imagem front-client no ECR consumida pelo CodeBuild para extrair assets estáticos."
  type        = string
  default     = "latest"
}

variable "run_front_deploy" {
  description = "Se true, dispara CodeBuild no terraform apply via null_resource. Equivalente a -c runFrontDeploy=true no CDK."
  type        = bool
  default     = false
}

locals {
  front_client_image_uri = aws_ecr_repository.main["front_client"].repository_url

  # Mensagem exibida no output front_deploy_hint conforme flag
  front_deploy_hint = var.run_front_deploy ? "CodeBuild será executado neste apply (run_front_deploy=true)" : "Infra OK. Publique: push front-client no ECR, depois terraform apply -var=run_front_deploy=true"
}

# IAM Role — CodeBuild assume esta role via sts:AssumeRole (trust policy)
resource "aws_iam_role" "codebuild_front" {
  name = "${var.project_name}-codebuild-front"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.project_name}/codebuild-front-role"
  }
}

# Inline policy — permissões mínimas: logs, S3 do front, pull ECR front_client
resource "aws_iam_role_policy" "codebuild_front" {
  name = "${var.project_name}-codebuild-front"
  role = aws_iam_role.codebuild_front.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-front-to-s3*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.front.arn,
          "${aws_s3_bucket.front.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = aws_ecr_repository.main["front_client"].arn
      },
    ]
  })
}

resource "aws_codebuild_project" "front_deploy" {
  name          = "${var.project_name}-front-to-s3"
  description   = "Publica front-client do ECR no bucket S3"
  service_role  = aws_iam_role.codebuild_front.arn
  build_timeout = 20

  artifacts {
    type = "NO_ARTIFACTS" # Output vai direto pro S3 via script do buildspec
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true # Necessário para docker pull/run dentro do build
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "BUCKET_NAME"
      value = aws_s3_bucket.front.id
    }

    environment_variable {
      name  = "IMAGE_URI"
      value = local.front_client_image_uri
    }

    environment_variable {
      name  = "IMAGE_TAG"
      value = var.front_client_image_tag
    }

    environment_variable {
      name  = "AWS_REGION"
      value = var.aws_region
    }
  }

  source {
    type      = "NO_SOURCE" # Buildspec inline via file(); sem repo Git conectado
    buildspec = file("${path.module}/buildspec/front-to-s3.yml")
  }

  tags = {
    Name = "${var.project_name}/front-to-s3"
  }
}

# null_resource — recurso "virtual" para side-effects (provisioner local-exec)
# count = 0 ou 1: padrão condicional (alternativa: for_each com map vazio)
# triggers: força re-execução quando image_tag ou buildspec mudam
resource "null_resource" "front_deploy" {
  count = var.run_front_deploy ? 1 : 0

  triggers = {
    project_name    = aws_codebuild_project.front_deploy.name
    distribution_id = aws_cloudfront_distribution.front.id
    image_tag       = var.front_client_image_tag
    buildspec_hash  = filemd5("${path.module}/buildspec/front-to-s3.yml")
    deploy_script   = filemd5("${path.module}/scripts/front-deploy.sh")
  }

  provisioner "local-exec" {
    command = "bash \"${abspath(path.module)}/scripts/front-deploy.sh\" \"${aws_codebuild_project.front_deploy.name}\" \"${var.aws_region}\" \"${aws_cloudfront_distribution.front.id}\" \"${var.front_client_image_tag}\""
  }

  depends_on = [
    aws_codebuild_project.front_deploy,
    aws_cloudfront_distribution.front,
    aws_s3_bucket_policy.front,
  ]
}
