locals {

  ecr_repositories = {
    cadastro_cliente = "cadastro-cliente"
    front_client     = "front-client"
    front_insights   = "front-insights"
  }
}

resource "aws_ecr_repository" "main" {
  for_each = local.ecr_repositories

  name                 = each.value
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name = "${var.project_name}/${each.value}"
  }
}
