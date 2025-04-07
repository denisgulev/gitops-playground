variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "prefix" {
  type        = string
  description = "Prefix for resources"
}

variable "domain_name" {
  type        = string
  description = "Domain name for the website"
}

variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket"
}

variable "common_tags" {
  type        = map(string)
  description = "Common tags for all resources"
}

variable "ec2_dns" {
  type    = string
  default = "fallback.example.com"
}
