variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "instance_type" {
  description = "Instance Type"
  type        = string
}

variable "domain_name" {
  description = "The domain name to use for the API (e.g., example.com)"
  type        = string
}

variable "subdomain" {
  description = "The subdomain to point to EC2 EIP (e.g., api)"
  type        = string
  default     = "api"
}

variable "hosted_zone_id" {
  description = "The ID of the Route 53 hosted zone"
  type        = string
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH into the EC2 instance (e.g., your office or home IP: 203.0.113.0/32)"
  type        = string
}
