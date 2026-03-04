output "honeypot_public_ip" {
  description = "Elastic IP address of the honeypot EC2 instance (share this publicly to attract scanners)"
  value       = aws_eip.honeypot_eip.public_ip
}

output "honeypot_instance_id" {
  description = "EC2 instance ID of the honeypot server"
  value       = aws_instance.honeypot.id
}

output "honeypot_public_dns" {
  description = "Public DNS hostname of the honeypot"
  value       = aws_eip.honeypot_eip.public_dns
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group name receiving Cowrie events"
  value       = aws_cloudwatch_log_group.honeypot_logs.name
}

output "dynamodb_table_name" {
  description = "DynamoDB table storing intrusion events"
  value       = aws_dynamodb_table.intrusion_events.name
}

output "lambda_function_name" {
  description = "Lambda log processor function name"
  value       = aws_lambda_function.log_processor.function_name
}

output "cloudwatch_dashboard_url" {
  description = "Direct URL to the CloudWatch intrusion dashboard"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.intrusion_dashboard.dashboard_name}"
}

output "vpc_id" {
  description = "VPC ID for the honeypot network"
  value       = aws_vpc.honeypot_vpc.id
}
