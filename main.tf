# =============================================================================
# PROVIDERS — configuração de autenticação e região AWS
# =============================================================================
# Entrevista: "O que é um provider no Terraform?"
# → Plugin que conecta o Terraform à API de um cloud (AWS, Azure, GCP...).
# Credenciais vêm de variáveis de ambiente (AWS_ACCESS_KEY_ID) ou ~/.aws/credentials.
# =============================================================================

# Provider padrão — todos os recursos sem alias usam esta região (var.aws_region)
provider "aws" {
  region = var.aws_region
}

# Provider com ALIAS — necessário porque WAF para CloudFront só existe em us-east-1.
# Entrevista: "Por que CloudFront/WAF precisam de us-east-1?"
# → CloudFront é serviço global; recursos associados (certificados ACM, WAF CLOUDFRONT scope)
#   são gerenciados na região us-east-1 por design da AWS.
# Uso: resource "aws_wafv2_web_acl" "..." { provider = aws.us_east_1 }
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
