terraform {
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
