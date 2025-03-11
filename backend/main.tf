terraform {
  cloud {

    organization = "Terraform-bootcamp-aws"

    workspaces {
      name = "Backend"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_instance" "flask_app" {
  ami                         = "ami-00ffa5b66c55581f9" # Amazon Linux 2023 AMI (ARM)
  instance_type               = var.instance_type
  vpc_security_group_ids      = [aws_security_group.flask_sg.id]
  subnet_id                   = aws_subnet.public_subnet_1.id
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name
  associate_public_ip_address = true
  key_name                    = "flask-key"

  user_data = file("${path.module}/user_data.sh")

  tags = {
    Name = "FlaskAppEC2"
  }
}
