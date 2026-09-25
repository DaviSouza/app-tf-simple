# =============================================================================
# TERRAFORM BLOCK — metadados do projeto
# =============================================================================
# Entrevista: "O que é o bloco terraform {}?"
# → Define versão mínima do Terraform e quais providers (plugins) são necessários.
# O Terraform baixa providers do registry (hashicorp/aws) na primeira execução.
# O version constraint (~> 6.0) aceita 6.x mas não 7.0 (breaking changes).
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    # Provider AWS — traduz recursos HCL (aws_vpc, aws_s3_bucket...) em chamadas API AWS
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Provider random — gera valores aleatórios (senhas, sufixos de bucket)
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    # Provider archive — compacta diretórios em .zip (usado pela Lambda auth-service)
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    # Provider null — recurso "placeholder" para executar provisioners (ex.: disparar CodeBuild)
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}
