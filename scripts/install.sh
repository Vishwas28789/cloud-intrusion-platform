#!/usr/bin/env bash
# Bulletproof Cowrie honeypot installation script

LOG_FILE="/var/log/honeypot-install.log"
log() { 
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg" | tee -a "$LOG_FILE"
}

fail() {
  log "ERROR: $*"
  log "Installation FAILED at $(date)"
  exit 1
}

# Variables from Terraform
LOG_GROUP="${log_group_name}"
LOG_STREAM="${log_stream_name}"
REGION="${aws_region}"

log "========================================"
log "HONEYPOT INSTALL: Starting"
log "Log Group: $LOG_GROUP"
log "Log Stream: $LOG_STREAM"
log "Region: $REGION"
log "========================================"

# [1/8] DISABLE NATIVE SSH DAEMON
log "[STEP 1/8] Disabling native SSH daemon completely..."
systemctl stop sshd 2>/dev/null || true
systemctl disable sshd 2>/dev/null || true
systemctl mask sshd 2>/dev/null || true
killall sshd 2>/dev/null || true
sleep 2
log "✓ SSH daemon disabled"

# [2/8] INSTALL DOCKER & CLOUDWATCH
log "[STEP 2/8] Installing Docker and CloudWatch Agent..."
if command -v dnf &> /dev/null; then
  dnf update -y >> "$LOG_FILE" 2>&1 || fail "dnf update failed"
  dnf install -y docker amazon-cloudwatch-agent >> "$LOG_FILE" 2>&1 || fail "dnf install failed"
else
  yum update -y >> "$LOG_FILE" 2>&1 || fail "yum update failed"
  yum install -y docker amazon-cloudwatch-agent >> "$LOG_FILE" 2>&1 || fail "yum install failed"
fi
log "✓ Packages installed"

# [3/8] START DOCKER DAEMON
log "[STEP 3/8] Starting Docker daemon..."
systemctl enable docker >> "$LOG_FILE" 2>&1 || fail "Failed to enable Docker"
systemctl start docker >> "$LOG_FILE" 2>&1 || fail "Failed to start Docker"

# Wait for Docker to be ready (up to 60 seconds)
local docker_ready=0
for i in {1..60}; do
  if docker ps > /dev/null 2>&1; then
    docker_ready=1
    break
  fi
  log "  Waiting for Docker... ($i/60)"
  sleep 1
done
[ "$docker_ready" -eq 1 ] || fail "Docker failed to start after 60 seconds"
log "✓ Docker daemon is ready"

# [4/8] CREATE LOG DIRECTORY
log "[STEP 4/8] Creating Cowrie log directory..."
mkdir -p /cowrie/log >> "$LOG_FILE" 2>&1 || fail "Failed to create /cowrie/log"
chmod 777 /cowrie/log >> "$LOG_FILE" 2>&1 || fail "Failed to chmod /cowrie/log"
log "✓ Log directory created"

# [5/8] PULL COWRIE IMAGE
log "[STEP 5/8] Pulling Cowrie container (this may take 1-2 minutes)..."
if ! timeout 600 docker pull cowrie/cowrie:latest >> "$LOG_FILE" 2>&1; then
  log "  First pull timed out, retrying..."
  if ! timeout 600 docker pull cowrie/cowrie:latest >> "$LOG_FILE" 2>&1; then
    fail "Docker image pull failed after 2 attempts"
  fi
fi
log "✓ Cowrie image pulled successfully"

# [6/8] START COWRIE CONTAINER  
log "[STEP 6/8] Starting Cowrie container on port 22..."
docker rm -f cowrie-honeypot 2>/dev/null || true
sleep 1

if ! docker run -d \
  --name cowrie-honeypot \
  --restart always \
  -p 22:2222 \
  -p 23:2223 \
  -v /cowrie/log:/cowrie/var/log/cowrie \
  cowrie/cowrie:latest >> "$LOG_FILE" 2>&1; then
  fail "Failed to start Cowrie container"
fi

sleep 3

# Verify container is running
if ! docker ps 2>/dev/null | grep -q cowrie-honeypot; then
  fail "Cowrie container is not running after start"
fi
log "✓ Cowrie container started and running"

# [7/8] CONFIGURE CLOUDWATCH AGENT
log "[STEP 7/8] Configuring CloudWatch Agent..."
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc || fail "Failed to create CloudWatch config dir"

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "agent": { "metrics_collection_interval": 60 },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/cowrie/log/cowrie.json",
            "log_group_name": "__LOG_GROUP__",
            "log_stream_name": "__LOG_STREAM__",
            "timezone": "UTC"
          },
          {
            "file_path": "/cowrie/log/cowrie.log",
            "log_group_name": "__LOG_GROUP__",
            "log_stream_name": "__LOG_STREAM__",
            "timezone": "UTC"
          }
        ]
      }
    },
    "force_flush_interval": 10
  }
}
CWCONFIG

sed -i "s|__LOG_GROUP__|$LOG_GROUP|g" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sed -i "s|__LOG_STREAM__|$LOG_STREAM|g" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

systemctl enable amazon-cloudwatch-agent >> "$LOG_FILE" 2>&1 || fail "Failed to enable CloudWatch Agent"
systemctl start amazon-cloudwatch-agent >> "$LOG_FILE" 2>&1 || fail "Failed to start CloudWatch Agent"
log "✓ CloudWatch Agent configured and started"

# [8/8] VERIFY EVERYTHING
log "[STEP 8/8] Final verification..."
sleep 2

# Check if port 22 is listening (Cowrie)
if ss -tulnp 2>/dev/null | grep -q ":2222"; then
  log "✓ Cowrie SSH is listening on 2222 (mapped to 22)"
elif netstat -tulnp 2>/dev/null | grep -q ":2222"; then
  log "✓ Cowrie SSH is listening on 2222 (mapped to 22)"
else
  log "⚠ Warning: Cannot verify port 2222 listening (tools may be missing)"
fi

# Show final status
log ""
log "========================================"
log "✓ HONEYPOT INSTALLATION COMPLETE"
log "========================================"
log "Instance: $HOSTNAME"
log "Honeypot: Cowrie (SSH on 22, Telnet on 23)"
log "Logs: /cowrie/log/"
log "CloudWatch: $LOG_GROUP"
log "========================================"
log "Installation completed at $(date)"
log "========================================"

