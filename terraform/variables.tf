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

variable "dynamodb_table_name" {
  description = "DynamoDB table name for storing intrusion events"
  type        = string
  default     = "intrusion-events"
}
