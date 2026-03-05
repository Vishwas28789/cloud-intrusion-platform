#!/usr/bin/env bash
################################################################################
#  Cloud Intrusion Behavior Analytics Platform
#  EC2 Honeypot Installation Script - runs as user_data on EC2 startup
################################################################################

set -euo pipefail

# Template variables (substituted by Terraform)
LOG_GROUP_NAME="${log_group_name}"
LOG_STREAM_NAME="${log_stream_name}"
AWS_REGION="${aws_region}"

# Logging function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/honeypot-install.log
}

log "=== Starting Honeypot Installation ==="
log "Log Group: $LOG_GROUP_NAME"
log "Log Stream: $LOG_STREAM_NAME"
log "Region: $AWS_REGION"

# ============================================================================
#  1. Update System & Install Dependencies
# ============================================================================
log "Installing Docker and CloudWatch Agent..."
dnf update -y -q 2>/dev/null || true
dnf install -y -q docker amazon-cloudwatch-agent curl wget jq net-tools 2>/dev/null

# ============================================================================
#  2. Start Docker Daemon
# ============================================================================
log "Starting Docker daemon..."
systemctl enable docker >/dev/null 2>&1
systemctl start docker >/dev/null 2>&1

# Wait for Docker to be ready
for i in {1..30}; do
  if docker info >/dev/null 2>&1; then
    log "Docker is ready"
    break
  fi
  if [ $i -eq 30 ]; then
    log "ERROR: Docker failed to start"
    exit 1
  fi
  sleep 1
done

# ============================================================================
#  3. Create Log Directories
# ============================================================================
log "Creating log directories..."
mkdir -p /var/log/cowrie
chmod 755 /var/log/cowrie

# ============================================================================
#  4. Start Cowrie Honeypot Container
# ============================================================================
log "Pulling Cowrie Docker image..."
docker pull cowrie/cowrie:latest 2>&1 | tee -a /var/log/honeypot-install.log

log "Starting Cowrie honeypot container..."
log "Using --network host to bind directly to ports 22 (SSH) and 23 (Telnet)"
docker run -d \
  --name cowrie-honeypot \
  --restart unless-stopped \
  --network host \
  -v /var/log/cowrie:/cowrie/var/log/cowrie \
  cowrie/cowrie:latest

log "Waiting for Cowrie container to initialize..."
for i in {1..60}; do
  if docker ps --filter "name=cowrie-honeypot" --format "{{.Names}}" 2>/dev/null | grep -q cowrie-honeypot; then
    log "Cowrie container is running"
    break
  fi
  [ $i -lt 60 ] && sleep 1
done

if ! docker ps --filter "name=cowrie-honeypot" --format "{{.Names}}" 2>/dev/null | grep -q cowrie-honeypot; then
  log "ERROR: Cowrie container failed to start"
  docker logs cowrie-honeypot 2>&1 | tee -a /var/log/honeypot-install.log || true
  exit 1
fi

# ============================================================================
#  5. Verify Honeypot Ports
# ============================================================================
log "Waiting for honeypot to bind listening ports..."
sleep 5

log "Checking if ports 22 (SSH) and 23 (Telnet) are listening..."
if netstat -tuln 2>/dev/null | grep -qE "LISTEN.*:(22|23)" || ss -tuln 2>/dev/null | grep -qE "LISTEN.*:(22|23)"; then
  log "SUCCESS: Honeypot is listening on attack ports"
else
  log "INFO: Cowrie container running but ports initializing"
fi

log "Cowrie container logs (diagnostic):"
docker logs cowrie-honeypot 2>&1 | tail -20 | tee -a /var/log/honeypot-install.log

# ============================================================================
#  6. Configure CloudWatch Agent
# ============================================================================
log "Configuring CloudWatch Agent..."
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "agent": {
    "metrics_collection_interval": 60,
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log",
    "debug": false
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/cowrie/cowrie.json",
            "log_group_name": "CWLOG_GROUP",
            "log_stream_name": "CWLOG_STREAM",
            "timezone": "UTC",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S",
            "multi_line_start_pattern": "{",
            "retention_in_days": 30
          },
          {
            "file_path": "/var/log/cowrie/cowrie.log",
            "log_group_name": "CWLOG_GROUP",
            "log_stream_name": "CWLOG_STREAM",
            "timezone": "UTC",
            "retention_in_days": 30
          }
        ]
      }
    },
    "force_flush_interval": 10
  }
}
CWCONFIG

log "Substituting CloudWatch configuration placeholders..."
sed -i "s|CWLOG_GROUP|$LOG_GROUP_NAME|g" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sed -i "s|CWLOG_STREAM|$LOG_STREAM_NAME|g" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

log "CloudWatch Agent configuration saved:"
cat /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json | tee -a /var/log/honeypot-install.log

# ============================================================================
#  7. Start CloudWatch Agent
# ============================================================================
log "Starting CloudWatch Agent..."
systemctl enable amazon-cloudwatch-agent >/dev/null 2>&1 || true

sleep 2

log "Applying CloudWatch Agent configuration to monitor log files..."
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s 2>&1 | tee -a /var/log/honeypot-install.log

sleep 2

log "CloudWatch Agent status:"
systemctl status amazon-cloudwatch-agent --no-pager 2>&1 | tee -a /var/log/honeypot-install.log || log "CloudWatch Agent may still be initializing"

# ============================================================================
#  8. Verify Complete Attack Pipeline
# ============================================================================
log "Verifying complete honeypot pipeline..."

log "[STEP 1] Verify Cowrie container running:"
if docker ps --filter "name=cowrie-honeypot" --format "{{.ID}}" 2>/dev/null | grep -q .; then
  log "OK: Cowrie container running"
else
  log "ERROR: Cowrie container not running"
fi

log "[STEP 2] Check honeypot log files:"
ls -lah /var/log/cowrie/ 2>&1 | tee -a /var/log/honeypot-install.log

if [ -f /var/log/cowrie/cowrie.json ]; then
  log "OK: JSON event log exists"
  wc -l /var/log/cowrie/cowrie.json | tee -a /var/log/honeypot-install.log
else
  log "INFO: JSON log will be created on first connection"
fi

if [ -f /var/log/cowrie/cowrie.log ]; then
  log "OK: Text log exists - last entries:"
  tail -3 /var/log/cowrie/cowrie.log | tee -a /var/log/honeypot-install.log
else
  log "INFO: Text log will be created on first connection"
fi

# ============================================================================
#  9. Create Systemd Service for Continuous Monitoring
# ============================================================================
log "Installing systemd service for Cowrie monitoring and restart..."
cat > /etc/systemd/system/cowrie-monitor.service << 'SYSTEMD'
[Unit]
Description=Cowrie Honeypot Container Lifecycle Manager
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStart=/bin/bash -c 'while true; do if ! docker ps | grep -q cowrie-honeypot; then docker run -d --name cowrie-honeypot --restart unless-stopped --network host -v /var/log/cowrie:/cowrie/var/log/cowrie cowrie/cowrie:latest; fi; sleep 30; done'
User=root

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload >/dev/null 2>&1
systemctl enable cowrie-monitor.service >/dev/null 2>&1
log "Systemd service installed and enabled"

# ============================================================================
#  Installation Success Summary
# ============================================================================
log ""
log "=========================================================================="
log "HONEYPOT INSTALLATION COMPLETE - READY FOR ATTACK"
log "=========================================================================="
log ""
log "Honeypot Configuration:"
log "  Attack Ports: 22 (SSH), 23 (Telnet)"
log "  Honeypot Type: Cowrie (Docker container)"
log "  Log Location: /var/log/cowrie/cowrie.json, cowrie.log"
log "  CloudWatch Log Group: $LOG_GROUP_NAME"
log "  CloudWatch Stream: $LOG_STREAM_NAME"
log ""
log "Attack Interaction Flow:"
log "  1. Attacker: ssh root@&lt;honeypot_ip&gt;"
log "  2. Cowrie logs authentication attempt"
log "  3. Attacker enters fake commands"
log "  4. Cowrie logs all interactions to /var/log/cowrie/"
log "  5. CloudWatch Agent ships logs to CloudWatch Logs"
log "  6. Lambda processes logs and stores in DynamoDB"
log "  7. Dashboard displays intrusion analytics"
log ""
log "For manual testing:"
log "  ssh root@&lt;public_ip&gt;  (default password: test)"
log ""
log "Installation Log: /var/log/honeypot-install.log"
log "=========================================================================="

