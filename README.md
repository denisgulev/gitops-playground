# GitOps Playground

A production-ready boilerplate for deploying a Flask backend API and a static frontend on AWS, fully automated with Terraform and GitHub Actions.

---

## Overview

| Layer | Technology |
|---|---|
| Frontend | Static HTML/JS hosted on S3, served via CloudFront |
| Backend | Flask + Gunicorn in Docker on EC2, behind Nginx |
| Infrastructure | Terraform (Terraform Cloud, two workspaces) |
| DNS | Route 53 (ACM-issued TLS cert) |
| CI/CD | GitHub Actions |
| Observability | Grafana · Loki · Promtail · Tempo · Mimir |

---

## Architecture

```
                         ┌─────────────────────────────────────────┐
                         │           CloudFront Distribution        │
                         │                                         │
                         │  default /*  ──────────►  S3 Origin     │
                         │  /api/*      ──────────►  EC2 Origin    │
                         └──────────┬────────────────────┬─────────┘
                                    │                    │
                           static-website.          api.domain.com
                               domain.com
                                    │                    │
                              ┌─────▼─────┐       ┌─────▼──────┐
                              │ S3 Bucket │       │ EC2 (Nginx) │
                              │  (private)│       │  → Gunicorn │
                              └───────────┘       │  → Flask    │
                                                  └────────────┘
```

Both domains (`static-website.domain.com` and `api.domain.com`) point to the **same CloudFront distribution**. CloudFront uses path-based routing to forward `/api/*` requests to the EC2 origin and everything else to S3.

---

## Repository Structure

```
.
├── backend/
│   ├── app/                    # Go API (Docker image)
│   │   ├── main.go
│   │   ├── main_test.go
│   │   ├── Dockerfile
│   │   └── go.mod / go.sum
│   └── infra/                  # Terraform — EC2, VPC, IAM, EIP, SSM
├── frontend/
│   ├── static/dist/            # Static HTML/JS deployed to S3
│   └── infra/                  # Terraform — S3, CloudFront, ACM, Route 53
├── observability-stack/        # Docker Compose — Grafana, Loki, Promtail, Tempo, Mimir
├── bin/                        # Helper scripts (S3 bucket creation)
└── .github/workflows/          # GitHub Actions CI/CD pipelines
```

---

## Prerequisites

- AWS account with sufficient IAM permissions
- Terraform Cloud account (organization + two workspaces: `Backend`, `Frontend`)
- Docker Hub account
- A registered domain with a Route 53 hosted zone
- GitHub repository secrets configured (see [CI/CD](#cicd) section)

---

## Backend

### Flask Application (`backend/app/`)

The API is a Python Flask app served by Gunicorn. It runs as a non-root Docker container on EC2.

**Endpoints:**

| Method | Path | Description |
|---|---|---|
| GET | `/api/hello` | Returns a greeting |
| GET | `/api/info` | Returns service info |
| GET | `/api/status` | Health check endpoint |

**Logging:**
- Structured logs are written to `/var/log/flask/app.log` (picked up by Promtail) and to CloudWatch Logs via `watchtower`. Both handlers fail gracefully — the app continues running if either destination is unavailable.

**Tracing:**
- OpenTelemetry traces are exported to a Tempo endpoint. The endpoint defaults to `http://tempo:4318/v1/traces` and can be overridden via the `OTEL_EXPORTER_OTLP_ENDPOINT` environment variable.

**Environment variables:**

| Variable | Default | Description |
|---|---|---|
| `AWS_DEFAULT_REGION` | `eu-south-1` | AWS region for CloudWatch |
| `CLOUDWATCH_LOG_GROUP` | `flask-app-logs` | CloudWatch log group name |
| `STATIC_SITE_URL` | `https://static-website.example.com` | Used for 404 redirects |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://tempo:4318/v1/traces` | Tempo trace exporter endpoint |

### Docker (`backend/app/Dockerfile`)

- Base image: `python:3.11-slim`
- Non-root user (`appuser:appgroup`) for runtime security
- Dependencies installed from pinned `requirements.txt`
- Health check: `GET /api/status`
- Entrypoint: `gunicorn --workers 3 --bind 0.0.0.0:8000 app:app`

### EC2 Infrastructure (`backend/infra/`)

Managed via Terraform (workspace: `Backend`). See [backend/infra/README.md](backend/infra/README.md) for full resource documentation.

**Key resources:**
- EC2 instance (Amazon Linux 2023, ARM) bootstrapped via `user_data.sh`
- Elastic IP — stable public address across instance replacements
- Nginx — reverse proxy on port 80 forwarding to Gunicorn on port 8000; handles CORS preflight
- Security groups — HTTP/HTTPS ingress restricted to the CloudFront managed prefix list; SSH restricted via `ssh_allowed_cidr`
- SSM Parameter — EIP DNS stored at `/infra/ec2/public_dns` for cross-workspace consumption

**Terraform variables:**

| Variable | Description |
|---|---|
| `aws_region` | Deployment region |
| `instance_type` | EC2 instance type |
| `domain_name` | Base domain (e.g. `example.com`) |
| `ssh_allowed_cidr` | CIDR block allowed to SSH (restrict in production) |

### Deployment Workflow

1. Develop on a feature branch
2. Open a PR targeting `main` → `terraform-backend.yml` runs checks (fmt, validate, tflint) and a plan; the plan is shown in the run's job summary
3. Review the plan and merge the PR
4. On `main` the workflow plans again and the **Apply** job waits for approval (GitHub Environment `infrastructure`); approve it after reading that plan, and it applies

For application deployments (Docker image updates), everything is driven by `release.yml`:

1. Merge to `main`, then push a version tag on a commit that is on `main` (e.g. `git tag v1.2.0 && git push origin v1.2.0`)
2. The workflow verifies the tag, runs the same checks as a PR (`ci.yml`), builds the image from the tagged commit and pushes it to Docker Hub
3. The **deploy** job then waits for approval (GitHub Environment `production`, required reviewer)
4. After approval it runs the deploy script on EC2 through SSM (canary container, health check, promote; the running container is untouched if the canary fails) and finally checks that the public API reports the new version

**Rollback / redeploy:** Actions → *Release* → *Run workflow* → enter an existing tag (e.g. `v1.1.0`). The image is not rebuilt; the same approval and post-deploy check apply.

**One-time setup:** create the `production` Environment with a required reviewer *before* the first release. GitHub silently creates a missing environment without protection rules, which would skip the approval.

---

## Frontend

### Static Site (`frontend/static/dist/`)

Plain HTML/JS. The JavaScript calls `https://api.domain.com/api/hello` to demonstrate frontend–backend connectivity.

### Infrastructure (`frontend/infra/`)

Managed via Terraform (workspace: `Frontend`). See [frontend/infra/README.md](frontend/infra/README.md) for full resource documentation.

**Key resources:**

| Resource | Purpose |
|---|---|
| S3 bucket (private) | Stores static files |
| CloudFront distribution | CDN with two origins (S3 + EC2), TLS enforced |
| ACM certificate | TLS cert for the domain, validated via DNS |
| Route 53 records | A records for `static-website.domain.com` and `api.domain.com` → CloudFront |
| CloudFront Function | Strips `www.` prefix from requests |
| SSM data source | Reads EC2 EIP DNS from `/infra/ec2/public_dns` (written by backend Terraform) |

**CloudFront routing:**

| Path pattern | Origin | Cache policy |
|---|---|---|
| `/api/*` | EC2 (Nginx/Gunicorn) | Custom — 0 TTL, CORS headers forwarded |
| `/*` (default) | S3 bucket | Managed CachingOptimized |

### Deployment Workflow

**Infrastructure:**
1. Open a PR with changes to `frontend/infra/` → `terraform-frontend.yml` runs checks (fmt, validate, tflint) and a plan (in the job summary)
2. Review the plan and merge the PR
3. On `main` the workflow plans again and the **Apply** job waits for approval (Environment `infrastructure`), then applies

**Static files:**
- Push to `main` with changes in `frontend/static/` (or run the workflow manually) → `static-deploy.yml` syncs `dist/` to S3 with a `Cache-Control` header (HTML: 5 minutes, everything else: 1 day; file names are not fingerprinted), invalidates the CloudFront cache, and verifies that the bucket matches `dist/` with the intended headers

---

## Observability Stack

Deployed to the same EC2 instance via Docker Compose. Managed by `deploy-grafana.yml` on push to `main` when `observability-stack/**` changes.

| Service | Role |
|---|---|
| Grafana | Dashboards and alerting |
| Loki | Log storage backend |
| Promtail | Scrapes `/var/log/flask/*.log` and ships to Loki |
| Tempo | Distributed tracing backend (receives OTLP spans from Flask) |
| Mimir | Long-term metrics storage |
| Prometheus | Metrics scraping |

Grafana is accessible only via the EC2 instance's IP — it is not exposed publicly.

---

## CI/CD

| Workflow | Trigger | Action |
|---|---|---|
| `terraform-frontend.yml` | PR touching `frontend/infra/**`; push to `main` touching it; manual | Calls `_terraform.yml`: checks (fmt, validate, tflint) + plan; on `main` also apply after approval |
| `terraform-backend.yml` | PR touching `backend/infra/**`; push to `main` touching it; manual | Same, for `backend/infra` |
| `_terraform.yml` | Called by the two workflows above | Shared logic: pinned Terraform, plan summary, approval-gated apply |
| `ci.yml` | PR to `main` (and called by `release.yml`) | gofmt, vet, tests, actionlint, shellcheck, hadolint, govulncheck, image build + smoke test; single required check `CI gate` |
| `release.yml` | Push of tag `vX.Y.Z`, or manual run with a tag | Verify tag → CI → build & push image → approval → deploy via SSM (canary) → verify public API version |
| `static-deploy.yml` | Push to `main` touching `frontend/static/**`, or manual | S3 sync with cache headers + CloudFront invalidation + verification of the bucket |
| `deploy-grafana.yml` | Push to `main` touching `observability-stack/**`, or manual | EC2 downloads the repo at the commit (via SSM) and runs `docker-compose up -d` |

**Required GitHub Secrets:**

| Secret | Used by |
|---|---|
| `TF_API_TOKEN` | All Terraform workflows |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | release, static-deploy, deploy-grafana |
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | release |

**Repository Variables** (Settings → Secrets and variables → Actions → Variables). These are not secrets, so they live in variables. The workflows use the variable when it is set and fall back to the old secret of the same purpose, so the switch is safe to do in any order:

| Variable | Fallback secret | Used by |
|---|---|---|
| `AWS_REGION` | `AWS_REGION` | release, static-deploy, deploy-grafana |
| `S3_BUCKET` | `BUCKET_NAME` | static-deploy |
| `CLOUDFRONT_DISTRIBUTION_ID` | `DISTRIBUTION_ID` | static-deploy |

Once the variables are set, the secrets `AWS_REGION`, `BUCKET_NAME` and `DISTRIBUTION_ID` can be deleted. `PERSONAL_ACCESS_TOKEN`, `EC2_USER` and `EC2_SSH_KEY` are no longer used by any workflow and can be deleted too.

---

## Security Considerations

- EC2 HTTP/HTTPS ingress is restricted to the [CloudFront managed prefix list](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/LocationsOfEdgeServers.html) — direct internet access to the instance is blocked
- SSH access is gated via `ssh_allowed_cidr` — set this to your IP in production, not `0.0.0.0/0`
- The Flask container runs as a non-root user (`appuser`)
- All viewer traffic is redirected to HTTPS at CloudFront (`redirect-to-https`)
- TLS minimum version: `TLSv1.2_2021`
- S3 bucket is private; CloudFront accesses it via Origin Access Control (OAC)

---

## How to Use

```bash
git clone https://github.com/denisgulev/gitops-playground.git
cd gitops-playground
```

1. Create a Terraform Cloud organization and two workspaces: `Backend` and `Frontend`
2. Create a Route 53 hosted zone for your domain and point your registrar's NS records to it
3. Create an S3 bucket for Terraform state (or use Terraform Cloud's built-in state)
4. Fill in `backend/infra/terraform.tfvars` and `frontend/infra/terraform.tfvars` (copy from `.example` files)
5. Set all Terraform variables and GitHub secrets listed above
6. Apply backend infrastructure first (`backend/infra/`), then frontend (`frontend/infra/`)
7. Push a version tag to trigger the first Docker build and deployment

---

## Further Reading

- [Deploy a Static Website with AWS S3, CloudFront, and Terraform](https://denisgulev.com/static-website-with-aws-s3-cloudfront-and-terraform/)
- [Deploy a Flask Backend on AWS EC2 with Terraform](https://denisgulev.com/deploy-flask-backend-on-aws-ec2-with-terraform/)


This repository provides Terraform templates to quickly deploy both a static frontend website and a backend service using AWS infrastructure. The frontend is hosted on AWS S3, with CloudFront for content distribution and Route 53 for DNS management.
The backend service is a Flask app that runs as docker container inside an EC2 instance.

### Architecture

- **Static Frontend**: Hosted on an S3 bucket, served via CloudFront.
- **API Backend**: Running Flask on EC2, accessible through the same CloudFront distribution under the /api/* path.
- **CloudFront**: Configured with multiple origins to serve both the static content from S3 and the API from EC2. A CloudFront function is used to remove the "www." prefix from the domain.
- **Route 53 DNS**: Manages domain names and subdomains (e.g., static-website.example.com, api.example.com).

### CloudFront Setup — Multiple Origins

Two origins are configured inside one CloudFront distribution:
- Origin 1 (S3): Static site.
- Origin 2 (EC2): API.

Key CloudFront settings:
1. **default_cache_behavior**: Handles static content (targeting S3).
2. **ordered_cache_behavior** with path_pattern = "/api/*": Routes API calls to EC2.
3. Attached cache policies and viewer protocol policies for both.
4. **CloudFront Function** for www redirection.

### Route53 Records — Proper Domain Routing
1. A record for static-website.example.com -> CloudFront distribution.
2. A record for api.example.com -> Same CloudFront distribution (CloudFront routes to correct origin via /api/* pattern).
3. CNAME for www.static-website.example.com pointing to static-website.example.com for redirect.

**Note: Both frontend and backend share CloudFront, but routing depends on path and/or subdomain.

### CORS Handling — API (EC2 with Flask)

Initially:
- CORS issues when frontend called backend via CloudFront.
- Missing preflight (OPTIONS) response support.

✅ Resolved by:
- <strike>Adding Flask-CORS, correctly configured:
  ```python
    CORS(app, 
      origins=["https://static-website.example.com"], 
      supports_credentials=True,
      methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
      allow_headers=["Content-Type", "Authorization"])
  ```
  </strike>
- Configuring CORS through nginx
  ```conf
    # Handle OPTIONS requests
    if (\$request_method = 'OPTIONS') {
        access_log /var/log/nginx/options_requests.log;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
        add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;
        add_header 'Access-Control-Allow-Origin' 'https://static-website.denisgulev.com' always;
        add_header 'Access-Control-Max-Age' 1728000;
        add_header 'Content-Type' 'text/plain charset=UTF-8';
        add_header 'Content-Length' 0;
        return 204;
    }

    # CORS headers
    add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS' always;
    add_header 'Access-Control-Allow-Headers' 'Content-Type, Authorization' always;
    add_header 'Access-Control-Allow-Origin' 'https://static-website.denisgulev.com' always;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_pass http://localhost:5000;
  ```
  Functionality:
  
  1. Handles OPTIONS Requests (Preflight Requests)
    - Checks if the request method is OPTIONS
    - Sets necessary CORS headers
    - Returns a 204 No Content response with appropriate headers
  2. Adds CORS Headers for Actual Requests
    - Ensures that actual requests also return CORS headers
  3. Proxying Requests to the Backend
    - Forwards requests to a backend running on localhost:5000
    - Sets headers to pass along client information

### Security Groups — Restricting EC2 to CloudFront

Ideally we want to restrict access to EC2 only for requests coming from the CloudFront.
Currently i am setting manually this, by choosing the **prefix list** of CloudFront.

🚀 **Next Steps**

<strike>Automate the usage of this prefix list through AWS lamdba, which will update the security group with the update prefix list of CloudFront.</strike> -> **DONE**
  - i managed to automatically retrieve the prefix list for CloudFront, by using the following
    ```terraform
      # Data source to fetch the CloudFront prefix list
      data "aws_ec2_managed_prefix_list" "cloudfront" {
        name = "com.amazonaws.global.cloudfront.origin-facing"
      }

      resource "aws_vpc_security_group_ingress_rule" "sg_ingress_http" {
        security_group_id = aws_security_group.flask_sg_http.id
        ....
        prefix_list_id = data.aws_ec2_managed_prefix_list.cloudfront.id
        ....
      }
    ```

### Terraform Workspaces — Cross-workspace Resources Issue

Problem:
- EC2 instance managed in a separate Terraform workspace/project.
- CloudFront defined in another workspace needs to use EC2’s public DNS as an origin.

✅ Solution:
<strike>
- Save EC2 instance as terraform variable in the workspace we want to reference the instance.
- Reference EC2’s public DNS
  ```hcl
    data "aws_instance" "imported_instance" {
      instance_id = var.ec2_instance_id
    }
  ```
➡️ **Note**: If EC2 is modified in its own workspace, updates won’t propagate unless you re-import or manage the resource cross-workspace properly (e.g., through Terraform Cloud workspaces or outputs).
</strike>

- in the backend setup, i save the ec2_dns inside an SSM parameter
  ```
    resource "aws_ssm_parameter" "ec2_dns" {
      name  = "/infra/ec2/public_dns"
      type  = "String"
      value = aws_eip.flask_app_eip.public_dns
    }
  ```
- the frontend retrieves this parameter, if this is not found, a default value is set (in order to allow the static page to function)
  ```
    data "aws_ssm_parameter" "ec2_dns" {
      name = "/infra/ec2/public_dns"
    }

    locals {
      ec2_dns = try(data.aws_ssm_parameter.ec2_dns.value, var.ec2_dns)
    }

    resource "aws_cloudfront_distribution" "s3_distribution" {
      ...
      ...

      origin {
        domain_name = local.ec2_dns
        origin_id   = "EC2-origin"
      ...
      }
      ...
      ...
    }

  ```

### Automate Frontend Deployments — Both Infrastructure and Static Files

To streamline frontend deployments, we implemented a GitHub Actions workflow that automates the management of both infrastructure and static files. 

#### Infrastructure

The process begins when a pull request (PR) is created with changes to the **frontend/infra/** directory. Upon PR creation, the checks (format, validate, tflint) and a Terraform Plan are automatically executed, evaluating the infrastructure changes without applying them; the plan is shown in the run's job summary. After the PR is merged, the workflow plans again on `main` and the Apply job waits until a reviewer approves the `infrastructure` Environment, so the reviewer sees the plan that is about to be applied.

#### Static Files

Static files (HTML, CSS, JS) are automatically deployed to an S3 bucket when committed to the **frontend/static/** directory.

### Automate infrastructure changes via GitHub Actions

The process is similar to the one for the frontend flow.
When a pull request (PR) is created with changes to the **backend/infra/** directory, `terraform-backend.yml` automatically runs the checks and a Terraform Plan, without applying anything. After the merge, the Apply job runs on `main` once a reviewer approves the `infrastructure` Environment.

#### *Notes on how deployments works*

Developers begin by working on changes in a dedicated feature branch. Once the work is complete, they open a pull request targeting the main branch. This initiates a structured deployment process:
1.	The checks (fmt, validate, tflint) and a Terraform Plan run automatically to preview infrastructure changes (handled separately for frontend and backend). The plan appears in the job summary of the run.
2.	If the checks fail or the plan reveals issues or requires improvements, the reviewer leaves feedback on the PR and the author pushes changes.
3.	If everything looks good, the PR is merged into the main branch.
4.	On `main` the workflow plans again and the Apply job waits for approval on the `infrastructure` Environment. Approving it applies the changes; a failed apply leaves `main` as merged, so fix forward with a new PR.

**One-time setup:** create the `infrastructure` Environment with a required reviewer *before* the first infra change is merged. GitHub silently creates a missing environment without protection rules, which would skip the approval.

## Frontend Setup

The static frontend app is described in detail in the following article:  
[Deploy a Static Website with AWS S3, CloudFront, and Terraform](https://denisgulev.com/static-website-with-aws-s3-cloudfront-and-terraform/).

In this article, you'll find a step-by-step guide on how to set up an S3-backed static website using Terraform, including CloudFront distribution, DNS configuration with Route 53, and more.

### Diagram

![Static Web Hosting](./assets/static-web-hosting.png)

## Backend Setup

The backend service is deployed on a single EC2 instance running a simple Python Flask application. This backend architecture is designed to be minimal yet production-ready, including a robust networking layer, proper IAM permissions, and logging capabilities. 

All infrastructure components — from networking to compute and security — are fully managed and provisioned using Infrastructure as Code (IaC) through Terraform, ensuring consistent, repeatable, and easily maintainable deployments.

The backend app is described in detail in the following article:  
[Deploy an EC2 Instance with internet access](https://denisgulev.com/deploy-flask-backend-on-aws-ec2-with-terraform/).

### Architecture Components
- **EC2 Instance**: Hosts a Flask application.
- **Networking Layer**:
   - **VPC**: A dedicated Virtual Private Cloud for isolation and security.
   - **Public Subnets**: For resources that require direct access to the internet, including the EC2 instance.
   - **Private Subnets**: Reserved for future use, such as databases or internal services that shouldn’t be publicly accessible.
   - **Security Group**: Controls traffic to the EC2 instance with:
   - **Ingress Rules**: Allow HTTP (port 80), HTTPS (443) and SSH (port 22) access.
   - **Egress Rule**: Allows all outbound traffic.
   - **Internet Gateway**: Provides internet connectivity for the VPC.
   - **Route Table & Associations**: Routes traffic appropriately within the VPC and to the internet.
   - **IAM Roles**: 
      1. An iam role attached to the instance, granting permissions to write logs to CloudWatch Logs for better monitoring and observability.
      1. An iam role that allows to fetch prefix list ids for global CloudFront.

### Flask Application

The Flask backend exposes a single API endpoint as an example of a backend service. It is served using Gunicorn, a WSGI HTTP server for Python, behind Nginx, which acts as a reverse proxy for better performance and security.

### Diagram

![Backend](./assets/backend.png)

## How to Use

1. Clone this repository:
   ```bash
   git clone https://github.com/denisgulev/gitops-playground.git
   cd gitops-playground
   ```
2.	Customize the variables in the frontend and backend directories to suit your needs.
3.	Follow the instructions in the linked article to deploy the frontend static website.
4.	Follow the instructions in the linked article to deploy the backend service.


## 📌 Future Developments  

- <strike>**Connect the Static Frontend with the Backend API**</strike> - **DONE**
  - Expose backend API under a proper domain (e.g., `api.example.com`).  
  - Configure CORS settings to allow frontend-backend communication.  
  - Update frontend to interact with backend endpoints.  

- <strike>**Implement CI/CD Pipelines for Frontend and Backend**</strike> - **DONE**
  - Automate frontend deployments (S3 + CloudFront invalidation) using GitHub Actions. 
  - Automate backend EC2 updates and infrastructure changes via GitHub Actions.  

    - I’ve split the infrastructure from the backend service (Flask app):

      1. The infrastructure code lives in the *backend/infra/* folder. Any PRs to the *main* branch that touch files in this folder will trigger the *terraform-backend.yml* workflow. This runs the checks and a *terraform plan*; after the merge, the *terraform apply* runs on *main* once a reviewer approves it.

      2. The backend service runs in Docker. Whenever a version tag is pushed, the *release.yml* workflow runs the checks, builds a Docker image from the tagged commit and pushes it to Docker Hub, then deploys it after approval.

  - automate the deployment of docker image inside EC2 instance **DONE**
    
    ### 🚀 Automated Deployment Workflow for Flask App

    #### 🧱 Branch Structure
    -	**backend branch** -> Development branch. New changes are pushed here and tested by a reviewer or i may setup a workflow to test the changes.
      
    -	**main branch** -> Production-ready branch. After staging validation and management approval, changes are merged into main, version-tagged, and deployed to production through a gated process.


    #### 🛠 CI/CD Pipeline Overview

    ##### 1. ✅ Push to backend
      - The app is ready to be tested (currently requires a manual pull and local testing)
      - Once everything is tested, a PR is issued towards main branch

    #### 2. ✅ Merge backend → main and Create a Tag
      - Merge changes into main
      - Create a new Git tag (e.g., v1.0.0)

    #### 3. ✅ Tag Push → Checks → Build & Push Docker Image
      - `release.yml` verifies the tag (format `vX.Y.Z`, on `main`) and runs the CI checks
      - GitHub Actions builds the image from the tagged commit
      - Tags and pushes it to Docker Hub (e.g., go-app:v1.0.0)

    #### 4. ✅ Approval → Deploy to Production
      - The deploy job waits for approval on the `production` Environment (required reviewer)
      - After approval it runs `scripts/deploy-app.sh` on the EC2 instance through SSM:
        - Pulls the new Docker image and starts a canary container
        - Promotes it only if the canary health check passes; otherwise the running container is left untouched
      - Finally checks that the public API reports the new version
      - Roll back by running the workflow manually with an older tag

- **Add Monitoring, Logging, and Alerts**  
  - Enable detailed **CloudWatch Logs** for backend (Nginx, Gunicorn, Flask).  
  - Set up **CloudWatch Alarms** for critical metrics (CPU, memory, HTTP errors).  
  - Configure notification systems (e.g., **SNS**, email, Slack) for alerts.  
  #### 📊 Observability Stack (Grafana + Loki + Promtail)

  This repository contains the GitOps-managed configuration to deploy a full observability stack on an AWS EC2 instance using Docker Compose and GitHub Actions.

  ##### 🧰 Stack Components
  
  Grafana -> Visualization & alerting platform
  
  Loki -> Log aggregation backend

  Promtail -> Log collector/forwarder from EC2 instance

  #### 📁 Log Collection (via Promtail)

  Promtail is currently configured to collect logs from:
  - **/var/log/flask/*.log** (Flask application logs)

  To add support for additional services (e.g., Nginx, Gunicorn), update the `promtail-config.yaml` file by adding new `scrape_configs` with appropriate paths.

  #### 🌐 Accessing Grafana

  Grafana is accessible **only internally** via the EC2 instance’s IP.  
  It is not exposed through a public domain or CloudFront.

  #### 🔔 Alerting

  Grafana supports:
  - Log-based alerting
  - Notification channels (Email, Slack, Webhook, etc.)

  Alerts can be version-controlled using provisioning or exported JSON.



- **Security Hardening**  
  - Apply least privilege principles to IAM roles and security groups.  
  - Enable HTTPS for backend and frontend (SSL/TLS via ACM).  
  - Add security headers, rate limiting, and request validation to backend (Nginx/Flask).  
  - Consider adding **AWS WAF** and API throttling for additional protection.  
