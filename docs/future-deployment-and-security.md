# Logikality — Future AWS Deployment & Security Proposal

**Document type:** Technical architecture and deployment proposal  
**Status:** Proposed; not deployed  
**Prepared:** 14 October 2026  
**Audience:** Engineering leadership

## 1. Executive summary

This document proposes the production evolution of Logikality's assessment implementation into a secure, resilient AWS document-processing platform. The current repository demonstrates a minimal Python HTTP API, Docker packaging, S3/SQS/DLQ and IAM definitions in Terraform, and a CI-only GitHub Actions workflow. **It does not currently deploy AWS compute or implement document upload and processing logic.** The design below is a future roadmap, not a description of resources already provisioned.

The recommended target is two independently scalable Amazon ECS Fargate services—an HTTP API and an asynchronous document worker—fronted by a TLS-enabled Application Load Balancer (API only), with private Amazon S3 object storage, Amazon SQS with a dead-letter queue, and Amazon RDS for PostgreSQL for job and document metadata. GitHub Actions would authenticate to AWS with OIDC, publish verified Docker images to Amazon ECR, and deploy digest-pinned ECS task revisions with health gates and rollback.

**Objectives:** preserve document confidentiality; avoid static AWS keys; minimize blast radius; support workload bursts; make releases repeatable, observable, and reversible; and define measurable recovery procedures.

## 2. Assessment baseline versus proposed production scope

| Capability           | Already in assessment                                               | Proposed for production                                                     |
| -------------------- | ------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| HTTP service         | `/`, `/health`, Python tests                                        | Authenticated document APIs, readiness and business SLIs                    |
| Containers           | Non-root Dockerfile and health check                                | ECR, hardened ECS task definitions, runtime limits                          |
| Object storage       | Private S3 bucket, SSE-S3, versioning, HTTPS-only policy            | KMS key strategy, lifecycle and retention, access logs, malware scanning    |
| Queueing             | Encrypted SQS standard queue, DLQ, redrive settings                 | Worker application, idempotency, backpressure and autoscaling               |
| Identity             | Distinct ECS task roles and scoped inline policies                  | Scoped task execution roles, deployment and Terraform roles, OIDC           |
| Network and database | Not implemented                                                     | Multi-AZ VPC, ALB, private ECS and PostgreSQL RDS                           |
| Delivery             | GitHub Actions tests, Docker build/smoke test, Terraform validation | Immutable ECR publication, protected approvals, ECS deployment and rollback |
| Operations           | Incident runbook draft                                              | CloudWatch alarms, tracing, runbooks, restore/rollback drills               |

## 3. Target architecture and document flow

```text
Authenticated user / mortgage operations portal
                      |
                HTTPS + WAF
                      |
        Public Application Load Balancer
                      |
        Private ECS Fargate: API service
               /                 \
      S3 incoming/          SQS jobs queue
                                |
                        Private ECS workers
                         /             \
                  S3 incoming/      RDS PostgreSQL
                         \
                     S3 processed/

   Failed messages after configured receive attempts -> SQS DLQ
```

1. An authenticated client requests a document upload; the API validates tenant, MIME/type, size and authorization. Where appropriate, it issues a short-lived, tightly scoped presigned URL rather than proxying large files.
2. The document lands in a private S3 `incoming/` prefix. Avoid sensitive details in object names and logs; verify content and scan suspicious files before use.
3. The API creates a durable job record and publishes an SQS message containing a job ID, tenant-scoped document ID, and object reference—not document bytes or customer PII.
4. A separate worker receives a message, claims the job idempotently, reads the object, performs processing, commits metadata/result status, then deletes the message. SQS standard delivery is at least once: duplicates are expected and safe handling is mandatory.
5. Transient errors are retried with bounded attempts and visibility control. Poison messages move to the DLQ for controlled inspection and replay.

**Reliability design note:** a database outbox or reconciler is needed so storing a document/job record and enqueuing work cannot silently diverge on partial failure. An S3 event-based alternative should be evaluated based on workflow requirements.

## 4. Production infrastructure rollout

### Stage 0 — Establish accounts, environments and governance

- Separate at least development and production AWS accounts; ideally add staging. Organize with AWS Organizations and guardrails.
- Set account-level S3 Block Public Access, CloudTrail audit logging, IAM Identity Center/federated access, AWS Config/Security Hub where justified, MFA and break-glass procedures.
- Establish tagging, budgets, cost alerts, data-classification rules, retention requirements and incident ownership before receiving sensitive production documents.
- Create production Terraform remote state in an encrypted S3 bucket with state locking, narrowly scoped access and backup/versioning. The assessment's local validation is intentionally backend-free.

### Stage 1 — Networking and shared services

- Create a VPC spanning **at least two Availability Zones**. Place the ALB in public subnets and ECS tasks/RDS in private subnets; do not assign ECS or database public IPs.
- Allow inbound TLS 443 to ALB; only ALB security group to API container port; only approved task security groups to RDS TCP 5432. Workers require no inbound internet-facing port.
- Use a private RDS subnet group and encrypted RDS PostgreSQL Multi-AZ for metadata, with automated backups/PITR and Secrets Manager rotation.
- Use appropriate VPC endpoints (S3 gateway; SQS/ECR/CloudWatch Logs/Secrets Manager interfaces where suitable), route tables and egress controls. NAT or a controlled egress proxy is required if workers call external AI services.
- Create an ECR repository with tag immutability, scanning and lifecycle policies.

### Stage 2 — Compute and application services

- Build separate **API** and **worker** ECS Fargate services, each with explicit CPU/memory, task and execution roles, log groups, health management and task limits.
- Set API ALB target group health checks to `/health`, plus deeper authenticated synthetic monitoring outside the load balancer.
- Scale API based on request rate/CPU/latency. Scale workers using queue backlog per running worker, oldest-message age, processing duration and downstream capacity; implement upper bounds to protect AI API and database costs.
- Implement real document upload, job state machine, idempotency and worker acknowledgement logic before serving customer traffic.

### Stage 3 — Hardening, verification and go-live

- Validate threat model, IAM policy simulator/access analyzer, IaC scanning, image scanning and dependency/SBOM findings.
- Run integration tests against nonproduction S3/SQS/RDS, performance/load tests, failure-injection tests and recovery drills.
- Prove backups can restore within approved RPO/RTO; test poison-message replay and ECS rollback while verifying jobs remain recoverable.
- Require security and product owner sign-off before allowing production mortgage documents.

## 5. Future CI/CD deployment workflow

**Current CI (implemented):** PR and push to `main` trigger Python tests, Docker image build, HTTP smoke test, Terraform formatting/init/validate. No AWS credentials or deployment.

**Proposed delivery workflow:**

1. **Pull request gate:** require peer review, passing CI, Terraform/static checks, dependency and image vulnerability scans. Pin third-party actions to reviewed full commit SHAs and apply least-privilege `GITHUB_TOKEN` permissions.
2. **Build once:** produce image from the approved commit, record full Git SHA, SBOM, scan results and provenance. Do not embed secrets into image layers or logs.
3. **Publish to ECR:** configure GitHub OIDC for a repository/environment-restricted deployment IAM role; enable ECR immutable tags; push using the full SHA; resolve the published `sha256` image digest.
4. **Staging:** register a new ECS task definition containing the _digest-pinned_ ECR image; deploy to staging; wait for ECS stability and run functional, authentication and queue-processing smoke tests.
5. **Approve production:** use protected GitHub environments and required reviewers; limit production release triggers to the approved source ref. Use separate deployment roles and AWS accounts for staging and production.
6. **Production rollout:** register task revision, update the ECS API service with rolling deployment, ECS circuit breaker plus relevant CloudWatch alarm rollback, and verify ALB targets, API 5xx and latency. Deploy workers separately, controlling worker count/polling and preserving queued jobs.
7. **Post-deploy verification:** record release SHA, image digest, task definition ARN, deployment outcome, error rates, queue age, DLQ growth and responsible approver. Promote only if acceptance gates remain healthy.

**Policy:** deployments must reuse a verified artifact rather than independently rebuilding unverified code. A failed test, scan, approval or health gate prevents promotion. Do not use a mutable `latest` image for production ECS task definitions.

## 6. Security design (defense in depth)

### 6.1 Identity, roles and secrets

| Identity                    | Trust boundary                                                                                | Minimum expected permissions                                                                                                                                   |
| --------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GitHub CI                   | GitHub-hosted runner                                                                          | Repository read; no AWS permissions                                                                                                                            |
| GitHub deployment role      | GitHub OIDC subject restricted to authorized repo/ref/environment and `aud=sts.amazonaws.com` | Push to a named ECR repository; update named ECS services; register tasks; `iam:PassRole` only for approved ECS roles                                          |
| Terraform provisioning role | Approved infrastructure workflow / designated operators                                       | Create and update required resources only; separate from app deploy role; tightly audited                                                                      |
| ECS task execution role     | ECS tasks                                                                                     | Pull approved ECR images, write to target log group, retrieve authorized injected secrets                                                                      |
| API task role               | ECS API tasks                                                                                 | `s3:PutObject` to `incoming/*`, `sqs:SendMessage` to designated queue; production additions only when justified                                                |
| Worker task role            | ECS worker tasks                                                                              | `sqs:ReceiveMessage/DeleteMessage/ChangeMessageVisibility/GetQueueAttributes` on jobs queue; `s3:GetObject` from `incoming/*`; `s3:PutObject` to `processed/*` |

- Avoid hardcoded AWS access keys, static credentials in GitHub Secrets, or secrets in Terraform source/state wherever possible.
- Verify the GitHub OIDC `sub` claim format for the actual repository: newer repositories may use immutable identifier-based subjects. Restrict the AWS role trust policy accordingly; do not assume one string works for every repository.
- Store database credentials and external AI API keys in AWS Secrets Manager; audit access and rotate on a defined schedule. Where possible, use IAM-based authentication instead of passwords.
- Review `iam:PassRole` permissions carefully to prevent escalation; do not use wildcard administrator policies.

### 6.2 Network and API protection

- Put only the ALB in public subnets. Keep API, workers, queues (via AWS APIs), and database non-public.
- Terminate TLS with ACM certificates at the ALB and use TLS for service-to-service and RDS connections; consider WAF managed rules, rate limits, and bot defenses.
- Validate client authentication and tenant-level authorization on every document operation. Presigned URLs must be short-lived and scoped to one object/action with upload constraints.
- Limit task security groups and outbound egress; log network flows where required; use VPC endpoints and endpoint policies to narrow AWS service access.

### 6.3 Document, database and queue data protection

- Retain S3 Block Public Access and bucket-owner enforced ACL disabling. Keep bucket and object-level authorization explicit; enforce TLS. Consider customer-managed SSE-KMS keys when required by key-control or auditing policy. <https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html>
- Define lifecycle, retention, legal-hold and deletion policies with compliance stakeholders before enabling automatic deletion; turn on S3 data-event logging where appropriate.
- Use SQS encryption and IAM-scoped send/receive actions. Add an SQS resource policy explicitly denying non-TLS requests and consider VPC endpoint restrictions after validating required producer paths. <https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-security-best-practices.html>
- Never put document bytes, national identifiers, account numbers, or customer names in SQS message bodies, object key names, traces or logs without a documented need and protections.
- Encrypt RDS storage and backups, require TLS connections, tightly control security groups and database credentials, and log database events consistent with privacy rules.
- Add file scanning, type sniffing, content limits, and quarantine before downstream AI or OCR parsing; treat document contents as untrusted input, including prompt-injection risk for AI components.

### 6.4 Platform, supply-chain and operational security

- Run ECS containers as non-root, with a read-only root filesystem if application-compatible, dropped capabilities where supported, and explicit CPU/memory/task limits.
- Use a maintained minimal base image; pin images/digests, scan dependencies and images, generate an SBOM, and avoid unreviewed privileged containers.
- Enable CloudTrail, CloudWatch logs and alarms; consider GuardDuty, Security Hub and AWS Config according to risk. Redact PII and secrets from application logs and limit retention/access.
- Define tenant isolation, audit evidence, least-privilege reviews, incident escalation, vulnerability remediation SLAs, and data-subject handling with legal/compliance teams. Do not assert HIPAA/SOC 2 compliance solely from AWS service configuration.

## 7. Rollback, failure response and reliability

| Failure stage                       | Detection                                       | Response                                                                                          |
| ----------------------------------- | ----------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Test or vulnerability gate fails    | GitHub Action nonzero result                    | Do not publish/deploy; fix or formally adjudicate exceptions                                      |
| ECR push or OIDC assumption fails   | GitHub Actions / AWS STS error                  | Stop release; inspect OIDC trust, repository claim, IAM, ECR permissions                          |
| ECS task fails to start             | ECS service events, task stopped reason         | Halt rollout; inspect ECR access, network endpoints, secrets, CPU/memory and logs                 |
| API health/5xx/latency worsens      | ALB target health, CloudWatch alarms            | ECS circuit breaker/alarms roll back when correctly configured; verify service recovery           |
| Worker errors or queue age increase | SQS oldest age/backlog, worker failures, DLQ    | Limit worker concurrency, stop bad revision, redeploy last good worker image; do not purge queues |
| Schema incompatibility              | Error logs, DB metrics, integration checks      | Roll back application only if schema compatible; use expand–migrate–contract strategy             |
| Security incident                   | GuardDuty/audit events, unusual IAM/data access | Restrict access, preserve evidence, rotate compromised secrets, invoke incident process           |

**ECS rollback limitation:** ECS rollback requires a previously completed deployment; test this in staging. Circuit-breaker rollback mainly detects deployment failures, not an outage that appears hours after deployment. Add post-deploy SLO monitoring and a documented manual reversal path. <https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html>

**Recovery and replay:** do not purge queues as a quick fix. For DLQ replay, first classify poison messages, correct the cause, retain job IDs and deduplicate processing, and redrive in rate-limited batches. Define backups and restore drills against agreed recovery-time/recovery-point objectives.

## 8. Observability, SLOs and cost safeguards

| Signal / control                                              | Purpose                                | Initial proposed rule (calibrate with load tests)                                             |
| ------------------------------------------------------------- | -------------------------------------- | --------------------------------------------------------------------------------------------- |
| `ApproximateAgeOfOldestMessage`                               | Detect customer waiting time / backlog | Page if > 300 seconds for 10 minutes, excluding known poison-message anomalies                |
| `ApproximateNumberOfMessagesVisible` and running worker count | Backlog per worker                     | Alert on sustained growth for 15 minutes when processing throughput falls behind arrival rate |
| DLQ visible messages                                          | Poison jobs / repeated failure         | Alert on any new DLQ message for 5 minutes; page based on impact                              |
| Job completion latency p95/p99                                | End-to-end business processing SLI     | Define target with business owner and alert on sustained breach                               |
| ECS restart count, task OOM, CPU and memory                   | Worker saturation and instability      | Alert on repeated task failures or sustained high resource utilization                        |
| RDS connections, CPU, slow queries                            | Database contention                    | Monitor saturation and query latency during backlog events                                    |
| AWS Budgets + worker max task count                           | Cost controls                          | Monthly budget thresholds and scaling upper bound tied to downstream quotas                   |

Queues can be healthy while the API is healthy, and vice versa. `/health` is not a complete system-health indicator. The repository's `incident-runbook.md` contains the operational response to queue backlog, retries, DLQ growth and cost increases.

## 9. Implementation order and acceptance criteria

| Phase            | Deliverables                                                               | Acceptance criteria                                                                          |
| ---------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| 1. Foundation    | Accounts, remote Terraform state, IAM boundaries, network                  | Multi-AZ design reviewed; no unintended public resource access; Terraform plan peer-reviewed |
| 2. Data services | S3, SQS/DLQ, RDS, KMS/secrets strategy                                     | Encryption, TLS, access boundaries and recovery tested in nonproduction                      |
| 3. Application   | API/worker ECS services, S3/SQS integration, idempotency                   | Duplicate delivery doesn't duplicate business outcomes; poison jobs safely isolated          |
| 4. Delivery      | OIDC role, ECR, staging/prod GitHub environments, digest-pinned ECS deploy | No static AWS keys; test and security gates pass; release artifact traceable to source       |
| 5. Reliability   | Alerts, dashboards, backup/restore and rollback drills                     | Alarms trigger correctly; known-good release restored; recovery targets measured             |
| 6. Go-live       | Security review, load testing, runbooks, product sign-off                  | Explicit approval and evidence retained; no unresolved critical risks                        |

## 10. Deliberate exclusions and assumptions

- This proposal does not claim that ECS, RDS, VPC, KMS customer-managed keys, ECR, WAF, OIDC trust or deployment resources already exist in the submitted Terraform.
- The current Python HTTP service exposes only `/` and `/health`; it cannot yet upload a document, publish to SQS or process a job.
- Exact instance sizing, RPO/RTO, latency objectives, encryption key boundaries and regulatory retention require workload measurements and business/security approval.
- Production cloud cost will be incurred only when resources are actually created; the assessment remains safe to validate without deployment.

## 11. Authoritative references

- GitHub, _Configuring OpenID Connect in Amazon Web Services_: https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws
- AWS, _Amazon S3 security best practices_: https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html
- AWS, _Amazon SQS security best practices_: https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-security-best-practices.html
- AWS, _ECS deployment circuit breaker_: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html
- AWS, _ECS deployment failure detection_: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-failure-detection.html
