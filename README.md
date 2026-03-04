# Cloud Intrusion Behavior Analytics Platform

A budget-friendly AWS honeypot system that lures attackers, captures their behavior in real time, and stores every credential attempt, session, and command for analysis.

## Architecture

```
Internet
  │
  ▼
EC2 t2.micro (Cowrie SSH/Telnet Honeypot)   ← attackers connect here
  │                logs via CloudWatch Agent
  ▼
CloudWatch Log Group  (/honeypot/cloud-intrusion-platform/cowrie)
  │                subscription filter
  ▼
Lambda  (log_processor.py)   ← parses + enriches events
  │
  ▼
DynamoDB  (intrusion-events)   ← queryable intrusion database
  │
  ▼
CloudWatch Dashboard   ← live visualisation
```

### Component summary

| Component | Service | Free-tier |
|-----------|---------|-----------|
| Honeypot server | EC2 t2.micro | ✅ 750 hrs/mo |
| Persistent public IP | Elastic IP | ✅ free while attached |
| Log ingestion | CloudWatch Logs | ✅ 5 GB/mo |
| Event processing | Lambda | ✅ 1 M reqs/mo |
| Intrusion storage | DynamoDB on-demand | ✅ 25 GB + 200 M reqs/mo |
| Monitoring | CloudWatch Dashboard | 3 dashboards free |

---

## Repository Structure

```
cloud-intrusion-platform/
├── .github/
│   └── workflows/
│       ├── deploy.yml      # Terraform plan + apply on push to main
│       └── destroy.yml     # Manual destroy with confirmation
├── dashboards/
│   └── cloudwatch_dashboard.json   # Dashboard template (used by Terraform)
├── lambda/
│   └── log_processor.py    # CloudWatch → DynamoDB event processor
├── scripts/
│   └── install.sh          # EC2 user_data: installs Docker + Cowrie
├── terraform/
│   ├── versions.tf         # Provider & Terraform version pins
│   ├── variables.tf        # All input variables with descriptions
│   ├── main.tf             # All AWS resources
│   └── outputs.tf          # Useful output values
└── README.md
```

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| AWS Account | Free-tier eligible |
| AWS CLI ≥ 2.x | Configured with credentials |
| Terraform ≥ 1.5 | [Install](https://developer.hashicorp.com/terraform/install) |
| EC2 Key Pair | Create in AWS Console → EC2 → Key Pairs |
| GitHub repository | Fork or clone this repo |

---

## Deployment

### 1 – Clone the repository

```bash
git clone https://github.com/<your-org>/cloud-intrusion-platform.git
cd cloud-intrusion-platform
```

### 2 – Configure GitHub Secrets

Go to **GitHub → Settings → Secrets and Variables → Actions** and add:

| Secret name | Description |
|-------------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM user access key with appropriate permissions |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret |
| `EC2_KEY_PAIR_NAME` | Name of the key pair in your AWS account |
| `ADMIN_SSH_CIDR` | Your IP in CIDR notation e.g. `203.0.113.5/32` (optional, defaults to `0.0.0.0/0`) |

Minimum IAM permissions needed for deployment:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "iam:*",
        "lambda:*",
        "dynamodb:*",
        "logs:*",
        "cloudwatch:*"
      ],
      "Resource": "*"
    }
  ]
}
```

> For production, scope the `Resource` fields to specific ARNs.

### 3 – Create GitHub Environment (recommended)

Go to **GitHub → Settings → Environments → New environment** → name it `production`.

Add a **required reviewer** to force manual approval before any `apply` or `destroy` runs.

### 4 – Set up Terraform backend (optional but recommended)

Create an S3 bucket and DynamoDB lock table then add a backend block to `terraform/versions.tf`:

```hcl
backend "s3" {
  bucket         = "my-tfstate-bucket"
  key            = "cloud-intrusion-platform/terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "terraform-locks"
  encrypt        = true
}
```

### 5 – Deploy

Push to the `main` branch to trigger the deployment pipeline automatically:

```bash
git add .
git commit -m "feat: initial honeypot deployment"
git push origin main
```

The **Deploy** workflow will:
1. Validate and format-check Terraform code
2. Run `terraform plan` and save the plan
3. Run `terraform apply` using the saved plan (if changes exist)
4. Run smoke tests to verify all components are healthy

### 6 – Local deploy (alternative)

```bash
cd terraform

terraform init

terraform plan \
  -var="key_pair_name=my-keypair" \
  -var="aws_region=us-east-1" \
  -var="admin_ssh_cidr=$(curl -s https://checkip.amazonaws.com)/32"

terraform apply \
  -var="key_pair_name=my-keypair" \
  -var="aws_region=us-east-1"
```

---

## Viewing Results

### CloudWatch Dashboard

After deployment, the Terraform output `cloudwatch_dashboard_url` gives you a direct link.

Or navigate to: **AWS Console → CloudWatch → Dashboards → cloud-intrusion-platform-dashboard**

The dashboard shows:
- Live Cowrie event stream
- Top attacker IP addresses
- Most attempted usernames and passwords
- Commands executed by attackers who authenticated
- EC2 CPU and network metrics
- Lambda invocations and errors

### Query DynamoDB directly

```bash
# All intrusion events for a specific IP
aws dynamodb query \
  --table-name intrusion-events \
  --index-name AttackerIpIndex \
  --key-condition-expression "attacker_ip = :ip" \
  --expression-attribute-values '{":ip": {"S": "1.2.3.4"}}'

# All failed login events in the last 24 hours
aws dynamodb scan \
  --table-name intrusion-events \
  --filter-expression "event_type = :et" \
  --expression-attribute-values '{":et": {"S": "LOGIN_FAILED"}}' \
  --limit 100

# Count total events
aws dynamodb describe-table \
  --table-name intrusion-events \
  --query "Table.ItemCount"
```

### CloudWatch Logs Insights queries

Go to **CloudWatch → Logs Insights** and select the log group `/honeypot/cloud-intrusion-platform/cowrie`.

**Top attacking IPs (last 24 h):**
```
fields @message
| filter @message like /src_ip/
| parse @message '"src_ip": "*"' as src_ip
| stats count(*) as attempts by src_ip
| sort attempts desc
| limit 20
```

**Credential spray detection:**
```
fields @message
| filter @message like /login.failed/
| parse @message '"username": "*"' as username, '"password": "*"' as password
| stats count(*) as attempts by username, password
| sort attempts desc
| limit 50
```

**Post-auth commands:**
```
fields @message
| filter @message like /command.input/
| parse @message '"input": "*"' as command
| stats count(*) as times by command
| sort times desc
```

---

## Testing Attacks

> ⚠️ Only test against your own infrastructure. Never attack systems you do not own.

### Simulate a brute-force SSH attack

```bash
# Get your honeypot's public IP
HONEYPOT_IP=$(cd terraform && terraform output -raw honeypot_public_ip)

# Run a quick credential spray (requires hydra)
hydra -l root -P /usr/share/wordlists/rockyou.txt \
  -t 4 -f -V \
  ssh://$HONEYPOT_IP

# Or use nmap to trigger connection logging
nmap -p 22 -sV $HONEYPOT_IP
```

### Simulate a Telnet attack

```bash
HONEYPOT_IP=$(cd terraform && terraform output -raw honeypot_public_ip)
telnet $HONEYPOT_IP 23
```

### Manually invoke the Lambda processor

```bash
# Send a synthetic Cowrie login failure event
aws lambda invoke \
  --function-name cloud-intrusion-platform-log-processor \
  --payload "$(echo '{"awslogs":{"data":"'"$(echo '{"messageType":"DATA_MESSAGE","owner":"123456789","logGroup":"/honeypot/cloud-intrusion-platform/cowrie","logStream":"cowrie-events","subscriptionFilters":["test"],"logEvents":[{"id":"1","timestamp":1709000000000,"message":"{\"eventid\":\"cowrie.login.failed\",\"src_ip\":\"172.16.0.1\",\"username\":\"admin\",\"password\":\"password123\",\"session\":\"abc123\",\"timestamp\":\"2024-02-27T12:00:00.000000Z\"}"}]}' | gzip | base64 -w0)'"}}' | base64 -w0)" \
  --cli-binary-format raw-in-base64-out \
  /dev/stdout
```

### Verify data arrived in DynamoDB

```bash
aws dynamodb scan \
  --table-name intrusion-events \
  --max-items 5 \
  --query "Items[*].[event_id.S,event_type.S,attacker_ip.S,username.S,timestamp.S]" \
  --output table
```

---

## Configuration Reference

All variables are in `terraform/variables.tf`. Key options:

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `environment` | `production` | Tag label |
| `honeypot_instance_type` | `t2.micro` | EC2 type (keep t2.micro for Free Tier) |
| `key_pair_name` | *(required)* | EC2 key pair for emergency SSH |
| `admin_ssh_cidr` | `0.0.0.0/0` | CIDR for management SSH (port 2222) |
| `dynamodb_table_name` | `intrusion-events` | DynamoDB table |
| `log_retention_days` | `30` | CloudWatch log retention |
| `lambda_memory_mb` | `128` | Lambda memory |
| `lambda_timeout_seconds` | `30` | Lambda timeout |

---

## Destroying Infrastructure

> ⚠️ This will permanently delete all data including DynamoDB records and CloudWatch logs.

### Via GitHub Actions (recommended)

1. Go to **GitHub → Actions → Destroy – Terraform Destroy**
2. Click **Run workflow**
3. Type `DESTROY-HONEYPOT` in the confirmation field
4. Enter a reason
5. Click **Run workflow**
6. Approve the `production` environment gate if configured

### Via CLI

```bash
cd terraform

terraform destroy \
  -var="key_pair_name=my-keypair" \
  -var="aws_region=us-east-1" \
  -auto-approve
```

---

## Cost Estimate

Assuming 24/7 operation on Free Tier eligible account (first 12 months):

| Resource | Free Tier Allowance | Estimated Usage | Est. Cost |
|----------|--------------------|--------------:|-----------|
| EC2 t2.micro | 750 hrs/mo | 744 hrs/mo | **$0.00** |
| Elastic IP | Free while attached | 1 EIP | **$0.00** |
| CloudWatch Logs ingest | 5 GB/mo free | ~0.5 GB/mo | **$0.00** |
| CloudWatch Logs storage | 5 GB/mo free | ~0.5 GB/mo | **$0.00** |
| Lambda invocations | 1 M/mo free | ~50 K/mo | **$0.00** |
| Lambda compute | 400,000 GB-s/mo free | ~6,000 GB-s/mo | **$0.00** |
| DynamoDB storage | 25 GB free | ~0.1 GB/mo | **$0.00** |
| DynamoDB requests | 200 M/mo free | ~100 K/mo | **$0.00** |
| CloudWatch Dashboard | 3 free | 1 | **$0.00** |
| **Total (Free Tier)** | | | **~$0.00/mo** |

After Free Tier expiry: estimated **$8–12/month** depending on attack traffic volume.

---

## Security Notes

- The EC2 instance uses **IMDSv2** (token-required) to prevent SSRF attacks
- EC2 root volume is **encrypted**
- Cowrie runs in a **Docker container** with `no-new-privileges`
- Lambda and EC2 IAM roles follow **least privilege**
- DynamoDB enables **point-in-time recovery** and **server-side encryption**
- Real management access uses **AWS Systems Manager Session Manager** (no SSH port required)
- Consider placing the honeypot IP in public threat intel feeds (Shodan, AbuseIPDB) to attract more traffic

---

## Troubleshooting

### Cowrie container not starting

```bash
# SSH or use SSM to access the instance, then:
docker ps -a
docker logs cowrie-honeypot
systemctl status cowrie-honeypot
cat /var/log/honeypot-install.log
```

### No logs appearing in CloudWatch

```bash
# Check CloudWatch Agent status
systemctl status amazon-cloudwatch-agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status

# Check agent logs
tail -f /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
```

### Lambda not processing events

```bash
# Check Lambda logs
aws logs tail /aws/lambda/cloud-intrusion-platform-log-processor --follow

# Check subscription filter
aws logs describe-subscription-filters \
  --log-group-name /honeypot/cloud-intrusion-platform/cowrie
```

### DynamoDB write errors

```bash
# Verify table exists and is ACTIVE
aws dynamodb describe-table --table-name intrusion-events

# Check Lambda IAM role has DynamoDB permissions
aws iam get-role-policy \
  --role-name cloud-intrusion-platform-lambda-exec-role \
  --policy-name cloud-intrusion-platform-lambda-policy
```

---

## License

MIT – see [LICENSE](LICENSE) for details.
