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

  default_cache_behavior {
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
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

# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_function
resource "aws_cloudfront_function" "www_redirect" {
  name    = "${local.prefix}-www-redirect"
  comment = "Redirects www to root domain"
  runtime = "cloudfront-js-1.0"
  code    = file("./cloudfront_function.js")
  publish = true
}
