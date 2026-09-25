# =============================================================================
# CLOUDFRONT + S3 POLICY — CDN global para SPA + proxy realtime
# =============================================================================
# Entrevista: "O que é OAC (Origin Access Control)?"
# → Substitui OAI legado. CloudFront assina requests S3 com SigV4; bucket permanece privado.
# ordered_cache_behavior: regras por path (/realtime/* → ALB, resto → S3).
# custom_error_response 403/404→index.html: padrão SPA (client-side routing).
# =============================================================================

# OAC — identidade que CloudFront usa para acessar o bucket S3 privado
resource "aws_cloudfront_origin_access_control" "front" {
  name                              = "${var.project_name}-front-oac"
  description                       = "OAC para bucket ${var.project_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "front" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  comment             = "${var.project_name} front SPA"
  web_acl_id          = aws_wafv2_web_acl.cloudfront.arn # WAF em us-east-1 protege esta distribuição

  # Origin 1: arquivos estáticos do front (HTML, JS, CSS)
  origin {
    domain_name              = aws_s3_bucket.front.bucket_regional_domain_name
    origin_id                = "s3-front"
    origin_access_control_id = aws_cloudfront_origin_access_control.front.id
  }

  # Origin 2: ALB para rotas /realtime/* (SSE, WebSocket-like, API realtime)
  origin {
    domain_name = aws_lb.cadastro_cliente.dns_name
    origin_id   = "alb-realtime"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # ALB interno fala HTTP; CloudFront→viewer é HTTPS
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Comportamento default: cache agressivo para assets estáticos
  default_cache_behavior {
    target_origin_id       = "s3-front"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed policy: CachingOptimized
    compress               = true
  }

  # Comportamento específico: /realtime/* vai ao ALB, sem cache (SSE/eventos)
  ordered_cache_behavior {
    path_pattern             = "/realtime/*"
    target_origin_id         = "alb-realtime"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
    compress                 = false
  }

  # SPA fallback: rotas client-side (ex.: /clientes/123) retornam index.html
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # *.cloudfront.net — em prod use ACM + domínio customizado
  }

  tags = {
    Name = "${var.project_name}/front-cdn"
  }
}

# Bucket policy — duas regras: deny HTTP + allow CloudFront OAC
resource "aws_s3_bucket_policy" "front" {
  bucket = aws_s3_bucket.front.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.front.arn,
          "${aws_s3_bucket.front.arn}/*",
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.front.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.front.arn
          }
        }
      },
    ]
  })

  depends_on = [aws_cloudfront_distribution.front]
}
