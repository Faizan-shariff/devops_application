# Logikality DevOps Assessment

A deliberately small, no-cloud-cost assessment covering Docker, S3/SQS/IAM Terraform, GitHub Actions, architecture and queue incident response. **No AWS resources are deployed by this repository.** The HTTP service only implements `/` and `/health`; an actual S3 uploader and SQS worker are **not** implemented and are described as an extension.

## Repository structure
```
app/                   # Python stdlib HTTP service and unit tests
Dockerfile             # Non-root, slim runtime, Docker healthcheck
infra/                 # Terraform AWS S3, SQS, DLQ, IAM roles/policies
.github/workflows/ci.yml
architecture.png       # Intended production evolution; dashed = not implemented
incident-runbook.md
evidence/              # Actual local test output, environment limitations
```

## Local quickstart
Requires Python 3.13 (source is stdlib-only), optional Docker and Terraform CLI.

```bash
python -m unittest discover -s app -p 'test_*.py' -v
python -m app.server
# in another shell:
curl -i http://localhost:8080/
curl -i http://localhost:8080/health
```

Docker, when installed:
```bash
docker build -t logikality-document-api:local .
docker run --rm -p 8080:8080 logikality-document-api:local
curl -fsS http://localhost:8080/health
```

Terraform, when installed (no AWS resources created by these commands):
```bash
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
```
`terraform plan` typically requires AWS credentials, even though it doesn't create resources. Never run `apply` for this assessment. Supply a globally unique `bucket_suffix` if actually deploying. `terraform.tfvars.example` is safe to commit; real state and tfvars are gitignored. Backend is intentionally not configured because no deployment is required; for production use S3 remote state with locking, restricted permissions, encryption and state access audit.

## Resource flow and IAM
**Intended (not implemented):** API stores mortgage documents under `s3://BUCKET/incoming/` and submits document object reference (not sensitive payload) to SQS. Worker receives and processes messages, reads input from S3, writes output under `processed/` and deletes SQS message after durable success. Main SQS queue redrives after 5 receives into a separately encrypted managed-SSE DLQ. API role only permits `PutObject incoming/*` and `SendMessage` main queue; worker role only permits `GetObject incoming/*`, `PutObject processed/*`, and receive/delete/change-visibility/get-attributes on main queue. Both roles trust `ecs-tasks.amazonaws.com`; ECS task definitions must explicitly reference the relevant role in production. No worker access to DLQ, no bucket listing or `s3:*` allow.

S3 uses SSE-S3 (AES256) for a low-dependency baseline, bucket versioning, block-public-access, TLS-only bucket policy, and bucket-owner enforced object ownership. SQS queues have SQS-managed SSE. For mortgage production: assess SSE-KMS with scoped KMS key policies, log access, retention/legal hold, classification, document scanning, deletion lifecycle and privacy compliance. Bucket versions are deliberately not automatically deleted; define legal/compliance retention first.

## Production extension (not provisioned)
- **Network:** AWS account/environment segregation, VPC across 2-3 AZs, public ALB only, API/worker ECS Fargate tasks and RDS PostgreSQL in private subnets, SG allow 443 to API through ALB and PostgreSQL from exact task SG only. VPC endpoints for S3, SQS, ECR/CloudWatch/Secrets Manager as appropriate; tightly controlled egress/NAT where necessary.
- **Compute:** independent API and SQS worker ECS services, ECS task roles (separate execution roles), ECR immutable digest releases, ALB target health checks for API, ECS deployment circuit breaker, task limits and worker autoscaling based on queue backlog per worker and oldest age. Protect dependencies with concurrency caps.
- **Data:** RDS PostgreSQL Multi-AZ, encrypted backups, PITR, Secrets Manager rotation, connection pooling, minimal SG rules; atomic `document_id + processing_version` uniqueness to enforce idempotency. Object events/queue message payload limited to pointers and non-PII identifiers.
- **Observability:** structured scrubbed JSON logs, trace IDs, SQS backlog/oldest age/DLQ metrics, custom end-to-end job metrics, dashboards, incident alerts, data access audit.
- **Disaster recovery:** defined RPO/RTO, restore drills, regional dependency review, backups, queue/DLQ retention, and reprocessing protocol.

## CI/CD and secure AWS deployment extension
Current Actions workflow runs PR/push tests, Docker build, smoke test and Terraform format/init/validate checks without secrets or cloud provisioning. Local candidate image uses `sha-<12-char-commit>` tag (no mutable `latest`); registry push would additionally use the full commit digest/immutable image digest. Tag collision risk with short SHA is low but use **full SHA and digest** as authoritative production identity.

Production pipeline proposal: branch protection -> test/security/SBOM/image scan -> build once -> ECR push tagged by full git SHA -> assume *deployment-only* AWS role with GitHub OIDC and repo/environment/branch-scoped trust -> deploy ECS task definition pinned to ECR image **digest**, staged via GitHub environments -> validate API and worker metrics -> promote. No long-lived AWS keys. Deploy role only needs ECR push and narrowly scoped ECS task-definition/service-update and `iam:PassRole` for approved task roles; separate infrastructure provisioning role from app deploy role. See GitHub AWS OIDC docs: https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws . OIDC trust subject formats should be verified for the particular repo's GitHub settings.

**Failure/rollback:** fail closed if tests, scanning or health checks fail; halt deployment and alert. ECS deployment circuit breaker or CodeDeploy blue/green can revert to last healthy task definition and image digest (API ALB health + synthetic checks). For workers, pause/limit pollers as necessary, revert worker task definition and watch age/deletes/error metrics. Never roll back destructive DB schema changes blindly: use expand-contract backwards-compatible migrations. Record deployed SHA, task definition, rollback owner and recovery evidence.

## Assumptions, conscious tradeoffs and gaps
1. Task requires only a minimal HTTP service; **not** production document submission or consumption. Architecture arrows show proposed workflow, not implemented integration. A deployed ECS task would need an actual worker implementation.
2. SQS **standard** supports high throughput; duplicates are possible, so a future worker must implement durable idempotency. The example visibility timeout is 180 s, to be calibrated from observed p99 processing duration or extended via heartbeat. DLQ redrive max receive 5; no automatic replay.
3. IAM roles are defined but not attached until compute resources exist. S3 bucket name suffix must be unique if deployed.
4. No KMS customer-managed key, VPC, ECS, RDS, remote Terraform state, WAF, alarms as Terraform resources, or full audit plumbing are deployed; these exceed scope and are documented for production.
5. The app /health confirms process responsiveness only, not SQS or downstream progress. Separate business SLIs and alerts in runbook.
6. Evidence is captured honestly in `evidence/`; missing tooling is never reported as a successful test.
