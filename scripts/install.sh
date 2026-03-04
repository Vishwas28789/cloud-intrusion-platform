#!/usr/bin/env bash
# ============================================================
#  Cloud Intrusion Behavior Analytics Platform
#  Honeypot Installation Script – runs as EC2 user_data
# ============================================================
#  What this script does:
#    1. Installs system dependencies
#    2. Installs and configures the CloudWatch Agent
#    3. Installs Docker
#    4. Pulls and runs Cowrie SSH/Telnet honeypot in Docker
#    5. Configures systemd to keep everything running
# ============================================================

set -euo pipefail

LOG_TAG="honeypot-install"
LOG_GROUP_NAME="${log_group_name}"
LOG_STREAM_NAME="${log_stream_name}"
AWS_REGION="${aws_region}"

# ──────────────────────────
#  Helper logging function
# ──────────────────────────
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$LOG_TAG] $*" | tee -a /var/log/honeypot-install.log
}

log "============================================================"
log "Starting honeypot installation"
log "Log Group  : $LOG_GROUP_NAME"
log "Log Stream : $LOG_STREAM_NAME"
log "Region     : $AWS_REGION"
log "============================================================"

# ──────────────────────────
#  1. System update & deps
# ──────────────────────────
log "Updating system packages..."
dnf update -y
dnf install -y \
  python3 \
  python3-pip \
  jq \
  curl \
  wget \
  unzip \
  git \
  net-tools \
  htop

# ──────────────────────────
#  2. CloudWatch Agent
# ──────────────────────────
log "Installing CloudWatch Agent..."
dnf install -y amazon-cloudwatch-agent

# Write the CloudWatch Agent config
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWCONFIG
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "root",
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/home/cowrie/cowrie/var/log/cowrie/cowrie.json",
            "log_group_name": "$LOG_GROUP_NAME",
            "log_stream_name": "$LOG_STREAM_NAME",
            "timezone": "UTC",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S",
            "multi_line_start_pattern": "\\{",
            "encoding": "utf-8"
          },
          {
            "file_path": "/home/cowrie/cowrie/var/log/cowrie/cowrie.log",
            "log_group_name": "$LOG_GROUP_NAME",
            "log_stream_name": "cowrie-text-log",
            "timezone": "UTC"
          }
        ]
      }
    },
    "log_stream_name": "default-stream",
    "force_flush_interval": 15
  },
  "metrics": {
    "namespace": "HoneypotMetrics",
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60,
        "totalcpu": true
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "net": {
        "measurement": ["net_bytes_recv", "net_bytes_sent"],
        "metrics_collection_interval": 60,
        "resources": ["eth0"]
      }
    }
  }
}
CWCONFIG

log "Starting CloudWatch Agent..."
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s || log "WARN: CloudWatch Agent config may need log file to exist first – will auto-start on cowrie launch"

systemctl enable amazon-cloudwatch-agent

# ──────────────────────────
#  3. Docker Installation
# ──────────────────────────
log "Installing Docker..."
dnf install -y docker
systemctl enable docker
systemctl start docker

# Wait for Docker daemon to be ready
timeout 30 bash -c 'until docker info >/dev/null 2>&1; do sleep 1; done'
log "Docker is running: $(docker --version)"

# ──────────────────────────
#  4. Cowrie Honeypot Setup
# ──────────────────────────
log "Setting up Cowrie honeypot..."

# Create dedicated system user for Cowrie
useradd -r -m -d /home/cowrie -s /sbin/nologin cowrie 2>/dev/null || true

# Create log directories with correct ownership
mkdir -p /home/cowrie/cowrie/var/log/cowrie
mkdir -p /home/cowrie/cowrie/var/lib/cowrie
mkdir -p /home/cowrie/cowrie/etc

# ── Cowrie configuration ──────────────────────────────────────
cat > /home/cowrie/cowrie/etc/cowrie.cfg << 'COWRIECFG'
[honeypot]
hostname = srv01
log_path = var/log/cowrie
download_path = var/lib/cowrie/downloads
share_path = share/cowrie
state_path = var/lib/cowrie
etc_path = etc
contents_path = honeyfs
txtcmds_path = txtcmds
ttylog = true
ttylog_path = var/lib/cowrie
interactive_timeout = 180
authentication_timeout = 120
backend = shell
kernel_version = 5.10.0-21-amd64
kernel_build_string = #1 SMP Debian 5.10.162-1 (2023-01-21)
hardware_platform = x86_64
operating_system = GNU/Linux
timezone = UTC

[output_jsonlog]
enabled = true
logfile = var/log/cowrie/cowrie.json

[output_textlog]
enabled = true
logfile = var/log/cowrie/cowrie.log

[ssh]
enabled = true
listen_endpoints = tcp:2222:interface=0.0.0.0
version_string = SSH-2.0-OpenSSH_8.9p1

[telnet]
enabled = true
listen_endpoints = tcp:2223:interface=0.0.0.0
COWRIECFG

chown -R cowrie:cowrie /home/cowrie
log "Cowrie configuration written."

# ── Docker Compose file ───────────────────────────────────────
cat > /home/cowrie/docker-compose.yml << 'COMPOSE'
version: "3.8"

services:
  cowrie:
    image: cowrie/cowrie:latest
    container_name: cowrie-honeypot
    restart: unless-stopped
    ports:
      - "22:2222"
      - "23:2223"
    volumes:
      - /home/cowrie/cowrie/etc/cowrie.cfg:/cowrie/etc/cowrie.cfg:ro
      - /home/cowrie/cowrie/var/log/cowrie:/cowrie/var/log/cowrie
      - /home/cowrie/cowrie/var/lib/cowrie:/cowrie/var/lib/cowrie
    environment:
      - COWRIE_LISTEN_ENDPOINTS=tcp:2222:interface=0.0.0.0
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "3"
    security_opt:
      - no-new-privileges:true
COMPOSE

chown cowrie:cowrie /home/cowrie/docker-compose.yml

# ──────────────────────────
#  5. Pull & start Cowrie
# ──────────────────────────
log "Pulling Cowrie Docker image..."
docker pull cowrie/cowrie:latest

log "Starting Cowrie via docker-compose..."
cd /home/cowrie
docker compose up -d

# Verify container is running
sleep 5
if docker ps | grep -q cowrie-honeypot; then
  log "Cowrie honeypot container is running successfully."
else
  log "ERROR: Cowrie container failed to start. Check: docker logs cowrie-honeypot"
  docker logs cowrie-honeypot || true
fi

# ──────────────────────────────────────────────
#  6. iptables redirect: port 22 → 2222 (bait)
#     Real SSH management on port 2222 uses EC2
#     key pair; Cowrie listens on 22 via Docker
# ──────────────────────────────────────────────
log "Configuring iptables port redirect (22 -> container 2222 handled by Docker)..."
# Docker already binds container port 2222 to host port 22, so no extra iptables needed.
# Real management access via AWS Systems Manager Session Manager (no SSH port needed).

# ──────────────────────────────────────────────
#  7. Systemd service to restart on host reboot
# ──────────────────────────────────────────────
log "Creating systemd service for Cowrie..."
cat > /etc/systemd/system/cowrie-honeypot.service << 'SYSTEMD'
[Unit]
Description=Cowrie SSH/Telnet Honeypot (Docker Compose)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=forking
RemainAfterExit=yes
WorkingDirectory=/home/cowrie
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
ExecReload=/usr/bin/docker compose restart
TimeoutStartSec=120
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable cowrie-honeypot.service
log "Cowrie systemd service registered."

# ──────────────────────────────────────────────
#  8. Re-start CloudWatch Agent now that log
#     files exist from Cowrie
# ──────────────────────────────────────────────
sleep 10
log "Restarting CloudWatch Agent to pick up Cowrie log files..."
systemctl restart amazon-cloudwatch-agent || log "WARN: CW Agent restart failed – will retry on next boot"

log "============================================================"
log "Honeypot installation COMPLETE."
log "  Cowrie SSH honeypot  : listening on port 22"
log "  Cowrie Telnet        : listening on port 23"
log "  Logs → CloudWatch    : $LOG_GROUP_NAME / $LOG_STREAM_NAME"
log "============================================================"
