variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment label"
  type        = string
  default     = "production"
}

variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "cloud-intrusion-platform"
}

variable "honeypot_instance_type" {
  description = "EC2 instance type for the honeypot server (Free Tier: t2.micro)"
  type        = string
  default     = "t2.micro"
}

variable "key_pair_name" {
  description = "Name of an existing EC2 key pair for SSH access to the honeypot"
  type        = string
}

variable "admin_ssh_cidr" {
  description = "CIDR block allowed to SSH into the honeypot for management (your IP/32)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "dynamodb_table_name" {
  description = "DynamoDB table name for storing intrusion events"
  type        = string
  default     = "intrusion-events"
}

variable "log_retention_days" {
  description = "CloudWatch log retention period in days"
  type        = number
  default     = 30
}

variable "lambda_memory_mb" {
  description = "Memory allocation for the log processor Lambda function"
  type        = number
  default     = 128
}

variable "lambda_timeout_seconds" {
  description = "Timeout for the log processor Lambda function"
  type        = number
  default     = 30
}
