variable "aws_region" {
  type    = string
  default = "ap-south-1"
}
variable "project_name" {
  type    = string
  default = "logikality"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "Use a lowercase project name 3-21 characters long."
  }
}
variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging or prod."
  }
}
variable "bucket_suffix" {
  type        = string
  description = "Globally unique lowercase suffix for the S3 bucket; provide at deployment time."
  default     = "lab"
}
