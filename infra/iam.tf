data "aws_iam_policy_document" "ecs_tasks_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "api" {
  name               = "${local.prefix}-api-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}
resource "aws_iam_role" "worker" {
  name               = "${local.prefix}-worker-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_trust.json
}
data "aws_iam_policy_document" "api" {
  statement {
    sid       = "UploadDocuments"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.documents.arn}/incoming/*"]
  }
  statement {
    sid       = "EnqueueJobs"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.jobs.arn]
  }
}
data "aws_iam_policy_document" "worker" {
  statement {
    sid       = "ConsumeJobs"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.jobs.arn]
  }
  statement {
    sid       = "ReadInputs"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.documents.arn}/incoming/*"]
  }
  statement {
    sid       = "WriteOutputs"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.documents.arn}/processed/*"]
  }
}
resource "aws_iam_role_policy" "api" {
  name   = "api-data-access"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}
resource "aws_iam_role_policy" "worker" {
  name   = "worker-data-access"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}
