# =============================================================================
# ECR — Elastic Container Registry (registry de imagens Docker)
# =============================================================================
# Entrevista: "ECR vs Docker Hub?"
# → ECR integra nativamente com ECS/EKS/CodeBuild; IAM controla push/pull; scan de vulnerabilidades.
# for_each cria um recurso por entrada no map (vs count que usa índice numérico).
# =============================================================================

locals {
  # Map chave Terraform → nome do repositório ECR
  # for_each em aws_ecr_repository.main usa each.key (cadastro_cliente) e each.value (cadastro-cliente)
  ecr_repositories = {
    cadastro_cliente = "cadastro-cliente" # API Rust
    front_client     = "front-client"     # SPA React/Vite → S3 via CodeBuild
    front_insights   = "front-insights"   # Serviço realtime/SSE + MCP
  }
}

resource "aws_ecr_repository" "main" {
  for_each = local.ecr_repositories

  name                 = each.value
  image_tag_mutability = "MUTABLE" # Permite sobrescrever tag "latest" (IMMUTABLE = tag única para sempre)
  force_delete         = false     # Se true, permite destroy mesmo com imagens (cuidado em prod)

  image_scanning_configuration {
    scan_on_push = true # Scan básico de CVEs ao fazer push
  }

  encryption_configuration {
    encryption_type = "AES256" # Criptografia at-rest (alternativa: KMS com chave customizada)
  }

  tags = {
    Name = "${var.project_name}/${each.value}"
  }
}
