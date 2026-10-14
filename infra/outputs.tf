output "document_bucket_name" { value = aws_s3_bucket.documents.bucket }
output "jobs_queue_url" { value = aws_sqs_queue.jobs.url }
output "jobs_queue_arn" { value = aws_sqs_queue.jobs.arn }
output "dlq_url" { value = aws_sqs_queue.dlq.url }
output "api_task_role_arn" { value = aws_iam_role.api.arn }
output "worker_task_role_arn" { value = aws_iam_role.worker.arn }
