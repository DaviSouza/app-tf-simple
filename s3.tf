# =============================================================================
# S3 — bucket estático para o front-end SPA
# =============================================================================
# Fluxo: CodeBuild extrai assets do container front-client → S3 → CloudFront serve ao usuário.
# Entrevista: "Por que S3 + CloudFront e não servir do ECS?"
# → Custo menor, escala global, cache na edge; SPA estática não precisa de servidor.
# =============================================================================

# Gera sufixo aleatório de 4 bytes (8 chars hex) para garantir nome único do bucket
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "front" {
  # coalesce: usa var.s3_bucket_name se não for null, senão gera nome automático
  bucket = coalesce(var.s3_bucket_name, "${var.project_name}-front-${random_id.bucket_suffix.hex}")

  tags = {
    Name = "${var.project_name}/front"
  }
}

# Versioning — mantém histórico de objetos (rollback, proteção contra overwrite acidental)
resource "aws_s3_bucket_versioning" "front" {
  bucket = aws_s3_bucket.front.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 — criptografia server-side com chaves gerenciadas pela AWS (AES256)
resource "aws_s3_bucket_server_side_encryption_configuration" "front" {
  bucket = aws_s3_bucket.front.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block Public Access — impede ACL/policy pública (acesso só via CloudFront OAC)
# Entrevista: "Como o front fica acessível se o bucket é privado?"
# → CloudFront usa Origin Access Control (OAC) com policy que permite só a distribuição específica.
resource "aws_s3_bucket_public_access_block" "front" {
  bucket = aws_s3_bucket.front.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Policy do bucket está em cloudfront.tf (depende do ARN da distribuição CloudFront)
