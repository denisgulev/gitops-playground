
# Backend Infrastructure

Terraform configuration for the Flask backend running on AWS EC2, managed via Terraform Cloud (workspace: `Backend`).

## main.tf

Defines the Terraform Cloud backend, the AWS provider, and the EC2 instance resource.

#### aws_instance

Provisions the EC2 instance running the Flask application.

Key settings:
- **AMI**: Amazon Linux 2023 (ARM, `ami-00ffa5b66c55581f9`)
- **user_data**: Bootstrapped via `user_data.sh` using `templatefile`, which injects `aws_region` and `api_domain` variables
- **user_data_replace_on_change**: Any change to `user_data.sh` destroys and recreates the instance
- **iam_instance_profile**: Grants the instance permissions to write CloudWatch Logs

## network.tf

Defines the VPC and all networking resources.

#### aws_vpc

Creates a dedicated VPC (`10.0.0.0/16`) with DNS hostnames enabled.

#### aws_subnet (public)

Two public subnets (`10.0.1.0/24`, `10.0.2.0/24`) across two availability zones — the EC2 instance lives here.

#### aws_subnet (private)

Two private subnets (`10.0.101.0/24`, `10.0.102.0/24`) reserved for future use (databases, internal services). `map_public_ip_on_launch` is disabled.

#### aws_security_group

Two security groups:
- `flask-sg-http`: Allows inbound traffic on port 80
- `flask-sg-https`: Allows inbound traffic on port 443

HTTP/HTTPS ingress is restricted to the CloudFront managed prefix list so EC2 is not directly accessible from the internet.  
SSH ingress is controlled via `var.ssh_allowed_cidr`.

#### aws_internet_gateway / aws_route_table

Provides internet access for the public subnets.

## aws_eip.tf

#### aws_eip

Allocates a static Elastic IP and associates it with the EC2 instance. This ensures the public IP remains stable across instance replacements triggered by `user_data` changes.

## aws_ssm_parameter.tf

#### aws_ssm_parameter

Stores the EIP public DNS at `/infra/ec2/public_dns` in SSM Parameter Store. The frontend Terraform workspace reads this value to configure the CloudFront EC2 origin, ensuring the correct DNS is always referenced even after instance recreation.

## iam.tf

#### aws_iam_role / aws_iam_role_policy (CloudWatch)

IAM role attached to the EC2 instance granting permissions to:
- `logs:CreateLogGroup`
- `logs:CreateLogStream`
- `logs:PutLogEvents`
- `logs:DescribeLogStreams`

This enables the Flask app to ship logs to CloudWatch Logs via `watchtower`.

#### aws_iam_role / aws_iam_role_policy (Prefix List)

IAM role granting permissions to describe and enumerate AWS managed prefix lists (`ec2:DescribeManagedPrefixLists`, `ec2:GetManagedPrefixListEntries`). Used to automatically retrieve the CloudFront origin-facing prefix list for security group ingress rules.

## variables.tf

| Variable | Description |
|---|---|
| `aws_region` | AWS region to deploy resources |
| `instance_type` | EC2 instance type |
| `domain_name` | Base domain name (e.g. `denisgulev.com`) |
| `ssh_allowed_cidr` | CIDR block allowed to SSH into the instance |

## outputs.tf

| Output | Description |
|---|---|
| `flask_app_public_ip` | Elastic IP address of the EC2 instance |
| `cloudfront_prefix_list_id` | ID of the CloudFront managed prefix list |

## user_data.sh

Bootstrap script executed on first EC2 launch. Uses `templatefile` so Terraform variables can be injected directly.

Responsibilities:
- Updates the system and installs Nginx and Docker
- Enables Docker and adds `ec2-user` to the `docker` group
- Configures Nginx as a reverse proxy forwarding port 80 → port 8000 (Gunicorn)
- Sets CORS headers for preflight (`OPTIONS`) and standard requests
- Creates `/var/log/flask` with open permissions so the container's non-root user can write logs

## VCS Integration

The workspace is connected to the `backend/infra/` directory in the GitHub repository. Changes pushed to `main` that touch `backend/infra/` trigger a Terraform plan in Terraform Cloud.

Pre-requisites:
- All input variables must be set as Terraform Variables in the Cloud workspace.

To connect a workspace to VCS:
1. Go to your workspace → **Settings** → **Version Control**
2. Choose the VCS workflow, select the repository
3. Set the following:
   - **Terraform Working Directory** → `backend/infra`
   - **VCS branch** → `main`
   - **Automatic Run Triggering** → Patterns → `/backend/infra`

## How to Set Up

1. Create a remote state S3 bucket using the script in the `bin/` directory (if not using Terraform Cloud)
2. Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in all values
3. Set `ssh_allowed_cidr` to your trusted IP (e.g. `203.0.113.10/32`) — avoid `0.0.0.0/0` in production
4. Run `terraform init`, `terraform plan`, then `terraform apply`