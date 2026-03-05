# ─────────────────────────────────────────────────────────────
#  Data Sources
# ─────────────────────────────────────────────────────────────

# Retrieve the latest Amazon Linux 2023 AMI (Free Tier eligible)
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_caller_identity" "current" {}

# ─────────────────────────────────────────────────────────────
#  Networking – VPC / Subnet / IGW
# ─────────────────────────────────────────────────────────────

resource "aws_vpc" "honeypot_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "honeypot_igw" {
  vpc_id = aws_vpc.honeypot_vpc.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_subnet" "honeypot_public_subnet" {
  vpc_id                  = aws_vpc.honeypot_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

resource "aws_route_table" "honeypot_rt" {
  vpc_id = aws_vpc.honeypot_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.honeypot_igw.id
  }

  tags = {
    Name = "${var.project_name}-route-table"
  }
}

resource "aws_route_table_association" "honeypot_rta" {
  subnet_id      = aws_subnet.honeypot_public_subnet.id
  route_table_id = aws_route_table.honeypot_rt.id
}

# ─────────────────────────────────────────────────────────────
#  Security Group – allow all inbound SSH (honeypot bait)
# ─────────────────────────────────────────────────────────────

resource "aws_security_group" "honeypot_sg" {
  name        = "${var.project_name}-honeypot-sg"
  description = "Security group for honeypot EC2 instance"
  vpc_id      = aws_vpc.honeypot_vpc.id

  # Fake SSH (port 22) - Cowrie listens here; lures attackers
  ingress {
    description = "Honeypot SSH bait - open to internet"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Fake Telnet (port 23) – extra bait
  ingress {
    description = "Honeypot Telnet bait"
    from_port   = 23
    to_port     = 23
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Real management SSH on port 2222
  ingress {
    description = "Admin SSH for management"
    from_port   = 2222
    to_port     = 2222
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-honeypot-sg"
  }
}

# ─────────────────────────────────────────────────────────────
#  IAM – EC2 Instance Role (CloudWatch + SSM)
# ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "honeypot_ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "honeypot_ec2_policy" {
  name = "${var.project_name}-ec2-policy"
  role = aws_iam_role.honeypot_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.honeypot_logs.arn}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/*"
      }
    ]
  })
}

# Attach SSM managed core policy so we can use Session Manager (no bastion needed)
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.honeypot_ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "honeypot_profile" {
  name = "${var.project_name}-ec2-instance-profile"
  role = aws_iam_role.honeypot_ec2_role.name
}

# ─────────────────────────────────────────────────────────────
#  CloudWatch Log Group
# ─────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "honeypot_logs" {
  name              = "/honeypot/${var.project_name}/cowrie"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-log-group"
  }
}

resource "aws_cloudwatch_log_stream" "cowrie_stream" {
  name           = "cowrie-events"
  log_group_name = aws_cloudwatch_log_group.honeypot_logs.name
}

# ─────────────────────────────────────────────────────────────
#  SSH Key Pair (auto-generated – no manual input required)
# ─────────────────────────────────────────────────────────────

resource "tls_private_key" "honeypot" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "honeypot" {
  key_name   = "${var.project_name}-keypair"
  public_key = tls_private_key.honeypot.public_key_openssh

  tags = {
    Name = "${var.project_name}-keypair"
  }
}

# ─────────────────────────────────────────────────────────────
#  EC2 Honeypot Instance
# ─────────────────────────────────────────────────────────────

resource "aws_instance" "honeypot" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t2.micro"
  subnet_id              = aws_subnet.honeypot_public_subnet.id
  key_name               = aws_key_pair.honeypot.key_name
  iam_instance_profile   = aws_iam_instance_profile.honeypot_profile.name
  vpc_security_group_ids      = [aws_security_group.honeypot_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = base64encode(templatefile("${path.module}/../scripts/install.sh", {
    log_group_name  = aws_cloudwatch_log_group.honeypot_logs.name
    log_stream_name = aws_cloudwatch_log_stream.cowrie_stream.name
    aws_region      = var.aws_region
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  monitoring = true

  tags = {
    Name = "${var.project_name}-honeypot"
    Role = "honeypot"
  }
}

# ─────────────────────────────────────────────────────────────
#  Elastic IP
# ─────────────────────────────────────────────────────────────

resource "aws_eip" "honeypot_eip" {
  instance = aws_instance.honeypot.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }

  depends_on = [aws_internet_gateway.honeypot_igw]
}

# ─────────────────────────────────────────────────────────────
#  DynamoDB – Intrusion Events Table
# ─────────────────────────────────────────────────────────────

resource "aws_dynamodb_table" "intrusion_events" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST" # On-demand – no minimum charge
  hash_key     = "event_id"
  range_key    = "timestamp"

  attribute {
    name = "event_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "attacker_ip"
    type = "S"
  }

  global_secondary_index {
    name            = "AttackerIpIndex"
    hash_key        = "attacker_ip"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name = "${var.project_name}-intrusion-table"
  }
}

# ─────────────────────────────────────────────────────────────
#  IAM – Lambda Execution Role
# ─────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda_exec_role" {
  name = "${var.project_name}-lambda-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "${aws_cloudwatch_log_group.honeypot_logs.arn}:*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:BatchWriteItem"
        ]
        Resource = [
          aws_dynamodb_table.intrusion_events.arn,
          "${aws_dynamodb_table.intrusion_events.arn}/index/*"
        ]
      }
    ]
  })
}

# ─────────────────────────────────────────────────────────────
#  Lambda – Log Processor Function
# ─────────────────────────────────────────────────────────────

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/log_processor.py"
  output_path = "${path.module}/../lambda/log_processor.zip"
}

resource "aws_lambda_function" "log_processor" {
  function_name    = "${var.project_name}-log-processor"
  role             = aws_iam_role.lambda_exec_role.arn
  handler          = "log_processor.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  memory_size      = 128
  timeout          = 30

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = aws_dynamodb_table.intrusion_events.name
      LOG_GROUP_NAME      = aws_cloudwatch_log_group.honeypot_logs.name
      ACCOUNT_ID          = data.aws_caller_identity.current.account_id
    }
  }

  tags = {
    Name = "${var.project_name}-log-processor"
  }
}

# Allow CloudWatch Logs to invoke this Lambda
resource "aws_lambda_permission" "allow_cloudwatch_logs" {
  statement_id  = "AllowCloudWatchLogsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_processor.function_name
  principal     = "logs.${var.aws_region}.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.honeypot_logs.arn}:*"
}

# Subscribe Lambda to CloudWatch log group
resource "aws_cloudwatch_log_subscription_filter" "lambda_trigger" {
  name            = "${var.project_name}-lambda-trigger"
  log_group_name  = aws_cloudwatch_log_group.honeypot_logs.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.log_processor.arn

  depends_on = [aws_lambda_permission.allow_cloudwatch_logs]
}

# ─────────────────────────────────────────────────────────────
#  CloudWatch Dashboard
# ─────────────────────────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "intrusion_dashboard" {
  dashboard_name = "${var.project_name}-dashboard"
  dashboard_body = templatefile("${path.module}/../dashboards/cloudwatch_dashboard.json", {
    aws_region          = var.aws_region
    log_group_name      = aws_cloudwatch_log_group.honeypot_logs.name
    dynamodb_table_name = aws_dynamodb_table.intrusion_events.name
    lambda_function     = aws_lambda_function.log_processor.function_name
    instance_id         = aws_instance.honeypot.id
  })
}

# ─────────────────────────────────────────────────────────────
#  CloudWatch Alarms
# ─────────────────────────────────────────────────────────────

resource "aws_cloudwatch_metric_alarm" "high_intrusion_rate" {
  alarm_name          = "${var.project_name}-high-intrusion-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "IncomingLogEvents"
  namespace           = "AWS/Logs"
  period              = 300
  statistic           = "Sum"
  threshold           = 100
  alarm_description   = "More than 100 honeypot events in 5 minutes - possible attack campaign"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LogGroupName = aws_cloudwatch_log_group.honeypot_logs.name
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Lambda log processor is throwing errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.log_processor.function_name
  }
}
