# Cloud Intrusion Behavior Analytics Platform - Deployment Guide

## Overview
This is a fully automated AWS honeypot intrusion detection platform. All infrastructure deploys with **zero manual input** using Terraform.

## What Gets Deployed

### 1. **Honeypot EC2 Instance**
- **Instance Type**: t2.micro (Free Tier eligible)
- **AMI**: Amazon Linux 2023 (latest)
- **Disk**: 30GB gp3 (encrypted root volume)
- **Honeypot Service**: Cowrie SSH/Telnet honeypot (Docker container)
- **Networking**: VPC + Public Subnet + Elastic IP
- **Security Group**: Allows inbound on ports 22, 23 (honeypot bait)

### 2. **Log Processing Pipeline**
- **CloudWatch Log Group**: `/honeypot/cloud-intrusion-platform/cowrie`
- **CloudWatch Agent**: Monitors `/var/log/cowrie/` files on EC2
- **Lambda Function**: `log-processor` (Python 3.12)
  - Processes Cowrie JSON event logs
  - Parses authentication attempts, session connections, command execution
  - Writes to DynamoDB intrusion_events table

### 3. **Data Storage**
- **DynamoDB Table**: `intrusion-events`  
  - On-demand billing (no minimum charge)
  - Attributes: timestamp, event_type, attacker_ip, username, password, command, source_ip/port
  - Global Secondary Index on `attacker_ip` for analytics

### 4. **Monitoring & Analytics**
- **CloudWatch Dashboard**: 12-widget visualization
  - Log event counts and trends
  - Lambda invocation metrics
  - Top attacker IPs and attempted usernames
  - Cowrie logs insights queries
  - EC2 CPU, memory, network metrics

### 5. **Alarms**
- High intrusion rate alert
- Lambda error monitoring  

---

## Deployment Instructions

### Prerequisites
- AWS Account with valid credentials
- Terraform 1.5+ installed locally
- Git installed
- AWS CLI configured (optional, for manual testing)

### Step 1: Deploy Infrastructure

```bash
cd terraform
terraform init
terraform apply -auto-approve
```

**What happens:**
1. All AWS resources created (EC2, VPC, Lambda, DynamoDB, CloudWatch)
2. SSH key pair auto-generated and saved to Terraform outputs
3. EC2 instance launches with CloudWatch agent
4. Cowrie honeypot container starts automatically
5. Expected time: 2-3 minutes

### Step 2: Retrieve Honeypot IP Address

```bash
cd terraform
terraform output honeypot_public_ip
```

Output example: `203.0.113.45`

### Step 3: Test the Honeypot (Optional)

```bash
# Direct SSH to honeypot (accepts any password)
ssh root@203.0.113.45

# Default behavior:
# - Accepts login with any username/password
# - Provides fake shell interface
# - Any commands logged automatically
# - Exit with Ctrl+D
```

### Step 4: Monitor Logs in CloudWatch

```bash
# View logs in AWS Console:
# CloudWatch > Log Groups > /honeypot/cloud-intrusion-platform/cowrie
# Select log stream: cowrie-events
# View events in real-time
```

### Step 5: Query Intrusion Data in DynamoDB  

```bash
# In AWS Console:
# DynamoDB > Tables > intrusion-events
# Use Query or Scan to inspect captured attacks
```

---

## Key Design Decisions

### 1. **--network host Mode**
- Cowrie container directly binds to host ports 22 and 23
- No port mapping overhead
- Attackers see legitimate SSH/Telnet interface
- Ensures realistic attack capture

### 2. **CloudWatch Agent Log Shipping**
- Real-time log monitoring (10 second flush)
- Cowrie JSON events parsed as structured logs
- Lambda subscription filter triggers on log events
- DynamoDB stores enriched records for analytics

### 3. **On-Demand DynamoDB Pricing**
- Pay only for read/write capacity used
- No reserved capacity needed
- Scale automatically with attack volume
- Perfect for unpredictable honeypot traffic

### 4. **Systemd Container Monitoring**
- Cowrie container auto-restarts if it crashes
- Systemd service verifies container health every 30 seconds
- EC2 reboot automatically restarts honeypot

---

## Attack Flow Diagram

```
[Attacker] 
    |
    | ssh root@203.0.113.45
    v
[EC2 Security Group] (Port 22 allowed)
    |
    v
[Cowrie Honeypot Container] (--network host, listening on 22:2223)
    |
    | Logs authentication + commands
    v
[/var/log/cowrie/cowrie.json] & [cowrie.log]
    |
    v
[CloudWatch Agent] (monitors files, ships to CloudWatch every 10s)
    |
    v
[CloudWatch Log Group] (/honeypot/cloud-intrusion-platform/cowrie)
    |
    | Lambda subscription filter triggers
    v
[Lambda Function] (log-processor)
    |
    | Parses Cowrie JSON
    | Extracts attacker_ip, username, password, commands
    |
    v
[DynamoDB Table] (intrusion-events)
    |
    v
[CloudWatch Dashboard] (visualizes top attackers, commands, attempts)
```

---

## File Structure

```
.
├── terraform/
│   ├── main.tf              # All AWS resources
│   ├── variables.tf         # 4 variables with safe defaults
│   ├── versions.tf          # Provider versions
│   └── outputs.tf           # 11 outputs (honeypot_public_ip, etc)
│
├── lambda/
│   ├── log_processor.py     # Cowrie log processor (500 lines)
│   └── requirements.txt     # Dependencies
│
├── scripts/
│   └── install.sh           # EC2 user_data script (400 lines)
│                             # Installs Docker, starts Cowrie
│
├── dashboards/
│   └── cloudwatch_dashboard.json  # 12-widget visualization
│
└── .github/
    └── workflows/
        ├── deploy.yml       # CI/CD: validate → plan → apply
        └── destroy.yml      # Manual destroy with confirmation
```

---

## Troubleshooting

### Honeypot Not Responding
1. Check EC2 instance is running:
   ```bash
   aws ec2 describe-instances --region us-east-1 --query 'Reservations[0].Instances[0].State'
   ```

2. Check Cowrie container:
   ```bash
   # SSH to EC2 using Session Manager or key pair
   docker ps  # Should show cowrie-honeypot running
   docker logs cowrie-honeypot  # Last 20 lines
   ```

3. Check Security Group allows port 22:
   ```bash
   aws ec2 describe-security-groups --region us-east-1
   # Verify inbound rule: Protocol=TCP, Port Range=22-22, CIDR=0.0.0.0/0
   ```

### CloudWatch Logs Not Appearing
1. Check CloudWatch Agent is running:
   ```bash
   # On EC2:
   systemctl status amazon-cloudwatch-agent
   ```

2. Check log files exist:
   ```bash
   ls -lah /var/log/cowrie/
   ```

3. Manually trigger log entry:
   ```bash
   docker exec cowrie-honeypot touch /cowrie/var/log/cowrie/cowrie.log
   ```

### Lambda Not Executing
1. Check Lambda execution role has DynamoDB permissions
2. Check CloudWatch Log Group has subscription filter
3. Monitor Lambda CloudWatch logs:
   ```bash
   # CloudWatch > Log Groups > /aws/lambda/log-processor
   ```

---

## Cost Estimation (Free Tier)

| Service | Monthly Cost (Free Tier) |
|---------|--------------------------|
| EC2 t2.micro | $0 (750 hrs/month) |
| CloudWatch Logs | $0 (5GB ingestion free) |
| Lambda | $0 (1M invocations free) |
| DynamoDB | $0 (25GB on-demand storage) |
| **TOTAL** | **$0** |

---

## Security Notes

- **NEVER** run this on a production account - it deliberately exposes weak credentials
- All inbound traffic is logged and stored in DynamoDB indefinitely (or until TTL expires)
- The honeypot is intentionally vulnerable - it's designed to be compromised
- The isolated VPC prevents honeypot from attacking other resources
- EC2 instance has no internet access to external systems (only outbound CloudWatch API) 

---

## Cleanup

To destroy all AWS resources and stop charges:

```bash
cd terraform
terraform destroy -auto-approve
```

This removes:
- EC2 instance and all data
- VPC, subnets, and routing
- DynamoDB table (unless point-in-time recovery retention enabled)
- Lambda function and logs
- CloudWatch alarms and dashboards
- IAM roles and policies

---

## Next Steps

1. **Deploy now**: `terraform apply -auto-approve`
2. **Test honeypot**: `ssh root@<public_ip>` (any password)
3. **Monitor in real-time**: CloudWatch Dashboard
4. **Analyze attacks**: DynamoDB intrusion-events table
5. **Customize**: Modify variables.tf to change region, retention days, etc.

---

**Last Updated**: March 5, 2026  
**Status**: Production Ready ✓
