# =============================================================================
# VPC STACK — rede isolada na AWS
# =============================================================================
# Arquitetura: 2 AZs, 2 subnets públicas + 2 privadas, 1 NAT Gateway.
# Entrevista: "Por que subnets públicas E privadas?"
# → Públicas: recursos com IP público (ALB, NAT). Privadas: workloads (ECS) sem exposição direta.
# Entrevista: "O que faz o NAT Gateway?"
# → Permite que instâncias em subnet privada acessem internet (pull ECR, updates) sem receber tráfego inbound.
# =============================================================================

# DATA: lista AZs disponíveis na região (ex.: us-east-1a, us-east-1b)
data "aws_availability_zones" "available" {
  state = "available" # Ignora AZs deprecated ou unavailable
}

# LOCALS — valores calculados reutilizados no módulo (não são variáveis de entrada)
locals {
  # Pega as 2 primeiras AZs (equivalente a maxAzs: 2 no CDK)
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # cidrsubnet(parent, newbits, netnum):
  #   /16 + 2 newbits = /18 por subnet
  #   netnum 0,1 → públicas | netnum 2,3 → privadas (sem overlap de CIDR)
  public_subnet_cidrs  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 2, i)]
  private_subnet_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 2, i + 2)]
}

# VPC — rede virtual isolada (equivalente a uma datacenter lógico)
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true # Instâncias recebem hostname DNS (necessário para alguns serviços)
  enable_dns_support   = true # Resolve nomes DNS dentro da VPC

  tags = {
    Name = "${var.project_name}/vpc"
  }
}

# Internet Gateway — porta de saída/entrada da VPC para a internet pública
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}/vpc"
  }
}

# Subnets PÚBLICAS — rota default 0.0.0.0/0 → IGW; map_public_ip_on_launch = IP público automático
resource "aws_subnet" "public" {
  count = length(local.azs) # count cria N recursos indexados [0], [1]

  vpc_id                  = aws_vpc.main.id
  availability_zone       = local.azs[count.index]
  cidr_block              = local.public_subnet_cidrs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}/vpc/public-${local.azs[count.index]}"
  }
}

# Subnets PRIVADAS — sem IP público; saída internet via NAT Gateway
resource "aws_subnet" "private" {
  count = length(local.azs)

  vpc_id            = aws_vpc.main.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.private_subnet_cidrs[count.index]

  tags = {
    Name = "${var.project_name}/vpc/private-${local.azs[count.index]}"
  }
}

# Elastic IP — IP público estático para o NAT Gateway (domain = vpc, não EC2-Classic)
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}/vpc/nat"
  }

  depends_on = [aws_internet_gateway.main] # IGW deve existir antes do EIP ser associado ao NAT
}

# NAT Gateway — colocado em subnet pública; traduz tráfego de saída das privadas
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id # Apenas 1 NAT (custo vs HA — produção usa 1 NAT por AZ)

  tags = {
    Name = "${var.project_name}/vpc/nat"
  }

  depends_on = [aws_internet_gateway.main]
}

# Route table PÚBLICA — todo tráfego externo vai para o Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}/vpc/public"
  }
}

# Route table PRIVADA — tráfego externo vai para o NAT (não para IGW diretamente)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}/vpc/private"
  }
}

# Associa cada subnet pública à route table pública
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Associa cada subnet privada à route table privada
resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Security Group padrão da VPC — CDK também o restringe (sem regras = deny all implícito para inbound)
# Entrevista: "O que acontece se não mexer no default SG?"
# → AWS cria com self-referencing allow; aqui zeramos regras customizadas forçando uso de SGs explícitos.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}
