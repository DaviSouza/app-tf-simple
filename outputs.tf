output "vpc_id" {
  description = "ID da VPC — necessário para peerings, VPN, ou importar em outro stack."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR da VPC — útil para configurar security groups em stacks externos."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Lista de subnet IDs públicas — ALB, NAT, RDS público ficam aqui."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Lista de subnet IDs privadas — ECS EC2 instances ficam aqui."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  description = "ID do NAT Gateway — referência para troubleshooting de conectividade outbound."
  value       = aws_nat_gateway.main.id
}

output "cadastro_cliente_repository_uri" {
  description = "URI para docker push/pull da API Rust (cadastro-cliente)."
  value       = aws_ecr_repository.main["cadastro_cliente"].repository_url
}

output "front_client_repository_uri" {
  description = "URI do repositório front-client — imagem fonte do deploy S3."
  value       = aws_ecr_repository.main["front_client"].repository_url
}

output "front_insights_repository_uri" {
  description = "URI do repositório front-insights — serviço realtime/SSE."
  value       = aws_ecr_repository.main["front_insights"].repository_url
}

output "ecr_repository_arns" {
  description = "Map de ARNs ECR — usado em políticas IAM cross-service."
  value       = { for k, repo in aws_ecr_repository.main : k => repo.arn }
}

output "s3_bucket_name" {
  description = "Nome do bucket S3 do front — destino do CodeBuild."
  value       = aws_s3_bucket.front.id
}

output "s3_bucket_arn" {
  description = "ARN do bucket — referência em bucket policies."
  value       = aws_s3_bucket.front.arn
}

output "front_url" {
  description = "URL HTTPS pública do SPA via CloudFront."
  value       = "https://${aws_cloudfront_distribution.front.domain_name}"
}

output "realtime_sse_url" {
  description = "URL SSE de eventos em tempo real (VITE_REALTIME_SSE_URL)."
  value       = "https://${aws_cloudfront_distribution.front.domain_name}/realtime/events"
}

output "cloudfront_distribution_id" {
  description = "ID da distribuição — necessário para invalidation de cache."
  value       = aws_cloudfront_distribution.front.id
}

output "cloudfront_distribution_domain" {
  description = "Domínio *.cloudfront.net da distribuição."
  value       = aws_cloudfront_distribution.front.domain_name
}

output "db_endpoint_hostname" {
  description = "Hostname do RDS — use no DBeaver ou connection string."
  value       = aws_db_instance.postgres.address
}

output "db_endpoint_port" {
  description = "Porta PostgreSQL (5432)."
  value       = aws_db_instance.postgres.port
}

output "db_secret_arn" {
  description = "ARN do secret com username/password — ECS e operadores leem daqui."
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "load_balancer_dns_name" {
  description = "DNS interno do ALB — API Gateway faz proxy para este host."
  value       = aws_lb.cadastro_cliente.dns_name
}

output "load_balancer_url" {
  description = "URL HTTP direta do ALB (sem HTTPS — uso interno/debug)."
  value       = "http://${aws_lb.cadastro_cliente.dns_name}"
}

output "alb_listener_arn" {
  description = "ARN do listener HTTP:80 — base para criar listener rules adicionais."
  value       = aws_lb_listener.http.arn
}

output "ecs_cluster_name" {
  description = "Nome do cluster ECS — referência para aws ecs run-task / deploy scripts."
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Nome do serviço ECS cadastro-cliente."
  value       = aws_ecs_service.cadastro_cliente.name
}

output "cadastro_cliente_app_config_secret_arn" {
  description = "ARN do secret com env vars do app Rust (DATABASE_URL, Cognito...)."
  value       = aws_secretsmanager_secret.app_config.arn
}

output "cognito_user_pool_id" {
  description = "ID do User Pool — configure no front-end (VITE_COGNITO_USER_POOL_ID)."
  value       = aws_cognito_user_pool.main.id
}

output "cognito_user_pool_client_id" {
  description = "Client ID do app — usado no login e JWT audience validation."
  value       = aws_cognito_user_pool_client.main.id
}

output "web_acl_arn" {
  description = "ARN do WAF CloudFront (us-east-1) — associado à distribuição."
  value       = aws_wafv2_web_acl.cloudfront.arn
}

output "http_api_url" {
  description = "URL base do API Gateway HTTP — endpoint público da API."
  value       = aws_apigatewayv2_api.cadastro_cliente.api_endpoint
}

output "auth_lambda_name" {
  description = "Nome da Lambda auth-service — referência para logs e debug."
  value       = aws_lambda_function.auth_service.function_name
}

output "realtime_http_api_base" {
  description = "Base URL para rotas POST /realtime/* via API Gateway."
  value       = "${aws_apigatewayv2_api.cadastro_cliente.api_endpoint}/realtime"
}

output "insights_alb_dns_name" {
  description = "DNS do ALB para CNAME do subdomínio realtime customizado."
  value       = aws_lb.cadastro_cliente.dns_name
}

output "insights_host_hint" {
  description = "URL SSE sugerida conforme cors_origin, insights_host ou CloudFront."
  value       = local.insights_host_hint
}

output "insights_mcp_internal" {
  description = "MCP roda em localhost dentro da task — não exposto externamente."
  value       = "http://127.0.0.1:8899/mcp (somente dentro da task ECS)"
}

output "insights_service_name" {
  description = "Nome do serviço ECS insights."
  value       = aws_ecs_service.insights.name
}

output "insights_config_secret_arn" {
  description = "ARN do secret com credenciais do serviço insights."
  value       = aws_secretsmanager_secret.insights_config.arn
}

output "front_deploy_project_name" {
  description = "Nome do projeto CodeBuild — usado pelo script front-deploy.sh."
  value       = aws_codebuild_project.front_deploy.name
}

output "front_deploy_hint" {
  description = "Instrução de próximo passo para publicar o front no S3."
  value       = local.front_deploy_hint
}
