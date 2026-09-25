# =============================================================================
# API GATEWAY HTTP v2 — edge da API (auth Lambda + proxy ALB)
# =============================================================================
# Fluxo de roteamento:
#   /auth/*     → Lambda auth-service (Cognito)
#   /clientes/* → ALB → ECS (JWT required)
#   /health etc → ALB (público)
# Entrevista: "HTTP API vs REST API (v1)?"
# → HTTP API: mais barato, menor latência, JWT authorizer nativo. REST: mais features (WAF integration, request validation).
# Entrevista: "AWS_PROXY vs HTTP_PROXY?"
# → AWS_PROXY: evento Lambda formatado; HTTP_PROXY: repassa request HTTP ao backend.
# =============================================================================

locals {
  auth_lambda_source_dir = coalesce(
    var.auth_lambda_source_dir,
    "${path.module}/../../docker/app-cdk-simple/lambda/auth-service"
  )

  backend_base_url = "http://${aws_lb.cadastro_cliente.dns_name}"
  backend_alb_host = aws_lb.cadastro_cliente.dns_name

  # Issuer JWT do Cognito — API Gateway valida assinatura contra este URL
  cognito_issuer = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"

  # Rotas roteadas para Lambda (autenticação Cognito)
  auth_lambda_route_keys = [
    "POST /auth/confirm",
    "POST /auth/login",
    "POST /auth/refresh",
    "POST /auth/logout",
    "POST /auth/forgot-password",
    "POST /auth/reset-password",
  ]

  # Rotas públicas — proxy direto ao ALB sem JWT
  backend_public_route_keys = [
    "POST /auth/register",
    "GET /health",
    "POST /realtime/message",
    "POST /realtime/cliente-cadastrado",
    "POST /realtime/clientes-importados",
  ]

  # Rotas protegidas — exigem Authorization: Bearer <JWT Cognito>
  backend_jwt_route_keys = [
    "POST /clientes",
    "GET /clientes",
    "POST /clientes/importar",
    "GET /clientes/{id}",
    "PUT /clientes/{id}",
    "DELETE /clientes/{id}",
    "POST /clientes/verificar",
  ]
}

# DATA archive_file — zipa diretório da Lambda para upload (source_code_hash detecta mudanças)
data "archive_file" "auth_service" {
  type        = "zip"
  source_dir  = local.auth_lambda_source_dir
  output_path = "${path.module}/build/auth-service.zip"
}

resource "aws_apigatewayv2_api" "cadastro_cliente" {
  name          = "${var.project_name}-cadastro-cliente-api"
  protocol_type = "HTTP" # Alternativa: WEBSOCKET

  cors_configuration {
    allow_headers = [
      "Authorization",
      "Content-Type",
      "Accept",
      "Origin",
      "X-Requested-With",
    ]
    allow_methods = ["*"]
    allow_origins = ["*"]
  }

  tags = {
    Name = "${var.project_name}/cadastro-cliente-api"
  }
}

# Stage $default com auto_deploy — cada mudança de rota vai live sem deploy manual
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.cadastro_cliente.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Name = "${var.project_name}/cadastro-cliente-api-default"
  }
}

# JWT Authorizer — valida token Cognito (issuer + audience/client_id)
resource "aws_apigatewayv2_authorizer" "cognito_jwt" {
  api_id           = aws_apigatewayv2_api.cadastro_cliente.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "CognitoJwt"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.main.id]
    issuer   = local.cognito_issuer
  }
}

# =============================================================================
# POR QUE LAMBDA PARA /auth/* (e não o backend Rust no ECS)?
# =============================================================================
# API Gateway HTTP v2 tem JWT Authorizer nativo — valida tokens nas rotas /clientes/*.
# Porém login, refresh, logout, forgot-password etc. são FLUXOS ATIVOS: a aplicação
# precisa CHAMAR a API do Cognito (InitiateAuth, SignUp, ForgotPassword...) e devolver
# tokens/cookies ao front-end. Isso não é só "validar JWT"; é orquestração de auth.
#
# Opções arquiteturais:
#   A) Lambda auth-service  ← usado aqui
#   B) Rotas /auth/* no ECS Rust (funciona, mas mistura domínio de negócio com auth)
#   C) Cognito Hosted UI   (menos controle sobre UX/API customizada)
#
# Lambda foi escolhida porque:
#   1. Separação de responsabilidades — auth fica isolada do cadastro-cliente (Rust/ECS)
#   2. Escala independente — picos de login não competem com CPU do app principal
#   3. Custo — auth é esporádico; Lambda paga por invocação (vs task ECS sempre ligada)
#   4. Deploy independente — muda fluxo de login sem redeploy do container Rust
#   5. API Gateway integra nativamente (AWS_PROXY) — latência baixa, sem hop extra no ALB
#
# Entrevista: "Lambda entre API Gateway e Cognito vs chamar Cognito direto do front?"
# → Front direto expõe client_id e lógica de refresh; backend (Lambda) centraliza
#   credenciais de serviço, rate limit, logs e pode chamar o ALB após login se necessário.
# =============================================================================

# -----------------------------------------------------------------------------
# IAM ROLE — identidade que a Lambda assume em runtime
# -----------------------------------------------------------------------------
# Entrevista: "O que é uma IAM Role?"
# → Conjunto de permissões temporárias (credenciais STS) que um serviço AWS assume.
#   Não é usuário humano; é "quem sou eu quando executo".
#
# Entrevista: "Trust policy vs Permission policy?"
# → Trust policy (assume_role_policy): QUEM pode assumir a role (aqui: lambda.amazonaws.com)
# → Permission policy: O QUE a role pode fazer depois de assumida (logs, Cognito...)
#
# Fluxo: API Gateway invoca Lambda → Lambda chama sts:AssumeRole nesta role →
#        recebe credenciais temporárias → usa essas credenciais nas chamadas cognito-idp:*
# -----------------------------------------------------------------------------
resource "aws_iam_role" "auth_lambda" {
  name = "${var.project_name}-auth-service"

  # Trust policy — só o serviço Lambda pode "vestir" esta role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"              # Permissão de trocar identidade
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" } # Principal = quem solicita AssumeRole
    }]
  })

  tags = {
    Name = "${var.project_name}/auth-service-role"
  }
}

# -----------------------------------------------------------------------------
# IAM ROLE POLICY ATTACHMENT — policy gerenciada pela AWS (reutilizável)
# -----------------------------------------------------------------------------
# Entrevista: "Attachment vs inline policy?"
# → Attachment: vincula policy AWS-managed ou customer-managed EXISTENTE à role
# → Inline (auth_lambda_cognito abaixo): policy colada na role; some se a role for deletada
#
# AWSLambdaBasicExecutionRole concede:
#   - logs:CreateLogGroup, CreateLogStream, PutLogEvents → CloudWatch Logs
# Sem isso a Lambda executa mas você não vê stdout/stderr (debug impossível).
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "auth_lambda_basic" {
  role       = aws_iam_role.auth_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# -----------------------------------------------------------------------------
# IAM INLINE POLICY — permissões de negócio (Cognito User Pool)
# -----------------------------------------------------------------------------
# Entrevista: "Princípio do menor privilégio aqui?"
# → Resource = ARN do User Pool específico (não "*" em cognito-idp)
# → Action lista só APIs necessárias para os fluxos /auth/* definidos em auth_lambda_route_keys
#
# Por ação (o que a Lambda auth-service faz em cada rota):
#   SignUp / ConfirmSignUp        → registro + confirmação por email
#   InitiateAuth                  → login (USER_PASSWORD_AUTH ou SRP)
#   ForgotPassword / ConfirmForgotPassword → recuperação de senha
#   GlobalSignOut                 → logout (invalida refresh tokens)
#   Admin*                        → operações admin quando o fluxo user-side não basta
#                                   (ex.: confirmar usuário, reset forçado em suporte)
#
# A Lambda usa AWS SDK cognito-idp com credenciais desta role — NUNCA armazena
# access keys no código; IAM entrega credenciais temporárias automaticamente.
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "auth_lambda_cognito" {
  name = "${var.project_name}-auth-service-cognito"
  role = aws_iam_role.auth_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cognito-idp:SignUp",
        "cognito-idp:ConfirmSignUp",
        "cognito-idp:InitiateAuth",
        "cognito-idp:ForgotPassword",
        "cognito-idp:ConfirmForgotPassword",
        "cognito-idp:GlobalSignOut",
        "cognito-idp:AdminGetUser",
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminSetUserPassword",
        "cognito-idp:AdminInitiateAuth",
        "cognito-idp:AdminConfirmSignUp",
        "cognito-idp:AdminUpdateUserAttributes",
      ]
      Resource = aws_cognito_user_pool.main.arn # Escopo restrito a ESTE user pool
    }]
  })
}

# =============================================================================
# aws_lambda_function.auth_service — CÓDIGO CUSTOMIZADO (não é produto pronto da AWS)
# =============================================================================
# O que a AWS fornece:
#   - Lambda (plataforma): executa código sob demanda, escala, cobra por invocação
#   - Cognito (serviço): User Pool, senhas, emissão/validação de JWT
#   - API Gateway JWT Authorizer: valida JWT nas rotas /clientes/* SEM passar pela Lambda
#
# O que VOCÊS implementam (docker/.../lambda/auth-service/index.js):
#   - Rotas POST /auth/login, /refresh, /logout, /confirm, /forgot-password, /reset-password
#   - Lógica de negócio: ex. login valida credenciais no backend Rust (Postgres) ANTES do Cognito
#   - Sincroniza usuário Postgres → Cognito e devolve tokens + dados do usuário ao front
#
# Terraform empacota index.js + node_modules em .zip (data.archive_file) e publica na Lambda.
# auth_lambda (IAM role) = só o nome do recurso de permissões; não é um serviço AWS separado.
#
# Código-fonte: local.auth_lambda_source_dir → docker/app-cdk-simple/lambda/auth-service/
# =============================================================================
resource "aws_lambda_function" "auth_service" {
  function_name = "${var.project_name}-auth-service"
  role          = aws_iam_role.auth_lambda.arn # IAM role customizada (logs + cognito-idp)
  handler       = "index.handler"                # exports.handler no index.js
  runtime       = "nodejs20.x"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.auth_service.output_path
  source_code_hash = data.archive_file.auth_service.output_base64sha256 # Re-deploy se o .zip mudar

  environment {
    variables = {
      COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.main.id
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.main.id
      BACKEND_BASE_URL     = local.backend_base_url # ALB → ECS Rust (validação de login)
    }
  }

  tags = {
    Name = "${var.project_name}/auth-service"
  }
}

# Resource-based policy — permite API Gateway invocar a Lambda
resource "aws_lambda_permission" "auth_service_api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_service.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.cadastro_cliente.execution_arn}/*/*"
}

# Integração Lambda — payload format 2.0 (HTTP API v2 response format)
resource "aws_apigatewayv2_integration" "auth_lambda" {
  api_id                 = aws_apigatewayv2_api.cadastro_cliente.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.auth_service.invoke_arn
  payload_format_version = "2.0"
}

# Integração HTTP — proxy para ALB; overwrite:header.host corrige Host header para o ALB
resource "aws_apigatewayv2_integration" "backend_http" {
  api_id                 = aws_apigatewayv2_api.cadastro_cliente.id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = local.backend_base_url
  payload_format_version = "1.0"

  request_parameters = {
    "overwrite:path"        = "$request.path"
    "overwrite:header.host" = local.backend_alb_host
  }
}

# for_each + toset — cria uma rota por string (evita repetir blocos idênticos)
resource "aws_apigatewayv2_route" "auth_lambda" {
  for_each = toset(local.auth_lambda_route_keys)

  api_id    = aws_apigatewayv2_api.cadastro_cliente.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.auth_lambda.id}"
}

resource "aws_apigatewayv2_route" "backend_public" {
  for_each = toset(local.backend_public_route_keys)

  api_id             = aws_apigatewayv2_api.cadastro_cliente.id
  route_key          = each.value
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.backend_http.id}"
}

resource "aws_apigatewayv2_route" "backend_jwt" {
  for_each = toset(local.backend_jwt_route_keys)

  api_id             = aws_apigatewayv2_api.cadastro_cliente.id
  route_key          = each.value
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito_jwt.id
  target             = "integrations/${aws_apigatewayv2_integration.backend_http.id}"
}
