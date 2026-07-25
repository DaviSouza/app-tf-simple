locals {
  auth_lambda_source_dir = coalesce(
    var.auth_lambda_source_dir,
    "${path.module}/../../docker/app-cdk-simple/lambda/auth-service"
  )

  backend_base_url = "http://${aws_lb.cadastro_cliente.dns_name}"
  backend_alb_host = aws_lb.cadastro_cliente.dns_name

  cognito_issuer = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"

  auth_lambda_route_keys = [
    "POST /auth/confirm",
    "POST /auth/login",
    "POST /auth/refresh",
    "POST /auth/logout",
    "POST /auth/forgot-password",
    "POST /auth/reset-password",
  ]

  backend_public_route_keys = [
    "POST /auth/register",
    "GET /health",
    "POST /realtime/message",
    "POST /realtime/cliente-cadastrado",
    "POST /realtime/clientes-importados",
  ]

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

data "archive_file" "auth_service" {
  type        = "zip"
  source_dir  = local.auth_lambda_source_dir
  output_path = "${path.module}/build/auth-service.zip"
}

resource "aws_apigatewayv2_api" "cadastro_cliente" {
  name          = "${var.project_name}-cadastro-cliente-api"
  protocol_type = "HTTP"

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

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.cadastro_cliente.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Name = "${var.project_name}/cadastro-cliente-api-default"
  }
}

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

resource "aws_iam_role" "auth_lambda" {
  name = "${var.project_name}-auth-service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.project_name}/auth-service-role"
  }
}

resource "aws_iam_role_policy_attachment" "auth_lambda_basic" {
  role       = aws_iam_role.auth_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

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
      Resource = aws_cognito_user_pool.main.arn
    }]
  })
}

resource "aws_lambda_function" "auth_service" {
  function_name = "${var.project_name}-auth-service"
  role          = aws_iam_role.auth_lambda.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"
  timeout       = 30
  memory_size   = 256

  filename         = data.archive_file.auth_service.output_path
  source_code_hash = data.archive_file.auth_service.output_base64sha256

  environment {
    variables = {
      COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.main.id
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.main.id
      BACKEND_BASE_URL     = local.backend_base_url
    }
  }

  tags = {
    Name = "${var.project_name}/auth-service"
  }
}

resource "aws_lambda_permission" "auth_service_api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.auth_service.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.cadastro_cliente.execution_arn}/*/*"
}

resource "aws_apigatewayv2_integration" "auth_lambda" {
  api_id                 = aws_apigatewayv2_api.cadastro_cliente.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.auth_service.invoke_arn
  payload_format_version = "2.0"
}

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
