#!/usr/bin/env bash
set -e
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a /var/log/honeypot-install.log; }
LOG_GROUP_NAME="${log_group_name}"
LOG_STREAM_NAME="${log_stream_name}"
AWS_REGION="${aws_region}"
log "======== HONEYPOT INSTALL START ========"
log "Region: $AWS_REGION | Group: $LOG_GROUP_NAME"

# ============================================================================
# DISABLE SSH & INSTALL DOCKER
# ============================================================================
log "[1/7] Disabling SSH..."
systemctl stop sshd || true
systemctl disable sshd || true
systemctl mask sshd || true
pkill -9 sshd || true
sleep 2

log "[2/7] Installing Docker..."
yum update -y > /dev/null 2>&1 || dnf update -y > /dev/null 2>&1
yum install -y docker amazon-cloudwatch-agent > /dev/null 2>&1 || dnf install -y docker amazon-cloudwatch-agent > /dev/null 2>&1
systemctl enable docker
systemctl start docker

for i in {1..60}; do
  docker ps > /dev/null 2>&1 && { log "Docker ready"; break; }
  [ $i -eq 60 ] && { log "ERROR: Docker failed"; exit 1; }
  sleep 1
done

log "[3/7] Creating log dir..."
mkdir -p /cowrie/log
chmod 755 /cowrie/log

log "[4/7] Pulling Cowrie..."
timeout 300 docker pull cowrie/cowrie:latest || timeout 300 docker pull cowrie/cowrie:latest || log "Pull timeout - retrying"

log "[5/7] Starting Cowrie..."
docker rm -f cowrie-honeypot 2>/dev/null || true
sleep 2
docker run -d --name cowrie-honeypot --restart always -p 22:2222 -p 23:2223 -v /cowrie/log:/cowrie/var/log/cowrie cowrie/cowrie:latest
sleep 3

log "[6/7] Configuring CloudWatch..."
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "agent": { "metrics_collection_interval": 60 },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/cowrie/log/cowrie.json",
            "log_group_name": "CWLOG_GROUP",
            "log_stream_name": "CWLOG_STREAM",
            "timezone": "UTC"
          },
          {
            "file_path": "/cowrie/log/cowrie.log",
            "log_group_name": "CWLOG_GROUP",
            "log_stream_name": "CWLOG_STREAM",
            "timezone": "UTC"
          }
        ]
      }
    },
    "force_flush_interval": 10
  }
}
CWCONFIG

sed -i "s|CWLOG_GROUP|$LOG_GROUP_NAME|g" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
sed -i "s|CWLOG_STREAM|$LOG_STREAM_NAME|g" /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

log "[7/7] DONE!"
log ""
log "=========================================="
log "HONEYPOT READY FOR ATTACKERS"
log "=========================================="
log "SSH: Port 22 (Cowrie honeypot)"
log "Telnet: Port 23"
log "Logs: /cowrie/log/"
log "CloudWatch: $LOG_GROUP_NAME"
log ""
log "Test: ssh root@<public_ip>"
log "Any password works!"
log "=========================================="

