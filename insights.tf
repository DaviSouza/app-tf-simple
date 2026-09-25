# =============================================================================
# INSIGHTS — serviço realtime/SSE + MCP no mesmo cluster ECS
# =============================================================================
# Compartilha ALB com cadastro-cliente via listener rule (path /realtime/* ou host-header).
# Dois containers lógicos na mesma task: HTTP 8787 (realtime) + MCP 8899 (localhost only).
# Entrevista: "deployment_circuit_breaker no ECS?"
# → Se new tasks falham health check repetidamente, rollback automático para task definition anterior.
# =============================================================================

locals {
  api_gateway_base_url = trimsuffix(aws_apigatewayv2_api.cadastro_cliente.api_endpoint, "/")

  insights_image = "${aws_ecr_repository.main["front_insights"].repository_url}:${var.front_insights_image_tag}"

  # URL SSE sugerida para VITE_REALTIME_SSE_URL — prioridade: cors_origin > insights_host > CloudFront
  insights_host_hint = (
    var.cors_origin != null && var.cors_origin != "" && var.cors_origin != "*"
    ? "${trimsuffix(var.cors_origin, "/")}/realtime/events"
    : var.insights_host != null && var.insights_host != ""
    ? "https://${var.insights_host}/realtime/events"
    : "https://${aws_cloudfront_distribution.front.domain_name}/realtime/events"
  )

  use_insights_host_header = var.insights_host != null && var.insights_host != ""
}

resource "aws_secretsmanager_secret" "insights_config" {
  name_prefix             = "${var.project_name}-insights-"
  description             = "Credenciais do serviço MCP/realtime para /auth/login"
  recovery_window_in_days = 7

  tags = {
    Name = "${var.project_name}/insights-config"
  }
}

resource "aws_secretsmanager_secret_version" "insights_config" {
  secret_id = aws_secretsmanager_secret.insights_config.id
  secret_string = jsonencode({
    INSIGHTS_SERVICE_EMAIL    = var.insights_service_email
    INSIGHTS_SERVICE_PASSWORD = var.insights_service_password
  })
}

resource "aws_cloudwatch_log_group" "insights" {
  name              = "/ecs/${var.project_name}/insights"
  retention_in_days = 7

  tags = {
    Name = "${var.project_name}/insights-logs"
  }
}

resource "aws_iam_role" "insights_task_execution" {
  name = "${var.project_name}-insights-task-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.project_name}/insights-task-execution-role"
  }
}

resource "aws_iam_role_policy" "insights_task_execution" {
  name = "${var.project_name}-insights-task-execution"
  role = aws_iam_role.insights_task_execution.id

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
        Resource = "${aws_cloudwatch_log_group.insights.arn}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = aws_secretsmanager_secret.insights_config.arn
      },
    ]
  })
}

resource "aws_iam_role" "insights_task" {
  name = "${var.project_name}-insights-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = {
    Name = "${var.project_name}/insights-task-role"
  }
}

resource "aws_ecs_task_definition" "insights" {
  family                   = "${var.project_name}-insights"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.insights_task_execution.arn
  task_role_arn            = aws_iam_role.insights_task.arn

  container_definitions = jsonencode([{
    name      = "Insights"
    image     = local.insights_image
    essential = true
    memory    = var.insights_container_memory
    environment = [
      { name = "PORT", value = "8787" },
      { name = "MCP_PORT", value = "8899" },
      { name = "API_GATEWAY_URL", value = local.api_gateway_base_url },
      { name = "CLIENTES_API_URL", value = local.api_gateway_base_url },
      { name = "REALTIME_HTTP_URL", value = "http://127.0.0.1:8787/realtime" },
      { name = "MCP_URL", value = "http://127.0.0.1:8899/mcp" },
      { name = "CORS_ORIGIN", value = var.cors_origin },
      { name = "INTERVAL_MS", value = tostring(var.insights_interval_ms) },
    ]
    portMappings = [
      { containerPort = 8787, hostPort = 0, protocol = "tcp" },
      { containerPort = 8899, hostPort = 0, protocol = "tcp" },
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.insights.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "insights"
      }
    }
    secrets = [
      { name = "INSIGHTS_SERVICE_EMAIL", valueFrom = "${aws_secretsmanager_secret.insights_config.arn}:INSIGHTS_SERVICE_EMAIL::" },
      { name = "INSIGHTS_SERVICE_PASSWORD", valueFrom = "${aws_secretsmanager_secret.insights_config.arn}:INSIGHTS_SERVICE_PASSWORD::" },
    ]
  }])

  depends_on = [aws_secretsmanager_secret_version.insights_config]
}

resource "aws_lb_target_group" "insights" {
  name_prefix = "ins-"
  port        = 8787
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  deregistration_delay = 30

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
    Name = "${var.project_name}/insights-tg"
  }
}

# Listener Rule — roteamento condicional no ALB (prioridade 25)
# dynamic block: cria condition host_header OU path_pattern conforme insights_host
resource "aws_lb_listener_rule" "insights" {
  listener_arn = aws_lb_listener.http.arn
  priority     = var.insights_listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.insights.arn
  }

  dynamic "condition" {
    for_each = local.use_insights_host_header ? [var.insights_host] : []
    content {
      host_header {
        values = [condition.value]
      }
    }
  }

  dynamic "condition" {
    for_each = local.use_insights_host_header ? [] : [1]
    content {
      path_pattern {
        values = ["/realtime", "/realtime/*"]
      }
    }
  }
}

resource "aws_ecs_service" "insights" {
  name            = "${var.project_name}-insights"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.insights.arn
  desired_count   = var.insights_service_desired_count
  launch_type     = "EC2"

  health_check_grace_period_seconds = 60

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.insights.arn
    container_name   = "Insights"
    container_port   = 8787
  }

  depends_on = [aws_lb_listener_rule.insights]

  tags = {
    Name = "${var.project_name}/insights-service"
  }
}
