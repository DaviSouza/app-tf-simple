# =============================================================================
# CI/CD — Opção C: GitHub (source) + CodePipeline + CodeBuild (sem GitHub Actions)
# =============================================================================
# Fluxo:
#   push no GitHub → CodePipeline → CodeBuild (docker build/push ECR) → deploy
#     - cadastro-cliente → ECS force-new-deployment
#     - front-client     → S3 sync + invalidação CloudFront
#
# Após o apply: autorize a conexão GitHub no console AWS
#   Developer Tools → Settings → Connections → Pending → Update pending connection
# =============================================================================

locals {
  cicd_enabled = var.enable_cicd && var.github_owner != ""

  # Quando CI/CD está desligado, ambos podem ser null — coalesce sozinho falha.
  github_connection_arn = try(
    coalesce(
      var.github_connection_arn,
      aws_codestarconnections_connection.github[0].arn,
    ),
    null,
  )

  vite_api_gateway_url   = aws_apigatewayv2_api.cadastro_cliente.api_endpoint
  vite_cognito_authority = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  vite_cognito_client_id = aws_cognito_user_pool_client.main.id
  vite_realtime_sse_url  = "https://${aws_cloudfront_distribution.front.domain_name}/realtime/events"
  vite_realtime_http_url = "${aws_apigatewayv2_api.cadastro_cliente.api_endpoint}/realtime"
}

# Conexão GitHub (CodeConnections). Status fica PENDING até autorização manual no console.
resource "aws_codestarconnections_connection" "github" {
  count = local.cicd_enabled && var.github_connection_arn == null ? 1 : 0

  name          = "${var.project_name}-github"
  provider_type = "GitHub"

  tags = {
    Name = "${var.project_name}/github-connection"
  }
}

# Bucket de artefatos do CodePipeline (source zip entre stages)
resource "aws_s3_bucket" "pipeline_artifacts" {
  count = local.cicd_enabled ? 1 : 0

  bucket = "${var.project_name}-pipeline-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${var.project_name}/pipeline-artifacts"
  }
}

resource "aws_s3_bucket_versioning" "pipeline_artifacts" {
  count  = local.cicd_enabled ? 1 : 0
  bucket = aws_s3_bucket.pipeline_artifacts[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline_artifacts" {
  count  = local.cicd_enabled ? 1 : 0
  bucket = aws_s3_bucket.pipeline_artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline_artifacts" {
  count  = local.cicd_enabled ? 1 : 0
  bucket = aws_s3_bucket.pipeline_artifacts[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- IAM CodePipeline ---

resource "aws_iam_role" "codepipeline" {
  count = local.cicd_enabled ? 1 : 0
  name  = "${var.project_name}-codepipeline"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.project_name}/codepipeline-role"
  }
}

resource "aws_iam_role_policy" "codepipeline" {
  count = local.cicd_enabled ? 1 : 0
  name  = "${var.project_name}-codepipeline"
  role  = aws_iam_role.codepipeline[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts[0].arn,
          "${aws_s3_bucket.pipeline_artifacts[0].arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection"]
        Resource = local.github_connection_arn
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild",
        ]
        Resource = [
          aws_codebuild_project.cadastro_cliente_ci[0].arn,
          aws_codebuild_project.front_client_ci[0].arn,
        ]
      },
    ]
  })
}

# --- IAM CodeBuild (pipelines CI) ---

resource "aws_iam_role" "codebuild_ci" {
  count = local.cicd_enabled ? 1 : 0
  name  = "${var.project_name}-codebuild-ci"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.project_name}/codebuild-ci-role"
  }
}

resource "aws_iam_role_policy" "codebuild_ci" {
  count = local.cicd_enabled ? 1 : 0
  name  = "${var.project_name}-codebuild-ci"
  role  = aws_iam_role.codebuild_ci[0].id

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
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project_name}-*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.pipeline_artifacts[0].arn,
          "${aws_s3_bucket.pipeline_artifacts[0].arn}/*",
          aws_s3_bucket.front.arn,
          "${aws_s3_bucket.front.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = [
          aws_ecr_repository.main["cadastro_cliente"].arn,
          aws_ecr_repository.main["front_client"].arn,
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
        ]
        Resource = [
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.main.name}/${aws_ecs_service.cadastro_cliente.name}",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeClusters",
        ]
        Resource = [aws_ecs_cluster.main.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation"]
        Resource = aws_cloudfront_distribution.front.arn
      },
    ]
  })
}

# --- CodeBuild: cadastro-cliente ---

resource "aws_codebuild_project" "cadastro_cliente_ci" {
  count = local.cicd_enabled ? 1 : 0

  name          = "${var.project_name}-cadastro-cliente-ci"
  description   = "CI/CD: build Docker, push ECR e deploy ECS (cadastro-cliente)"
  service_role  = aws_iam_role.codebuild_ci[0].arn
  build_timeout = 45

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }

    environment_variable {
      name  = "REPOSITORY_URI"
      value = aws_ecr_repository.main["cadastro_cliente"].repository_url
    }

    environment_variable {
      name  = "ECS_CLUSTER_NAME"
      value = aws_ecs_cluster.main.name
    }

    environment_variable {
      name  = "ECS_SERVICE_NAME"
      value = aws_ecs_service.cadastro_cliente.name
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspec/cadastro-cliente-ci.yml")
  }

  tags = {
    Name = "${var.project_name}/cadastro-cliente-ci"
  }
}

# --- CodeBuild: front-client ---

resource "aws_codebuild_project" "front_client_ci" {
  count = local.cicd_enabled ? 1 : 0

  name          = "${var.project_name}-front-client-ci"
  description   = "CI/CD: build Docker, push ECR, sync S3 e invalida CloudFront"
  service_role  = aws_iam_role.codebuild_ci[0].arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }

    environment_variable {
      name  = "REPOSITORY_URI"
      value = aws_ecr_repository.main["front_client"].repository_url
    }

    environment_variable {
      name  = "BUCKET_NAME"
      value = aws_s3_bucket.front.id
    }

    environment_variable {
      name  = "CLOUDFRONT_DISTRIBUTION_ID"
      value = aws_cloudfront_distribution.front.id
    }

    environment_variable {
      name  = "VITE_API_GATEWAY_URL"
      value = local.vite_api_gateway_url
    }

    environment_variable {
      name  = "VITE_COGNITO_AUTHORITY"
      value = local.vite_cognito_authority
    }

    environment_variable {
      name  = "VITE_COGNITO_CLIENT_ID"
      value = local.vite_cognito_client_id
    }

    environment_variable {
      name  = "VITE_REALTIME_SSE_URL"
      value = local.vite_realtime_sse_url
    }

    environment_variable {
      name  = "VITE_REALTIME_HTTP_URL"
      value = local.vite_realtime_http_url
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${path.module}/buildspec/front-client-ci.yml")
  }

  tags = {
    Name = "${var.project_name}/front-client-ci"
  }
}

# --- Pipelines ---

resource "aws_codepipeline" "cadastro_cliente" {
  count = local.cicd_enabled ? 1 : 0

  name     = "${var.project_name}-cadastro-cliente"
  role_arn = aws_iam_role.codepipeline[0].arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts[0].bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = local.github_connection_arn
        FullRepositoryId = "${var.github_owner}/${var.github_cadastro_cliente_repo}"
        BranchName       = var.github_cadastro_cliente_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "BuildDeploy"

    action {
      name            = "BuildAndDeploy"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.cadastro_cliente_ci[0].name
      }
    }
  }

  tags = {
    Name = "${var.project_name}/pipeline-cadastro-cliente"
  }
}

resource "aws_codepipeline" "front_client" {
  count = local.cicd_enabled ? 1 : 0

  name     = "${var.project_name}-front-client"
  role_arn = aws_iam_role.codepipeline[0].arn

  artifact_store {
    location = aws_s3_bucket.pipeline_artifacts[0].bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = local.github_connection_arn
        FullRepositoryId = "${var.github_owner}/${var.github_front_client_repo}"
        BranchName       = var.github_front_client_branch
        DetectChanges    = "true"
      }
    }
  }

  stage {
    name = "BuildDeploy"

    action {
      name            = "BuildAndDeploy"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.front_client_ci[0].name
      }
    }
  }

  tags = {
    Name = "${var.project_name}/pipeline-front-client"
  }
}
