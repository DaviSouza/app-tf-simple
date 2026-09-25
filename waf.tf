# =============================================================================
# WAF — Web Application Firewall para CloudFront
# =============================================================================
# Entrevista: "WAF REGIONAL vs CLOUDFRONT scope?"
# → CLOUDFRONT: protege distribuições CloudFront (criado em us-east-1).
# → REGIONAL: protege ALB, API Gateway regional, AppSync (na região do recurso).
# Managed rule groups = regras mantidas pela AWS (OWASP, bots, SQLi...).
# =============================================================================

resource "aws_wafv2_web_acl" "cloudfront" {
  provider = aws.us_east_1 # OBRIGATÓRIO para scope CLOUDFRONT

  name        = "${var.project_name}-front-waf"
  description = "WAF para CloudFront - ${var.project_name}"
  scope       = "CLOUDFRONT"

  default_action {
    allow {} # Tráfego que não bate em nenhuma regra → permitido
  }

  rule {
    name     = "AWSManagedCommonRuleSet"
    priority = 0 # Menor = avaliada primeiro

    override_action {
      none {} # Usa ação default de cada regra do managed group (geralmente BLOCK)
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "aws-common"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "front-web-acl"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.project_name}/front-waf"
  }
}
