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
#  1. Completely Disable Native SSH to Free Port 22 for Cowrie
# ============================================================================
log "CRITICAL: Disabling native SSH daemon completely..."
systemctl stop sshd 2>/dev/null || true
systemctl stop ssh 2>/dev/null || true
systemctl disable sshd 2>/dev/null || true
systemctl disable ssh 2>/dev/null || true
systemctl mask sshd 2>/dev/null || true
systemctl mask ssh 2>/dev/null || true

# Kill any remaining SSH processes
pkill -f sshd || true
sleep 2

log "Native SSH fully disabled - Port 22 is now free for Cowrie honeypot"
log "Verifying sshd is not listening..."
if netstat -tuln 2>/dev/null | grep -q ":22 " || ss -tuln 2>/dev/null | grep -q ":22 "; then
  log "WARNING: Something still listening on port 22, will be replaced by Cowrie"
fi

# ============================================================================
#  2. Update System & Install Dependencies
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

# Wait for Docker to be ready - with detailed logging
log "Waiting for Docker daemon to be ready..."
for i in {1..60}; do
  if docker info >/dev/null 2>&1; then
    log "Docker is ready (attempt $i/60)"
    docker version 2>&1 | head -2 | tee -a /var/log/honeypot-install.log
    break
  fi
  if [ $i -eq 60 ]; then
    log "ERROR: Docker failed to start after 60 seconds"
    systemctl status docker 2>&1 | tee -a /var/log/honeypot-install.log
    journalctl -u docker -n 30 2>&1 | tee -a /var/log/honeypot-install.log
    exit 1
  fi
  sleep 1
done

# ============================================================================
#  3. Create Log Directories
# ============================================================================
log "Creating Cowrie log directories on host..."
mkdir -p /cowrie/log
chmod 755 /cowrie/log
log "Log directory created: /cowrie/log"

# ============================================================================
#  4. Start Cowrie Honeypot Container
# ============================================================================
# ============================================================================
#  4. Start Cowrie Honeypot Container
# ============================================================================
log "Pulling Cowrie Docker image (this may take 1-2 minutes)..."
for attempt in {1..3}; do
  if docker pull cowrie/cowrie:latest 2>&1 | tee -a /var/log/honeypot-install.log; then
    log "Cowrie image pulled successfully"
    break
  else
    log "Image pull attempt $attempt failed, retrying..."
    sleep 10
  fi
done

log "Starting Cowrie honeypot container..."
log "Port mapping: Host 22 -> Container 2222 (SSH), Host 23 -> Container 2223 (Telnet)"
log "Log volume: Host /cowrie/log -> Container /cowrie/var/log/cowrie"

# Remove old container if it exists
docker rm -f cowrie-honeypot 2>/dev/null || true

docker run -d \
  --name cowrie-honeypot \
  --restart unless-stopped \
  -p 22:2222 \
  -p 23:2223 \
  -v /cowrie/log:/cowrie/var/log/cowrie \
  cowrie/cowrie:latest 2>&1 | tee -a /var/log/honeypot-install.log

if [ $? -ne 0 ]; then
  log "ERROR: Failed to start Cowrie container"
  exit 1
fi

log "Waiting for Cowrie container to initialize..."
for i in {1..60}; do
  if docker ps --filter "name=cowrie-honeypot" --format "{{.Names}}" 2>/dev/null | grep -q cowrie-honeypot; then
    log "Cowrie container is running (attempt $i/60)"
    break
  fi
  [ $i -lt 60 ] && sleep 1
done

if ! docker ps --filter "name=cowrie-honeypot" --format "{{.Names}}" 2>/dev/null | grep -q cowrie-honeypot; then
  log "ERROR: Cowrie container failed to start after 60 seconds"
  log "Docker ps output:"
  docker ps -a 2>&1 | tee -a /var/log/honeypot-install.log
  log "Container logs:"
  docker logs cowrie-honeypot 2>&1 | tail -50 | tee -a /var/log/honeypot-install.log
  exit 1
fi

# ============================================================================
#  5. Verify Honeypot Ports
# ============================================================================
# ============================================================================
#  5. Verify Honeypot Ports
# ============================================================================
log "Waiting for honeypot to bind listening ports..."
sleep 5

log "Checking if ports 22 (SSH) and 23 (Telnet) are listening..."
for attempt in {1..10}; do
  if netstat -tuln 2>/dev/null | grep -qE "LISTEN.*:(22|23)" || ss -tuln 2>/dev/null | grep -qE "LISTEN.*:(22|23)"; then
    log "SUCCESS: Honeypot is listening on port 22 (SSH) and/or 23 (Telnet)"
    netstat -tuln 2>/dev/null | grep -E "LISTEN.*:(22|23)" || ss -tuln 2>/dev/null | grep -E "LISTEN.*:(22|23)"
    break
  fi
  if [ $attempt -lt 10 ]; then
    log "Waiting for ports to be ready... (attempt $attempt/10)"
    sleep 2
  else
    log "WARNING: Ports may still be initializing"
  fi
done

log "Cowrie container logs (diagnostic):"
docker logs cowrie-honeypot 2>&1 | tail -30 | tee -a /var/log/honeypot-install.log

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
            "file_path": "/cowrie/log/cowrie.json",
            "log_group_name": "CWLOG_GROUP",
            "log_stream_name": "CWLOG_STREAM",
            "timezone": "UTC",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S",
            "multi_line_start_pattern": "{",
            "retention_in_days": 30
          },
          {
            "file_path": "/cowrie/log/cowrie.log",
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
ls -lah /cowrie/log/ 2>&1 | tee -a /var/log/honeypot-install.log

if [ -f /cowrie/log/cowrie.json ]; then
  log "OK: JSON event log exists"
  wc -l /cowrie/log/cowrie.json | tee -a /var/log/honeypot-install.log
else
  log "INFO: JSON log will be created on first connection"
fi

if [ -f /cowrie/log/cowrie.log ]; then
  log "OK: Text log exists - last entries:"
  tail -3 /cowrie/log/cowrie.log | tee -a /var/log/honeypot-install.log
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
ExecStart=/bin/bash -c 'while true; do if ! docker ps | grep -q cowrie-honeypot; then docker run -d --name cowrie-honeypot --restart unless-stopped -p 22:2222 -p 23:2223 -v /cowrie/log:/cowrie/var/log/cowrie cowrie/cowrie:latest; fi; sleep 30; done'
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
log "  Native SSH Service: DISABLED (sshd masked)"
log "  Cowrie Container: RUNNING"
log "  Attack Ports: 22 (SSH), 23 (Telnet)"
log "  Port Mapping: Cowrie internal 2222->host 22, 2223->host 23"
log "  Log Location: /cowrie/log/cowrie.json, /cowrie/log/cowrie.log"
log "  CloudWatch Log Group: $LOG_GROUP_NAME"
log "  CloudWatch Stream: $LOG_STREAM_NAME"
log ""
log "Attack Interaction Flow:"
log "  1. Attacker: ssh root@<honeypot_ip>"
log "  2. Cowrie honeypot accepts connection (default password: test)"
log "  3. Attacker enters fake commands"
log "  4. Cowrie logs all interactions to /cowrie/log/"
log "  5. CloudWatch Agent ships logs to CloudWatch Logs"
log "  6. Lambda processes logs and stores in DynamoDB"
log "  7. Dashboard displays intrusion analytics"
log ""
log "For manual testing:"
log "  ssh root@<public_ip>  (any password accepted)"
log ""
log "Installation Log: /var/log/honeypot-install.log"
log "=========================================================================="

