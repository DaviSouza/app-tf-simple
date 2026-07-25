data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

locals {

  db_credentials = jsondecode(aws_secretsmanager_secret_version.db_credentials.secret_string)

  database_url = "postgres://${local.db_credentials.username}:${local.db_credentials.password}@${aws_db_instance.postgres.address}:${aws_db_instance.postgres.port}/${var.db_name}?sslmode=verify-full&sslrootcert=./global-bundle.pem"

  app_config = {
    DATABASE_URL      = local.database_url
    COGNITO_CLIENT_ID = aws_cognito_user_pool_client.main.id
    COGNITO_AUTHORITY = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
    HOST_API_RUST     = "0.0.0.0"
    PORT_API_RUST     = tostring(var.app_container_port)
    RUST_LOG          = var.app_rust_log
  }

  cadastro_cliente_image = "${aws_ecr_repository.main["cadastro_cliente"].repository_url}:${var.cadastro_cliente_image_tag}"
}

resource "aws_secretsmanager_secret" "app_config" {
  name_prefix             = "${var.project_name}-cadastro-cliente-"
  description             = "Variáveis de ambiente do app-cadastro-cliente (ECS)"
  recovery_window_in_days = 7

  tags = {
    Name = "${var.project_name}/cadastro-cliente-app-config"
  }
}

resource "aws_secretsmanager_secret_version" "app_config" {
  secret_id     = aws_secretsmanager_secret.app_config.id
  secret_string = jsonencode(local.app_config)
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  tags = {
    Name = "${var.project_name}/cluster"
  }
}

resource "aws_security_group" "ecs_instance" {
  name        = "${var.project_name}-ecs-instance"
  description = "ECS container instances (${var.project_name})"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}/ecs-instance"
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.project_name}-alb"
  description = "ALB do cadastro-cliente (${var.project_name})"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
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
    Name = "${var.project_name}/alb"
  }
}

resource "aws_security_group_rule" "alb_to_ecs" {
  type                     = "ingress"
  description              = "Load balancer to ECS dynamic host port"
  from_port                = 32768
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.ecs_instance.id
  source_security_group_id = aws_security_group.alb.id
}

resource "aws_iam_role" "ecs_instance" {
  name = "${var.project_name}-ecs-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.project_name}/ecs-instance-role"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance" {
  name = "${var.project_name}-ecs-instance"
  role = aws_iam_role.ecs_instance.name
}

resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.project_name}-ecs-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.ecs_instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ecs_instance.arn
  }

  vpc_security_group_ids = [aws_security_group.ecs_instance.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}/ecs-instance"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "ecs" {
  name_prefix         = "${var.project_name}-ecs-"
  vpc_zone_identifier = aws_subnet.private[*].id
  desired_capacity    = var.ecs_asg_desired_capacity
  min_size            = var.ecs_asg_min_size
  max_size            = var.ecs_asg_max_size

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}/ecs-asg"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "cadastro_cliente" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = {
    Name = "${var.project_name}/cadastro-cliente-alb"
  }
}

resource "aws_lb_target_group" "cadastro_cliente" {
  name_prefix = "cc-"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.project_name}/cadastro-cliente-tg"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.cadastro_cliente.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.cadastro_cliente.arn
  }
}

resource "aws_cloudwatch_log_group" "cadastro_cliente" {
  name              = "/ecs/${var.project_name}/cadastro-cliente"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}/cadastro-cliente-logs"
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.project_name}/ecs-task-execution-role"
  }
}

resource "aws_iam_role_policy" "ecs_task_execution" {
  name = "${var.project_name}-ecs-task-execution"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = "${aws_cloudwatch_log_group.cadastro_cliente.arn}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = aws_secretsmanager_secret.app_config.arn
      },
    ]
  })
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.project_name}-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.project_name}/ecs-task-role"
  }
}

resource "aws_ecs_task_definition" "cadastro_cliente" {
  family                   = "${var.project_name}-cadastro-cliente"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "web"
    image     = local.cadastro_cliente_image
    essential = true
    memory    = var.app_container_memory
    portMappings = [{
      containerPort = var.app_container_port
      hostPort      = 0
      protocol      = "tcp"
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.cadastro_cliente.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "cadastro-cliente"
      }
    }

    secrets = [
      { name = "DATABASE_URL", valueFrom = "${aws_secretsmanager_secret.app_config.arn}:DATABASE_URL::" },
      { name = "COGNITO_CLIENT_ID", valueFrom = "${aws_secretsmanager_secret.app_config.arn}:COGNITO_CLIENT_ID::" },
      { name = "COGNITO_AUTHORITY", valueFrom = "${aws_secretsmanager_secret.app_config.arn}:COGNITO_AUTHORITY::" },
      { name = "HOST_API_RUST", valueFrom = "${aws_secretsmanager_secret.app_config.arn}:HOST_API_RUST::" },
      { name = "PORT_API_RUST", valueFrom = "${aws_secretsmanager_secret.app_config.arn}:PORT_API_RUST::" },
      { name = "RUST_LOG", valueFrom = "${aws_secretsmanager_secret.app_config.arn}:RUST_LOG::" },
    ]
  }])
}

resource "aws_ecs_service" "cadastro_cliente" {
  name            = "${var.project_name}-cadastro-cliente"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.cadastro_cliente.arn
  desired_count   = var.ecs_service_desired_count
  launch_type     = "EC2"

  health_check_grace_period_seconds = 60

  load_balancer {
    target_group_arn = aws_lb_target_group.cadastro_cliente.arn
    container_name   = "web"
    container_port   = var.app_container_port
  }

  depends_on = [aws_lb_listener.http]

  tags = {
    Name = "${var.project_name}/cadastro-cliente-service"
  }
}
