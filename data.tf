# =============================================================================
# DATA SOURCES — leem recursos EXISTENTES sem criá-los
# =============================================================================
# Entrevista: "Qual a diferença entre resource e data?"
# → resource: CREATE/MANAGE (Terraform é dono do recurso)
# → data: READ ONLY (consulta algo que já existe ou é gerado pela AWS)
# =============================================================================

# Retorna account_id, arn e user_id da conta AWS autenticada.
# Usado em políticas IAM (ARNs com account_id) e no CodeBuild.
data "aws_caller_identity" "current" {}
