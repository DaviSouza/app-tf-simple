resource "aws_security_group" "db" {
  name        = "${var.project_name}-db"
  description = "PostgreSQL access from VPC and clients externos (DBeaver)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "PostgreSQL from VPC CIDR"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  ingress {
    description = "PostgreSQL from internet (DBeaver) — NÃO usar em produção"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}/db"
  }
}

resource "aws_db_subnet_group" "public" {
  name        = "${var.project_name}-postgres-public"
  description = "Subnets públicas para RDS acessível via internet (DBeaver)"
  subnet_ids  = aws_subnet.public[*].id

  tags = {
    Name = "${var.project_name}/postgres-public"
  }
}

resource "aws_secretsmanager_secret" "db_credentials" {
  name_prefix             = "${var.project_name}-db-"
  description             = "Credenciais PostgreSQL (${var.project_name})"
  recovery_window_in_days = 7

  tags = {
    Name = "${var.project_name}/db-credentials"
  }
}

resource "random_password" "db" {
  length           = 30
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
  })
}

resource "aws_db_instance" "postgres" {
  identifier = "${var.project_name}-postgres"

  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp2"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.public.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = var.db_publicly_accessible
  multi_az               = false

  backup_retention_period   = var.db_backup_retention_period
  deletion_protection       = var.db_deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-postgres-final"

  copy_tags_to_snapshot = true

  tags = {
    Name = "${var.project_name}/postgres"
  }

  depends_on = [aws_secretsmanager_secret_version.db_credentials]
}
