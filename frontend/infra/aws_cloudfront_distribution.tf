# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control
resource "aws_cloudfront_origin_access_control" "current" {
  name                              = "OAC ${data.aws_s3_bucket.static_website.bucket}"
  description                       = "Origin Access Controls for Static Website Hosting on ${var.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution
resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = data.aws_s3_bucket.static_website.bucket_regional_domain_name
    origin_id                = "${local.prefix}.${var.bucket_name}-origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.current.id
  }

  origin {
    domain_name = local.ec2_dns
    origin_id   = "EC2-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # or "match-viewer" if you want to enforce HTTPS for certain viewers
      origin_ssl_protocols   = ["TLSv1.2"] # For HTTPS, if you configure SSL on EC2
    }
  }

  comment         = "${local.prefix}.${var.domain_name} distribution"
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100" // Use only North America and Europe
  aliases = [
    "${local.prefix}.${var.domain_name}",
    "www.${local.prefix}.${var.domain_name}",
    "api.${var.domain_name}"
  ]
  default_root_object = "index.html"

  # Cache Behavior for API (EC2)
  ordered_cache_behavior {
    cache_policy_id        = aws_cloudfront_cache_policy.api_cache_policy.id
    path_pattern           = "/api/*"
    target_origin_id       = "EC2-origin"
    viewer_protocol_policy = "allow-all"

    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD"]
  }

  # Cache Behavior for Grafana (/grafana/*)
  ordered_cache_behavior {
    path_pattern           = "/grafana/*"
    target_origin_id       = "EC2-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id = aws_cloudfront_cache_policy.grafana_cache_policy.id
  }

  # Default Cache Behavior for Static Content (S3)
  default_cache_behavior {
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    target_origin_id       = "${local.prefix}.${var.bucket_name}-origin"

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.www_redirect.arn
    }
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.ssl_cert_validation.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
  tags = var.common_tags
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_cache_policy
resource "aws_cloudfront_cache_policy" "api_cache_policy" {
  name = "api-cache-policy-cors"

  default_ttl = 0 # Don't cache for long to avoid stale CORS responses
  max_ttl     = 10
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    headers_config {
      header_behavior = "whitelist"
      headers {
        items = [
          "Access-Control-Request-Headers",
          "Access-Control-Request-Method",
          "Origin"
        ]
      }
    }
    cookies_config {
      cookie_behavior = "none" # If you use cookies in API, otherwise "none"
    }
    query_strings_config {
      query_string_behavior = "none" # If your API uses query params
    }
  }
}

# cache policy for Grafana
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_cache_policy
resource "aws_cloudfront_cache_policy" "grafana_cache_policy" {
  name = "grafana-cache-policy"

  default_ttl = 1
  max_ttl     = 60
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    headers_config {
      header_behavior = "whitelist"
      headers {
        items = [
          "Host",
          "Origin",
          "Referer",
          "Authorization",
          "Access-Control-Request-Method",
          "Access-Control-Request-Headers",
          "CloudFront-Forwarded-Proto"
        ]
      }
    }
    cookies_config {
      cookie_behavior = "all"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
  }
}

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_function
resource "aws_cloudfront_function" "www_redirect" {
  name    = "${local.prefix}-www-redirect"
  comment = "Redirects www to root domain"
  runtime = "cloudfront-js-1.0"
  code    = file("./cloudfront_function.js")
  publish = true
}

data "aws_ssm_parameter" "ec2_dns" {
  name = "/infra/ec2/public_dns"
}

