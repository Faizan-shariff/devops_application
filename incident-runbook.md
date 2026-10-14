# Incident Runbook: SQS backlog / high processing latency

**Severity:** SEV-2 if oldest queued document > 10 min for 10 min, escalate to SEV-1 if contractual processing deadlines/customer operations are impaired. API /health is not a measure of queue processing readiness.

## First 5 minutes: establish impact and scope

1. Acknowledge incident; assign incident commander, communications owner, and investigator. Identify affected customer cohorts; record start time, deployment/config changes, and SLO impact. Avoid uploading document payloads to tickets or logs.
2. CloudWatch SQS: `ApproximateNumberOfMessagesVisible` (backlog), `ApproximateNumberOfMessagesNotVisible` (in-flight), `ApproximateAgeOfOldestMessage` (waiting time), `NumberOfMessagesSent`, `NumberOfMessagesReceived`, `NumberOfMessagesDeleted`, DLQ visible count. These are approximate, not exact transaction counts.
3. Compute: active ECS task count vs desired, worker restarts/OOM/CPU/memory, scaling activity, deployment events, task startup errors. Check request latency and errors of downstream OCR/AI, S3 4xx/5xx, database connections/lock waits, throttling, NAT egress/network timeouts, and CloudWatch spend.
4. Correlate sanitized worker logs using `job_id`, `message_id`, `attempt`, duration by processing stage, error type, and deployment SHA. Never emit borrower PII or entire message/document body.

## Diagnose systematically

- **Visible and oldest age rise; in-flight low**: too few consumers, workers down, scaling misconfiguration, receive permissions or connectivity failure. Verify `ReceiveMessage` success and ECS desired/running counts.
- **In-flight high, deletes low, processing duration high**: slow dependency, stuck CPU work, DB contention, timeouts or visibility timeout shorter than work. Compare queue received/deleted rates and per-stage p95.
- **Receives high; deletes low; DLQ grows**: repeated failures/poison messages or transient downstream outage. Sample redacted error classes and DLQ attributes, not sensitive payloads.
- **Sent rate > sustained delete rate**: insufficient effective capacity even with healthy workers. Estimate time to drain as `backlog / (deletes_per_min - arrivals_per_min)` only if delete rate exceeds arrival rate.
- **Cost rising**: retries, extra tasks, repeated OCR/AI invocations, SQS empty polling, excessive logs, NAT data processing. Attribute spend with service metrics and cost tags.

## Mitigate customer impact

1. Protect critical traffic: pause or throttle nonessential ingestion; apply bounded rate limits and communicate expected delay. Do **not** purge the main queue.
2. If workers are healthy and downstream headroom exists, increment ECS desired count / adjust queue-depth autoscaling gradually; cap concurrency to avoid overloading RDS/OCR/AI providers.
3. If regression follows a deployment, roll workers back to the last known-good image digest/task-definition revision and verify deletion throughput and error rates. Keep failed messages for analysis.
4. If downstream is failing, activate circuit breakers and backoff; temporarily reduce consumers to protect cost and provider quota. Handle persistent failures through DLQ (maxReceiveCount=5) and investigate before controlled redrive.
5. Track SQS oldest age, DLQ count, processing success %, p95 stage latency, and customer backlog until recovery. Close incident after sustained recovery; schedule postmortem with owner and deadlines.

## Retry storms and duplicate processing

- SQS standard delivers at least once. Use stable `document_id` + `processing_version` as idempotency key. Store atomic state transition (e.g. unique constraint in RDS) and guard side effects; process output using deterministic object key. Exactly-once end-to-end is **not** guaranteed by SQS.
- Delete message **only after** durable successful processing/commit. Never delete just on receive. If already completed, safely acknowledge duplicate.
- Set visibility timeout longer than normal duration (example 180 s here) and use `ChangeMessageVisibility` heartbeats for long work; design for worker crash/timeout. SQS redelivery can occur even within nominal visibility assumptions in exceptional cases, hence the idempotency guard.
- Bound retries, use jittered exponential backoff at application/dependency layers, limit max attempts via DLQ and quarantine poison messages. Note SQS redrive count is not a scheduled exponential backoff mechanism; for longer retries use delayed requeue/EventBridge Scheduler with explicit control.
- Redrive DLQ only after fix with rate controls and deduplication checks; use separate investigation permissions and no routine worker DLQ read access.

## Actionable CloudWatch alarms

| Alarm                        | Trigger                                                                                                           | Intended response                                                                                                                                                         |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DocumentQueueOldestAgeHigh` | `ApproximateAgeOfOldestMessage > 600 seconds` for 3 consecutive 5-minute periods; `TreatMissingData=notBreaching` | Page on-call, check arrival vs delete rates and worker task counts; evaluate controlled scale-out and downstream throttling. Threshold is illustrative; calibrate to SLO. |
| `DocumentDLQNonEmpty`        | DLQ `ApproximateNumberOfMessagesVisible >= 1` for 2 consecutive 1-minute periods                                  | Notify on-call, examine redacted error classes, stop runaway retries, fix root cause; replay only controlled validated messages.                                          |

## Resolution criteria and review

- Oldest message age below agreed SLO for 30 minutes; sustained deletes >= incoming volume; no new unexpected DLQ messages; processing error rate normal and cost rate stable.
- Postmortem: customer impact, root cause, detection gap, duration, recovery actions, changes to dashboards/tests/alerts, accountable owners.

## Operator command reference (production extension; not executed for this assessment)

Set actual AWS account/region/queue identifiers before using these commands. The assessment provisions no live AWS resources; these examples are read-only except where clearly labeled. Avoid accessing message bodies containing borrower information.

```bash
export AWS_REGION=ap-south-1
export QUEUE_NAME=logikality-prod-documents
export DLQ_NAME=logikality-prod-documents-dlq
export ECS_CLUSTER=logikality-prod
export ECS_WORKER_SERVICE=logikality-worker

# Inspect approximate queue state without reading document payloads
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$QUEUE_NAME" --query QueueUrl --output text --region "$AWS_REGION")
aws sqs get-queue-attributes --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible VisibilityTimeout RedrivePolicy \
  --region "$AWS_REGION"

# Inspect recent CloudWatch SQS metrics (fill in explicit UTC timestamps)
aws cloudwatch get-metric-statistics --namespace AWS/SQS \
  --metric-name ApproximateAgeOfOldestMessage \
  --dimensions Name=QueueName,Value="$QUEUE_NAME" \
  --start-time 2026-10-14T09:00:00Z --end-time 2026-10-14T10:00:00Z \
  --period 300 --statistics Maximum --region "$AWS_REGION"

# Compare ECS task availability with expected capacity
aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_WORKER_SERVICE" \
  --query 'services[].{desired:desiredCount,running:runningCount,pending:pendingCount,events:events[0:5]}' \
  --region "$AWS_REGION"
```

Adapt the time range to the live incident. For log investigation, use CloudWatch Logs Insights against a restricted worker log group. Example, assuming structured JSON logs and a `job_id` field:

```sql
fields @timestamp, job_id, attempt, stage, duration_ms, error_type, deployment_sha
| filter level = "ERROR"
| stats count(*) as failures by error_type, stage
| sort failures desc
| limit 20
```

This query is illustrative and requires the proposed worker to emit the named structured fields; the assessment HTTP application does not yet emit them. Never include document content, S3 presigned URLs, borrower names, or personally identifiable data in operational logs.

## Decision tree with concrete actions

1. **Check ingestion versus completion.** Compare `NumberOfMessagesSent` to `NumberOfMessagesDeleted` (both `Sum` over matching intervals); compare with application-level `jobs_completed_total`. If arrivals consistently exceed completions, there is negative capacity headroom.
2. **Check worker availability.** If visible backlog grows, inflight remains low, and ECS `runningCount < desiredCount`, inspect task launch errors, execution role, image access, networking, and recent rollouts. Restore availability before increasing desired count.
3. **Check slow work.** If inflight remains high and deletes are low, correlate worker CPU/memory, `processing_duration` p95, RDS waits, S3 errors, OCR/AI latency, and third-party rate limits. Check whether `VisibilityTimeout=180` is shorter than actual processing duration; if so, use explicit `ChangeMessageVisibility` heartbeat and idempotency, not blind retry escalation.
4. **Check repeated failure.** If receives rise much faster than completed jobs and DLQ grows, classify errors by permanent input errors, transient 429/5xx, broken credentials, bad releases, and network timeouts. Do not retrieve raw production messages without approval and a privacy-safe procedure.
5. **Mitigate deliberately.** Rate-limit intake if necessary; roll back a regression; otherwise scale healthy workers only after confirming DB/OCR/AI headroom. Disable unbounded worker-side retry loops, apply capped exponential backoff with jitter, and preserve failed jobs in DLQ for controlled recovery.
6. **Verify recovery.** Confirm decreasing age and visible backlog, stable job completion rate above arrivals, no new unexpected DLQ messages, restored p95 processing time, and normalized cloud cost trends.

## Backlog and capacity example

If 1,200 messages are waiting, arrivals are 40 jobs/minute and completed processing is 60 jobs/minute, net drain is 20 jobs/minute and the approximate drain time is 1,200/20 = **60 minutes**. If completion rate is 40/minute or lower, the backlog will not drain without reducing arrivals or increasing safe throughput. This model is an approximation and assumes stable rates and no major retries.

## Alarm implementation notes

Use `AWS/SQS` and dimension `QueueName` on the **main queue** for `ApproximateAgeOfOldestMessage`, statistic `Maximum`, period 300 seconds, threshold `>600`, evaluation periods 3, datapoints to alarm 3, and `TreatMissingData=notBreaching`. Send to the on-call SNS/paging integration. If the queue has poison messages, age metrics alone can underrepresent their wait; pair with DLQ monitoring and application job-age telemetry.

For `DocumentDLQNonEmpty`, use `ApproximateNumberOfMessagesVisible` on the **DLQ**, statistic `Maximum`, 60-second period, threshold `>=1`, evaluation periods 2, datapoints 2, and `TreatMissingData=notBreaching`. Notify on-call and attach a triage runbook; never automatically replay all DLQ messages.

Thresholds are preliminary proposals to calibrate against production SLOs and traffic. SQS metric publication is approximate, and alarm observation depends on metric availability.

## Idempotency design for planned RDS-backed worker

Use a unique `(document_id, processing_version)` business key in RDS, combined with an atomic processing state machine. Workers claim a job with a guarded transaction / lease, store outputs using deterministic S3 object keys, commit completion in durable storage, and then delete the SQS message. On redelivery, already completed jobs can be safely acknowledged. For external OCR/AI providers or billing side effects, use provider idempotency tokens where supported or durable side-effect records. A database uniqueness constraint alone does not magically make externally executed side effects exactly-once.

## Explicit out-of-scope notes

The current repository contains a minimal HTTP server, not an ECS worker or an active AWS deployment. ECS dashboards, CloudWatch application logs, RDS telemetry, and the alarms described here are **proposed production operations**. No real customer incident was simulated or production AWS commands executed in this assessment.

## Reference documentation

- [AWS SQS CloudWatch metrics](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-available-cloudwatch-metrics.html)
- [AWS SQS visibility timeout](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html)
- [AWS CloudWatch recommended SQS alarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Best_Practice_Recommended_Alarms_AWS_Services.html)
