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
| Alarm | Trigger | Intended response |
| --- | --- | --- |
| `DocumentQueueOldestAgeHigh` | `ApproximateAgeOfOldestMessage > 600 seconds` for 3 consecutive 5-minute periods; `TreatMissingData=notBreaching` | Page on-call, check arrival vs delete rates and worker task counts; evaluate controlled scale-out and downstream throttling. Threshold is illustrative; calibrate to SLO. |
| `DocumentDLQNonEmpty` | DLQ `ApproximateNumberOfMessagesVisible >= 1` for 2 consecutive 1-minute periods | Notify on-call, examine redacted error classes, stop runaway retries, fix root cause; replay only controlled validated messages. |

## Resolution criteria and review
- Oldest message age below agreed SLO for 30 minutes; sustained deletes >= incoming volume; no new unexpected DLQ messages; processing error rate normal and cost rate stable.
- Postmortem: customer impact, root cause, detection gap, duration, recovery actions, changes to dashboards/tests/alerts, accountable owners.
