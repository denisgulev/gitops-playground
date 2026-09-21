# GitOps Playground

A boilerplate for running a **Go API** and a **static frontend** on AWS, with all infrastructure in Terraform and every change to it, to the app and to the site going through GitHub Actions. Deployments need no SSH: they run through AWS Systems Manager (SSM), behind approvals.

- [Overview](#overview) · [Architecture](#architecture) · [Repository structure](#repository-structure)
- [Getting started](#getting-started)
- [Backend](#backend) · [Frontend](#frontend) · [Observability](#observability-stack)
- [CI/CD](#cicd) · [Repository protections](#repository-protections-and-configuration) · [Runbook](#runbook)
- [Security](#security) · [Known limitations and roadmap](#known-limitations-and-roadmap) · [What changed](#what-changed-in-the-cicd-hardening)

---

## Overview

| Layer | Technology |
|---|---|
| Frontend | Static HTML/JS on S3 (private bucket), served through CloudFront |
| Backend | Go API (chi) in a Docker container on one EC2 instance, behind Nginx |
| Infrastructure | Terraform on HCP Terraform (Terraform Cloud): workspaces `Backend` and `Frontend` |
| DNS / TLS | Route 53, ACM certificate (issued in `us-east-1`, DNS-validated) |
| CI/CD | GitHub Actions: CI, release, Terraform, static deploy, observability deploy |
| Deployment channel | SSM Run Command (no SSH, no inbound port needed) |
| Observability | Grafana, Loki, Promtail on the same instance (Tempo, Mimir and Prometheus are present but disabled) |

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
                       static-website.<domain>     api.<domain>
                                    │                    │
                              ┌─────▼─────┐       ┌──────▼──────┐
                              │ S3 Bucket │       │ EC2 · Nginx │
                              │ (private, │       │  → Go API   │
                              │   OAC)    │       │  (Docker)   │
                              └───────────┘       └─────────────┘
```

Three names (`static-website.<domain>`, `www.static-website.<domain>`, `api.<domain>`) point at the **same CloudFront distribution**. CloudFront routes by path: `/api/*` goes to the EC2 origin, everything else to S3. A CloudFront Function redirects `www.` to the bare name.

### CloudFront routing

| Path pattern | Origin | Cache policy |
|---|---|---|
| `/api/*` | EC2 (Nginx → Go API), HTTP on port 80 | Custom: default TTL 0, max TTL 10 s, forwards `Origin` and the CORS request headers |
| `/*` (default) | S3 bucket via Origin Access Control | Managed *CachingOptimized* |

![Static web hosting](./assets/static-web-hosting.png)

---

## Repository structure

```
.
├── .github/
│   ├── actions/ssm-run/        # composite action: run a script on the EC2 instance via SSM
│   ├── workflows/              # ci, release, terraform-*, _terraform, static-deploy, deploy-grafana
│   └── dependabot.yml          # weekly updates: GitHub Actions, Go modules, Docker
├── backend/
│   ├── app/                    # Go API: main.go, tests, Dockerfile
│   └── infra/                  # Terraform (workspace Backend): VPC, EC2, EIP, IAM, SSM
├── frontend/
│   ├── static/dist/            # the site that is deployed (index.html, error.html)
│   └── infra/                  # Terraform (workspace Frontend): CloudFront, ACM, Route 53, bucket config
├── observability-stack/        # Docker Compose: Grafana, Loki, Promtail (+ disabled Tempo/Mimir/Prometheus)
├── scripts/                    # the logic behind the workflows (shellcheck-ed, testable)
├── bin/create-s3-bucket        # helper that creates the site bucket
└── assets/                     # diagrams
```

---

## Getting started

### Prerequisites

- An AWS account and a domain with a **Route 53 hosted zone**
- An HCP Terraform (Terraform Cloud) organization with two **CLI-driven** workspaces, `Backend` and `Frontend`. The AWS credentials and the Terraform variables (`terraform.tfvars.example` in each `infra/` directory lists them) live in the workspaces. Set each workspace's *Terraform Working Directory* to `backend/infra` / `frontend/infra`.
- A Docker Hub account (the release workflow pushes the image there)
- The site bucket must **exist** before Terraform runs: `bin/create-s3-bucket` creates one, and its name goes into the `bucket_name` variable
- Change the organization name `Terraform-bootcamp-aws` (hardcoded in `backend/infra/main.tf` and `frontend/infra/backend.tf`) to yours

### One-time setup

1. **Apply the infrastructure, backend first.** The frontend reads the EC2 address that the backend publishes in SSM (`/infra/ec2/public_dns`). Run it through the pipeline described in [Terraform](#terraform), or the first time with `terraform apply` from each directory.
2. **Configure GitHub** ([details](#repository-protections-and-configuration)): repository secrets and variables, the two Environments (`production`, `infrastructure`), the rulesets. Create the environments **before** the first release or infra change, because GitHub silently creates a missing environment *without* protection, which would skip the approval.
3. **Cut the first release** ([runbook](#runbook)): push a tag such as `v0.1.0`.

---

## Backend

### The Go API (`backend/app/`)

A small [chi](https://github.com/go-chi/chi) service listening on port 8000.

| Method | Path | Description |
|---|---|---|
| GET | `/api/hello` | Greeting |
| GET | `/api/info` | Service info |
| GET | `/api/status` | Health: `{status, version, region, static_site}`. Used by the Docker health check, the deploy canary and the post-deploy check |
| GET | `/api/about` | Project description and stack |
| any other | | `302` to `${STATIC_SITE_URL}/error.html` |

**Configuration (environment variables):**

| Variable | Default | Description |
|---|---|---|
| `AWS_REGION` | `eu-south-1` | Region for the CloudWatch client. The deploy script sets `AWS_DEFAULT_REGION`, not this, so production uses the default |
| `CLOUDWATCH_LOG_GROUP` | `go-app-logs` | CloudWatch log group (created by the app if missing) |
| `STATIC_SITE_URL` | `https://static-website.example.com` | Target of the 404 redirect; also reported by `/api/status` |
| `APP_VERSION` | `unknown` | Reported by `/api/status`; the deploy sets it to the release tag |

**Logging.** JSON logs (`log/slog`) go to stdout, where Docker keeps them and Promtail ships them to Loki. A second copy goes to CloudWatch Logs; that copy carries the level and message only, not the structured attributes. Failing to reach CloudWatch does not stop the app.

**Rate limiting.** An in-memory limiter allows 50 requests per hour and 200 per day per key, and answers `429`. See the [limitations](#known-limitations-and-roadmap): the key is the connection's remote address, which behind CloudFront and Nginx is probably not the visitor's address.

**Health check.** `/app -healthcheck` requests `http://localhost:8000/api/status` and exits 0 or 1. It is the image's `HEALTHCHECK`.

**Local development**

```bash
cd backend/app
go test ./... -race
AWS_EC2_METADATA_DISABLED=true go run .    # then: curl localhost:8000/api/status
```

`AWS_EC2_METADATA_DISABLED` stops the CloudWatch client from waiting on the EC2 metadata service; without credentials the app still runs and logs to stdout only.

### The Docker image (`backend/app/Dockerfile`)

- **Multi-stage.** The build stage runs on the build machine and Go **cross-compiles** for the target (`GOOS`/`GOARCH` from `TARGETOS`/`TARGETARCH`), so an arm64 image is produced on an amd64 runner without emulation. The final stage is `FROM scratch` with only the binary and the CA certificates.
- **Non-root.** Runs as `65532:65532`.
- **Target.** `linux/arm64` (the EC2 instance is ARM). The CI builds the same Dockerfile for amd64 and starts it as a smoke test.
- **Do not give `ARG TARGETARCH` a default value** in the Dockerfile: the default overrides what BuildKit passes in, and an amd64 build silently gets an arm64 binary.

### EC2 infrastructure (`backend/infra/`)

Managed in the `Backend` workspace; per-resource notes are in [backend/infra/README.md](backend/infra/README.md).

- **Network:** dedicated VPC `10.0.0.0/16`, two public and two private subnets (the private ones are unused), internet gateway, route table
- **Instance:** Amazon Linux 2023 ARM, bootstrapped by `user_data.sh`, with an **Elastic IP**
- **Nginx** on port 80 proxies to the container on port 8000 and handles CORS (see [Design notes](#design-notes)). Only `GET`, `POST` and `OPTIONS` are allowed; `HEAD` gets a 405.
- **Security groups:** HTTP and HTTPS ingress only from the **CloudFront managed prefix list** (looked up with a data source); SSH from `ssh_allowed_cidr`
- **IAM:** an instance role with CloudWatch Logs write access and `AmazonSSMManagedInstanceCore` (what makes SSM deployments possible)
- **SSM parameters:** `/infra/ec2/public_dns` (read by the frontend workspace) and `/infra/ec2/instance_id` (read by the deploy workflows)

| Terraform variable | Description |
|---|---|
| `aws_region` | Deployment region |
| `instance_type` | EC2 instance type (ARM) |
| `domain_name` | Base domain, e.g. `example.com`; the API is served at `api.<domain>` |
| `ssh_allowed_cidr` | CIDR allowed to SSH; set it to your own address |
| `subdomain`, `hosted_zone_id` | Declared but currently **unused** |

> **Changing `user_data.sh` replaces the instance** (`user_data_replace_on_change`). The new instance has no app container and no observability stack until the deploy workflows run again.

![Backend network](./assets/backend.png)

*The network layout. The diagram predates two changes: the instance is named `FlaskAppEC2` in Terraform for historical reasons, and HTTP/HTTPS ingress is no longer open to `0.0.0.0/0` but limited to the CloudFront prefix list.*

---

## Frontend

### The site (`frontend/static/dist/`)

Two plain HTML files, `index.html` and `error.html`. The page calls the API at `https://api.<domain>/api/...`. The address is the `API_BASE` constant in `index.html`, currently set to the author's domain, so change it for yours.

### Infrastructure (`frontend/infra/`)

Managed in the `Frontend` workspace; notes per resource in [frontend/infra/README.md](frontend/infra/README.md).

| Resource | Purpose |
|---|---|
| S3 bucket (existing, private) | Site files. Website configuration, ownership controls, public-access block, private ACL and a bucket policy that only lets the CloudFront distribution read it (OAC) |
| CloudFront distribution | Two origins (S3 and EC2), TLS 1.2+ only, redirect to HTTPS, HTTP/2 and HTTP/3 |
| ACM certificate | For the site names and the API name, DNS-validated, created in `us-east-1` |
| Route 53 records | A records for the site and the API, CNAME for `www` |
| CloudFront Function | Redirects `www.` to the bare name |
| SSM data source | EC2 address from `/infra/ec2/public_dns` |

**Who owns the site files.** The **`static-deploy.yml` workflow** uploads `dist/`, not Terraform. Terraform used to manage the objects too, and the two fought over them; `frontend/infra/removed.tf` makes Terraform forget them without deleting them, and can be removed once applied.

**Cache headers.** HTML gets `Cache-Control: public, max-age=300` and everything else `max-age=86400`. The file names are not fingerprinted, so nothing is cached for long.

---

## Observability stack

`observability-stack/` is a Docker Compose project deployed to the same instance by `deploy-grafana.yml`.

| Service | State | Role |
|---|---|---|
| Grafana (`:3000`) | running | Dashboards; the Loki data source and a dashboard are provisioned from Git |
| Loki (`:3100`) | running | Log storage |
| Promtail | running | Ships Docker container logs (label `job=flask`, a legacy name) and `/var/log/nginx/*.log` to Loki |
| Tempo, Mimir, Prometheus | **disabled** (commented out in the compose file) | The app does not export traces or metrics yet |

**Access.** Grafana and Loki are published on the instance, but the security groups do not open those ports to the internet. Reach Grafana through an SSM port-forward (needs the AWS Session Manager plugin):

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
# then open http://localhost:3000
```

The committed `.env` sets the login to `admin` / `admin`. The deploy never overwrites an existing `.env` on the instance, so **change it there**.

**Deployment.** On a push to `main` touching `observability-stack/**` (or manually), the instance downloads this repository at that commit from GitHub (the repo is public) and runs `docker-compose pull && docker-compose up -d`. Markdown files are not copied, and only changed services are recreated.

---

## CI/CD

Everything is GitHub Actions. The logic lives in [`scripts/`](scripts), each script checked with `shellcheck`, and the workflows only wire it together.

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | Pull request to `main`; also called by `release.yml` | Format, vet, tests, lint, vulnerability scan, image build and smoke test. Its single required check is **`CI gate`** |
| `release.yml` | Push of a tag `vX.Y.Z`; or manual with a tag | Verify tag → CI → build and push image → **approval** → deploy → verify |
| `terraform-frontend.yml`, `terraform-backend.yml` | PR / push to `main` touching their `infra/` directory; manual | Thin callers of `_terraform.yml` |
| `_terraform.yml` | Called by the two above | Checks, plan, and an approval-gated apply |
| `static-deploy.yml` | Push to `main` touching `frontend/static/**`; manual | Upload with cache headers, invalidate CloudFront, verify the bucket |
| `deploy-grafana.yml` | Push to `main` touching `observability-stack/**`; manual | Deploy the observability stack |

### CI (`ci.yml`)

| Job | Checks |
|---|---|
| `Go` | `gofmt`, `go vet`, `go build`, `go test -race` |
| `Lint` | `actionlint` (which also runs `shellcheck` on workflow scripts), `shellcheck` on `scripts/`, `hadolint` on the Dockerfile |
| `Vulnerability scan` | `govulncheck`; blocking, so a new advisory can turn it red with no code change |
| `Image` | Builds the image and **starts it**: it must not run as root, must answer `/api/status`, and its `HEALTHCHECK` command must succeed |
| `CI gate` | Passes only if all of the above passed. It is the check the `main` ruleset requires |

There is deliberately no `paths:` filter on CI, so `CI gate` always reports. The tool versions (`actionlint`, `govulncheck`, `hadolint`) are pinned in the file, with the `hadolint` download verified by checksum.

### Release (`release.yml`)

```
tag vX.Y.Z pushed
  └─ verify   the tag is vMAJOR.MINOR.PATCH, exists, and its commit is on main
      └─ ci        the same checks as a pull request
          └─ build     image built FROM THE TAGGED COMMIT, pushed to Docker Hub as <user>/go-app:vX.Y.Z
              └─ deploy   waits for approval (Environment "production")
                          → scripts/deploy-app.sh on the instance via SSM
                          → checks that the public API reports vX.Y.Z
```

- **Canary deploy** (`scripts/deploy-app.sh`): pulls the image, starts it as a canary on port 8001, promotes it (replaces the production container on port 8000, `--restart unless-stopped`) only if `/api/status` answers `ok`. If the canary fails, the running container is untouched.
- **A failed CI never deploys**: on a tag push a skipped build does not count as a success. Only a manual run may skip the build.
- **Rollback / redeploy:** *Actions → Release → Run workflow* with an existing tag. The image is not rebuilt; the same approval and post-deploy check apply.

### Terraform

One reusable workflow, `_terraform.yml`, serves both directories:

| Job | Runs | Content |
|---|---|---|
| `Checks` | every run, **no secrets needed** | `terraform fmt -check`, `init -backend=false`, `validate`, `tflint` (warnings are shown; errors fail). Warns when `init` would change the provider lock file |
| `Plan` | every run, except PRs from forks or Dependabot | Real plan in HCP Terraform, summarised on the run's **Summary page** |
| `Apply` | push to `main` or a manual run on `main` only | Waits for approval on Environment `infrastructure`, then `terraform apply` |

The flow: open a PR → read the plan in the summary → merge → the workflow plans again on `main` → **read that plan**, then approve the apply. A failed apply leaves `main` as merged, so fix forward with a new PR. The apply trigger deliberately excludes the workflow files: editing a workflow never applies infrastructure. Terraform is pinned (`1.10.5` for the CLI; the workspace runs its own version), and so is `tflint`.

### Static site and observability deploys

- `static-deploy.yml`: two `aws s3 sync` passes (one per cache header), a CloudFront invalidation of `/*`, then `scripts/verify-static-headers.sh`, which fails if any object is missing, has the wrong header, or if the bucket holds anything not in `dist/`. Configuration comes from repository Variables.
- `deploy-grafana.yml`: one SSM call running `scripts/deploy-observability.sh`.

### Building blocks

| Piece | Role |
|---|---|
| `.github/actions/ssm-run` | Composite action: runs a repository script on the instance through SSM, waits, prints the output, fails unless it succeeded |
| `scripts/ssm-run.sh` | The logic behind that action. It builds the payload safely (values are quoted, never interpreted), tolerates the short delay before the command record exists, and gives up on a timeout |
| `scripts/deploy-app.sh` | Canary deploy (runs on the instance) |
| `scripts/deploy-observability.sh` | Fetches the repo at a commit, keeps an existing `.env`, installs Docker Compose (pinned, checksum-verified) if missing, starts the stack (runs on the instance) |
| `scripts/release-verify-tag.sh` | Tag checks for the release |
| `scripts/verify-deployment.sh` | Polls the public API until it reports the expected version |
| `scripts/smoke-test-image.sh` | Starts the built image and checks it (used by CI) |
| `scripts/terraform-plan-summary.sh` | Turns a plan into the summary page: a one-line verdict and the full output, HTML-escaped |
| `scripts/verify-static-headers.sh` | Post-deploy check of the bucket |

### Conventions

- Every action is pinned to a **full commit SHA** (with a version comment), and GitHub enforces it. Dependabot proposes updates weekly: minor and patch grouped, major versions as separate PRs. Terraform updates are left off because Dependabot PRs cannot read `TF_API_TOKEN`.
- Workflows declare least-privilege `permissions`, a `timeout-minutes` on every job, and `concurrency` groups: deploys queue and never cancel a running deploy; plans and CI cancel superseded runs.
- Untrusted values reach shell code through `env:`, not by inline `${{ }}` interpolation.

---

## Repository protections and configuration

### Rulesets (Settings → Rules)

| Ruleset | Rules | Bypass |
|---|---|---|
| `main` | Pull request required (0 approvals: a solo owner cannot approve their own); status check **`CI gate`** (from GitHub Actions) must pass; no force-push; no deletion | Admin, **only when merging a pull request** (emergencies); direct pushes stay blocked |
| `release-tags-create` | Only admins can create `v*` tags | Admin |
| `release-tags-immutable` | Nobody can move or delete a `v*` tag | **None**; removing a tag means disabling the ruleset first |

### Environments (Settings → Environments)

| Environment | Used by | Protection |
|---|---|---|
| `production` | the deploy job of `release.yml` | Required reviewer; allowed from `main` and tags `v*` |
| `infrastructure` | the apply job of `_terraform.yml` | Required reviewer; allowed from `main` |

### Secrets and variables

| Secret | Used by |
|---|---|
| `TF_API_TOKEN` | Terraform workflows (plan and apply) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | release (deploy job), static-deploy, deploy-grafana |
| `DOCKER_USERNAME`, `DOCKER_PASSWORD` | release (build job) |

| Variable | Used by |
|---|---|
| `AWS_REGION` | release, static-deploy, deploy-grafana |
| `S3_BUCKET` | static-deploy |
| `CLOUDFRONT_DISTRIBUTION_ID` | static-deploy |

`PERSONAL_ACCESS_TOKEN`, `EC2_USER` and `EC2_SSH_KEY` are no longer used by any workflow.

### Other settings

- **Actions:** SHA pinning is required; the default token is read-only; Actions cannot approve PRs
- **Secret scanning and push protection:** on
- **Dependabot alerts and security updates, CodeQL:** currently off (all free on a public repository)

<details>
<summary>Commands to recreate the environments and rulesets</summary>

```bash
REPO="<owner>/<repo>"; ME=$(gh api user --jq .id)     # replace the placeholder with your repository

# Environments (create BEFORE the first release / infra change)
gh api -X PUT repos/$REPO/environments/production --input - <<EOF
{"reviewers":[{"type":"User","id":$ME}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
EOF
gh api -X POST repos/$REPO/environments/production/deployment-branch-policies -f name=main -f type=branch
gh api -X POST repos/$REPO/environments/production/deployment-branch-policies -f name='v*' -f type=tag
gh api -X PUT repos/$REPO/environments/infrastructure --input - <<EOF
{"reviewers":[{"type":"User","id":$ME}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
EOF
gh api -X POST repos/$REPO/environments/infrastructure/deployment-branch-policies -f name=main -f type=branch

# Main branch ruleset (15368 is the GitHub Actions app; role 5 is Repository admin)
gh api -X POST repos/$REPO/rulesets --input - <<'EOF'
{"name":"main","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},
 "bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"pull_request"}],
 "rules":[{"type":"deletion"},{"type":"non_fast_forward"},
  {"type":"pull_request","parameters":{"required_approving_review_count":0,"dismiss_stale_reviews_on_push":false,"require_code_owner_review":false,"require_last_push_approval":false,"required_review_thread_resolution":false}},
  {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"CI gate","integration_id":15368}]}}]}
EOF

# Release tags: creation for admins, immutability for everyone
gh api -X POST repos/$REPO/rulesets --input - <<'EOF'
{"name":"release-tags-create","target":"tag","enforcement":"active",
 "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},
 "bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}],
 "rules":[{"type":"creation"}]}
EOF
gh api -X POST repos/$REPO/rulesets --input - <<'EOF'
{"name":"release-tags-immutable","target":"tag","enforcement":"active",
 "conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},
 "bypass_actors":[],
 "rules":[{"type":"update"},{"type":"deletion"}]}
EOF

# Require SHA pinning for actions
gh api -X PUT repos/$REPO/actions/permissions -F enabled=true -f allowed_actions=all -F sha_pinning_required=true
```

</details>

---

## Runbook

**Release a version**

```bash
git switch main && git pull
git tag v1.2.0 && git push origin v1.2.0       # must be on a commit that is on main
```

Then open the run (*Actions → Release*), and approve the `production` deployment once CI and the build are green.

**Roll back or redeploy:** *Actions → Release → Run workflow*, enter the tag (for example `v1.1.0`), and approve.

**Change infrastructure:** PR → read the plan on the run's Summary page → merge → read the plan of the run on `main` → approve the `infrastructure` deployment.

**Delete or move a release tag:** disable the `release-tags-immutable` ruleset, do it, re-enable it.

```bash
gh api -X PUT repos/<owner>/<repo>/rulesets/<id> -f enforcement=disabled   # ...and =active afterwards
```

**Check that a deployment worked**

```bash
curl -s https://api.<domain>/api/status                       # status "ok" and the expected version
curl -sI https://static-website.<domain>/ | grep -i cache-control
```

**Emergency:** a red required check blocks merging. As admin you can still merge the PR (the bypass applies to pull requests only). To push directly, disable the `main` ruleset temporarily and re-enable it afterwards. To turn SHA pinning off, set `sha_pinning_required=false` with the command above.

---

## Design notes

**CORS is handled by Nginx**, not by the app. Nginx answers `OPTIONS` preflights with `204` and adds `Access-Control-Allow-Origin` (the static site's origin), `Allow-Methods` and `Allow-Headers` to every response, then proxies to the container. Because the API is also reachable under `static-website.<domain>/api/*` on the same distribution, a same-origin call would need no CORS at all.

**The EC2 address crosses workspaces through SSM.** The backend workspace writes `/infra/ec2/public_dns`, and the frontend workspace reads it as a data source to configure the CloudFront EC2 origin, so the two workspaces never need to know each other's state. This is why the backend is applied first.

**The instance only accepts CloudFront.** The security group looks up the CloudFront origin-facing managed prefix list with a data source, so the allowed ranges stay current without maintenance.

**No SSH for deployments.** The instance role includes SSM core; the workflows read the instance id from `/infra/ec2/instance_id` and send commands through SSM Run Command. SSH remains open to `ssh_allowed_cidr` only as a break-glass path.

---

## Security

What is in place:

- **Network:** HTTP/HTTPS to the instance only from CloudFront's prefix list; TLS 1.2+ and redirect-to-HTTPS at CloudFront; the S3 bucket is private and readable only by the distribution (OAC)
- **Container:** non-root, `scratch` image (no shell), health-checked; every release is built from a tag that must be on `main`
- **Delivery:** a required check before merging, approvals for production and infrastructure, immutable release tags, SHA-pinned actions, least-privilege workflow tokens, secret scanning with push protection
- **Deployments:** commands reach the instance through SSM only, with values quoted rather than interpreted, and inputs (tag, repo, commit) are validated before use

Known gaps are listed below.

---

## Known limitations and roadmap

**Planned**

- **OIDC instead of AWS access keys.** Three workflows still authenticate with a long-lived IAM user key stored as GitHub secrets. Replacing it with per-run, short-lived credentials from an IAM OIDC role is the next step.
- **Security features** that are still off: Dependabot alerts and security updates, CodeQL.

**Known and not yet fixed**

- **Rate limiting.** The limiter keys on the connection's remote address (`ip:port`), and the app sits behind CloudFront and Nginx, so it is *probably* not limiting per visitor; this has not been confirmed against production logs. The state is in memory, and it is cleared every 10 minutes. A layered design (Nginx `limit_req` with the real client address, the app limiter fixed to read it, and optionally AWS WAF) is the intended fix. The Docker health check also calls `/api/status`, so that route should be exempted before the limiter is corrected.
- **Origin exposure.** CloudFront reaches the instance over plain HTTP, and the prefix list admits *any* CloudFront distribution, not only this one. A secret header checked by Nginx would close that.
- **Observability is partial.** No traces or metrics are exported (there is no `/metrics` endpoint), and there are no alerts. The CloudWatch log copy drops structured attributes, and its log group has no retention set.
- **Single instance.** One EC2 instance in one subnet, with a short interruption while the container is swapped. Editing `user_data.sh` replaces the instance.
- **Terraform housekeeping.** Unused variables (`subdomain`, `hosted_zone_id`) and a local (`module_name`); the AMI id is hardcoded; IMDSv2 is not enforced; the instance role's logs permission uses `Resource: "*"`; the frontend lock file carries an unused `hashicorp/local` entry (CI warns about it); the S3 behaviour in CloudFront allows write methods. `removed.tf` can be deleted once applied.
- **Grafana** ships with `admin` / `admin`, and Loki has no authentication (both are unreachable from the internet by network rules).

Cost note: everything above runs on free tiers of the GitHub features used (public repository) and adds nothing to the AWS bill beyond the resources themselves.

---

## What changed in the CI/CD hardening

A summary of the work that turned the original workflows into what this document describes (all on 2026-09-21):

1. **Baseline.** The Go rewrite's tests and `-healthcheck` flag were committed (the Dockerfile's `HEALTHCHECK` called a flag the binary did not have), and a Go CI added.
2. **Hygiene.** Actions pinned to SHAs, `permissions`, `timeout-minutes`, `concurrency`, untrusted values moved into `env:`, Dependabot added.
3. **One CI with a gate.** `ci.yml` replaced the Go-only workflow: format, vet, tests, lint, vulnerability scan, image smoke test, and a single `CI gate` check.
4. **SSM scripts.** The copy-pasted "send, wait, print, fail" code became one composite action and scripts; the observability deploy now pulls the repository at the commit instead of uploading base64 files.
5. **Release in one workflow.** Tag → checks → build (from the tagged commit, without emulation) → approval → deploy → verification, with rollback by manual run. This replaced the bot pull request, the personal access token and `deployment-version.txt`.
6. **Terraform in one reusable workflow.** Checks without secrets, a plan summary, and an apply after merge behind approval, replacing the label-triggered apply from unmerged pull-request code.
7. **Static site.** Cache headers, repository variables instead of secrets, a post-deploy check of the bucket, and Terraform stopped managing the site files.
8. **Repository protections.** The `main` and release-tag rulesets, the two Environments and enforced SHA pinning.
9. **Dependencies.** Go 1.27.0 (which also cleared the reachable vulnerabilities) and current versions of the Go libraries and all actions.

---

## Further reading

The original articles were written for the earlier Python/Flask version of the backend; the infrastructure they describe still applies.

- [Deploy a Static Website with AWS S3, CloudFront, and Terraform](https://denisgulev.com/static-website-with-aws-s3-cloudfront-and-terraform/)
- [Deploy an EC2 Instance with internet access](https://denisgulev.com/deploy-flask-backend-on-aws-ec2-with-terraform/)

Licensed under the terms in [LICENSE](LICENSE).
