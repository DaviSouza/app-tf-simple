# =============================================================================
# VARIABLES — parâmetros de entrada do módulo/root module
# =============================================================================
# Entrevista: "Como passar valores para variables?"
# → terraform.tfvars, -var="nome=valor", TF_VAR_nome env var, ou default no bloco.
# type constraint valida o tipo em plan/apply (string, number, bool, list, map, object).
# sensitive = true oculta valor no output do plan (não criptografa no state!).
# =============================================================================

# --- Região e naming ---

variable "aws_region" {
  description = "Região AWS onde a maioria dos recursos será criada. WAF CloudFront continua em us-east-1 via provider alias."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo para tags Name e nomes de recursos. Facilita identificar recursos no console e evitar conflitos de nome."
  type        = string
  default     = "app-tf-simple"
}

# --- Rede (VPC) ---

variable "vpc_cidr" {
  description = "Bloco CIDR da VPC (/16 = 65.536 IPs). Subnets são derivadas com cidrsubnet() nos locals."
  type        = string
  default     = "10.0.0.0/16"
}

# --- S3 ---

variable "s3_bucket_name" {
  description = "Nome global único do bucket S3. Se null, Terraform gera automaticamente com random_id (nomes S3 são únicos mundialmente)."
  type        = string
  default     = null
}

# --- RDS PostgreSQL ---

variable "db_username" {
  description = "Usuário master do PostgreSQL. Criado na instância RDS e armazenado no Secrets Manager."
  type        = string
  default     = "app"
}

variable "db_name" {
  description = "Nome do database inicial criado na instância (não confundir com db_instance identifier)."
  type        = string
  default     = "app"
}

variable "db_engine_version" {
  description = "Versão major do engine PostgreSQL. AWS gerencia patches minor automaticamente."
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "Classe da instância RDS (CPU/RAM). t4g = Graviton (ARM), geralmente mais barato."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Storage inicial em GB (gp2). Pode crescer até max_allocated_storage se autoscaling habilitado."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Limite máximo de storage com autoscaling. Entrevista: evita crescimento infinito de disco."
  type        = number
  default     = 100
}

variable "db_backup_retention_period" {
  description = "Dias de retenção de backup automático. Free Tier RDS permite no máximo 1 dia."
  type        = number
  default     = 1
}

variable "db_deletion_protection" {
  description = "Se true, impede destroy acidental via console/API. Terraform destroy também falha até desabilitar."
  type        = bool
  default     = true
}

variable "db_publicly_accessible" {
  description = "Se true, RDS recebe IP público nas subnets públicas. Útil para DBeaver local; em produção use VPN/bastion."
  type        = bool
  default     = true
}

# --- Lambda auth-service (API Gateway) ---

variable "auth_lambda_source_dir" {
  description = "Diretório com código Node.js da Lambda auth-service (precisa de node_modules). null = caminho padrão do projeto CDK."
  type        = string
  default     = null
}

# --- ECS / cadastro-cliente (app Rust) ---

variable "cadastro_cliente_image_tag" {
  description = "Tag da imagem Docker no ECR. Terraform referencia a URI; o push da imagem é feito fora do Terraform (CI/CD)."
  type        = string
  default     = "latest"
}

variable "ecs_instance_type" {
  description = "Tipo EC2 do cluster ECS. ECS EC2 mode = você gerencia as instâncias (vs Fargate = serverless)."
  type        = string
  default     = "t3.small"
}

variable "ecs_asg_min_size" {
  description = "Mínimo de instâncias EC2 no Auto Scaling Group do cluster ECS."
  type        = number
  default     = 1
}

variable "ecs_asg_max_size" {
  description = "Máximo de instâncias EC2 no ASG. Limita custo e capacidade de scale-out."
  type        = number
  default     = 2
}

variable "ecs_asg_desired_capacity" {
  description = "Capacidade desejada do ASG. ECS agenda tasks nessas instâncias."
  type        = number
  default     = 1
}

variable "ecs_service_desired_count" {
  description = "Número de tasks (containers) rodando simultaneamente no serviço cadastro-cliente."
  type        = number
  default     = 1
}

variable "app_container_port" {
  description = "Porta TCP exposta pelo container Rust. ALB encaminha tráfego para hostPort dinâmico (32768-65535)."
  type        = number
  default     = 8002
}

variable "app_container_memory" {
  description = "Memória reservada para o container em MiB. ECS EC2 reserva memória na instância host."
  type        = number
  default     = 512
}

variable "app_rust_log" {
  description = "Nível de log RUST_LOG passado como variável de ambiente ao container."
  type        = string
  default     = "info"
}

# --- ECS / insights (realtime + MCP) ---

variable "front_insights_image_tag" {
  description = "Tag da imagem front-insights no ECR para o serviço de realtime/SSE."
  type        = string
  default     = "latest"
}

variable "insights_service_email" {
  description = "Email usado pelo serviço insights para autenticar via POST /auth/login no API Gateway."
  type        = string
  default     = "admin@dsmercado.com"
  sensitive   = true # Oculta no plan output; armazenado no Secrets Manager
}

variable "insights_service_password" {
  description = "Senha do serviço insights. sensitive=true evita vazamento no terminal durante terraform plan."
  type        = string
  default     = "admin"
  sensitive   = true
}

variable "insights_host" {
  description = "Host customizado (ex.: realtime.seudominio.com). Se definido, ALB roteia por host-header em vez de path /realtime/*."
  type        = string
  default     = null
}

variable "cors_origin" {
  description = "Origem permitida no CORS do serviço insights. * = qualquer origem (dev); em prod use domínio específico."
  type        = string
  default     = "*"
}

variable "insights_interval_ms" {
  description = "Intervalo de polling do serviço insights em milissegundos."
  type        = number
  default     = 30000
}

variable "insights_container_memory" {
  description = "Memória reservada para o container insights (MiB)."
  type        = number
  default     = 384
}

variable "insights_service_desired_count" {
  description = "Número de tasks do serviço ECS insights."
  type        = number
  default     = 1
}

variable "insights_listener_rule_priority" {
  description = "Prioridade da regra no ALB listener. Menor número = avaliada primeiro. Default (cadastro-cliente) usa prioridade implícita baixa."
  type        = number
  default     = 25
}

# --- CI/CD (Opção C: GitHub + CodePipeline + CodeBuild) ---

variable "enable_cicd" {
  description = "Se true e github_owner estiver preenchido, cria CodePipeline + CodeBuild para os apps."
  type        = bool
  default     = true
}

variable "github_owner" {
  description = "Usuário ou organização no GitHub (ex.: davisouza). Vazio desativa criação dos pipelines."
  type        = string
  default     = "DaviSouza"
}

variable "github_cadastro_cliente_repo" {
  description = "Nome do repositório GitHub do app-cadastro-cliente."
  type        = string
  default     = "app-cadastro-cliente"
}

variable "github_front_client_repo" {
  description = "Nome do repositório GitHub do app-front-client."
  type        = string
  default     = "app-front-client"
}

variable "github_cadastro_cliente_branch" {
  description = "Branch do app-cadastro-cliente que dispara o pipeline (deploy ECS)."
  type        = string
  default     = "main"
}

variable "github_front_client_branch" {
  description = "Branch do app-front-client que dispara o pipeline (deploy S3/CloudFront)."
  type        = string
  default     = "master"
}

variable "github_connection_arn" {
  description = "ARN de uma CodeConnections GitHub já autorizada. Se null, Terraform cria uma conexão (fica PENDING até autorizar no console)."
  type        = string
  default     = null
}
