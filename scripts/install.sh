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
dnf install -y -q docker amazon-cloudwatch-agent curl wget jq 2>/dev/null

# ============================================================================
#  2. Start Docker
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
#  4. Start Cowrie Container
# ============================================================================
log "Pulling Cowrie image..."
docker pull cowrie/cowrie:latest

log "Starting Cowrie honeypot container..."
docker run -d \
  --name cowrie-honeypot \
  --restart unless-stopped \
  -p 22:2222 \
  -p 23:2223 \
  -v /var/log/cowrie:/cowrie/var/log/cowrie \
  cowrie/cowrie:latest

# Wait for container to stabilize
sleep 5

if docker ps --filter "name=cowrie-honeypot" --format '{{.Names}}' | grep -q cowrie-honeypot; then
  log "Cowrie container started successfully"
else
  log "ERROR: Cowrie container failed to start"
  docker logs cowrie-honeypot || true
  exit 1
fi

# ============================================================================
#  5. Verify Ports
# ============================================================================
log "Verifying port bindings..."
sleep 5
if docker port cowrie-honeypot 2222 >/dev/null 2>&1; then
  log "Port 22 -> 2222 binding verified"
else
  log "WARNING: Port mapping may not be ready yet"
fi

# ============================================================================
#  6. Configure CloudWatch Agent
# ============================================================================
log "Configuring CloudWatch Agent..."
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "agent": {
    "metrics_collection_interval": 60,
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/cowrie/cowrie.log",
            "log_group_name": "CWLOG_GROUP",
            "log_stream_name": "CWLOG_STREAM",
            "timezone": "UTC",
            "retention_in_days": 30
          },
          {
            "file_path": "/var/log/cowrie/cowrie.json",
            "log_group_name": "CWLOG_GROUP",
            "log_stream_name": "cowrie-json",
            "timezone": "UTC",
            "retention_in_days": 30
          }
        ]
      }
    },
    "force_flush_interval": 15
  }
}
CWCONFIG

# Substitute actual values
sed -i "s|CWLOG_GROUP|$LOG_GROUP_NAME|g" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sed -i "s|CWLOG_STREAM|$LOG_STREAM_NAME|g" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# ============================================================================
#  7. Start CloudWatch Agent
# ============================================================================
log "Starting CloudWatch Agent..."
systemctl enable amazon-cloudwatch-agent >/dev/null 2>&1

# Wait for log files to be created by Cowrie
log "Waiting for Cowrie to generate log files..."
for i in {1..30}; do
  if [ -f /var/log/cowrie/cowrie.log ] || [ -f /var/log/cowrie/cowrie.json ]; then
    log "Log files detected"
    break
  fi
  if [ $i -eq 30 ]; then
    log "WARNING: Log files not created after 30 seconds, continuing anyway"
  fi
  sleep 1
done

# Fetch and start CloudWatch Agent config
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s 2>&1 | tee -a /var/log/honeypot-install.log || log "CloudWatch Agent start returned non-zero (may be expected)"

# ============================================================================
#  8. Verify Pipeline
# ============================================================================
log "Verifying honeypot pipeline..."

if docker ps --filter "name=cowrie-honeypot" --format '{{.Names}}' | grep -q cowrie-honeypot; then
  log "OK: Cowrie container running"
else
  log "ERROR: Cowrie container not running"
fi

if [ -f /var/log/cowrie/cowrie.log ]; then
  log "OK: Cowrie logfile exists"
  tail -5 /var/log/cowrie/cowrie.log | tee -a /var/log/honeypot-install.log
else
  log "WARNING: Cowrie logfile not yet created"
fi

# ============================================================================
#  9. Create Systemd Service for Monitoring
# ============================================================================
log "Creating systemd service..."
cat > /etc/systemd/system/cowrie-monitor.service << 'SYSTEMD'
[Unit]
Description=Cowrie Honeypot Container Monitor
After=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/docker logs -f cowrie-honeypot
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload >/dev/null 2>&1
systemctl enable cowrie-monitor.service >/dev/null 2>&1

log "=== Honeypot Installation Complete ==="
log "Cowrie SSH honeypot: listening on port 22 (container:2222)"
log "Cowrie Telnet honeypot: listening on port 23 (container:2223)"
log "Log location: /var/log/cowrie/"
log "CloudWatch Group: $LOG_GROUP_NAME"
log "CloudWatch Stream: $LOG_STREAM_NAME"
log "=== Ready for connections ==="

