# =============================================================================
# COGNITO — autenticação gerenciada (User Pool + App Client)
# =============================================================================
# Entrevista: "Cognito User Pool vs Identity Pool?"
# → User Pool: diretório de usuários + login (JWT). Identity Pool: troca identidade por credenciais AWS temporárias.
# Este projeto usa User Pool + JWT no API Gateway authorizer.
# =============================================================================

resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-user-pool"

  auto_verified_attributes = ["email"] # Envia código de verificação por email no sign-up

  username_attributes = ["email"] # Login com email em vez de username arbitrário

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_uppercase = true
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  tags = {
    Name = "${var.project_name}/user-pool"
  }
}

# App Client — representa a aplicação front-end que usa o User Pool
resource "aws_cognito_user_pool_client" "main" {
  name         = "${var.project_name}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false # false = client público (SPA/mobile); true = backend confidencial

  # Fluxos de auth habilitados — SRP é mais seguro que password direto; incluímos ambos para flexibilidade
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_ADMIN_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
