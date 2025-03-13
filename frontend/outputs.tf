output "dist_files" {
  value     = fileset(local.dist_dir, "**/*")
  sensitive = true
}

output "s3_website_endpoint" {
  description = "S3 hosting URL (HTTP)"
  value       = "http://${aws_s3_bucket_website_configuration.website_bucket.website_endpoint}"
  sensitive   = true
}

output "cloudfront_id" {
  description = "Cloudfront ID"
  value       = aws_cloudfront_distribution.s3_distribution.id
  sensitive   = true
}

output "cloudfront_url" {
  description = "Cloudfront distribution URL (HTTPS)"
  value       = "https://${aws_cloudfront_distribution.s3_distribution.domain_name}"
  sensitive   = true
}

output "website_url" {
  description = "Website URL (HTTPS)"
  value       = "https://${local.prefix}.${var.domain_name}"
  sensitive   = true
}
