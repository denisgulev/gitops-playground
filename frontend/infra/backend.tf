terraform {
  # `removed` blocks (see removed.tf) need Terraform 1.7 or newer.
  required_version = ">= 1.7"

  cloud {

    organization = "Terraform-bootcamp-aws"

    workspaces {
      name = "Frontend"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
