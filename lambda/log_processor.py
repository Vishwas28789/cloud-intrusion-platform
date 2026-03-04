"""
Cloud Intrusion Behavior Analytics Platform
Lambda Log Processor

Triggered by CloudWatch Logs subscription filter on the Cowrie honeypot
log group. Decodes, parses, and enriches log events then stores them in
DynamoDB for downstream querying and dashboard visualisation.

Log event types handled
-----------------------
  cowrie.login.failed      – Failed SSH/Telnet login attempt
  cowrie.login.success     – Successful login (attacker authenticated)
  cowrie.command.input     – Command executed post-login
  cowrie.session.connect   – New connection established
  cowrie.session.closed    – Connection closed (attacker left)
  cowrie.client.version    – Client software version / banner info
  cowrie.direct-tcpip.data – TCP forwarding attempt
"""

from __future__ import annotations

import base64
import gzip
import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone
from typing import Any

import boto3
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

# ─────────────────────────────────────────────────────────────
#  Configuration
# ─────────────────────────────────────────────────────────────

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

DYNAMODB_TABLE_NAME: str = os.environ["DYNAMODB_TABLE_NAME"]
LOG_GROUP_NAME: str = os.environ.get("LOG_GROUP_NAME", "")
AWS_REGION: str = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

# TTL: keep records for 90 days by default
RECORD_TTL_DAYS: int = int(os.environ.get("RECORD_TTL_DAYS", "90"))

_dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
_table = _dynamodb.Table(DYNAMODB_TABLE_NAME)

# ─────────────────────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────────────────────

def _ttl_epoch(days: int = RECORD_TTL_DAYS) -> int:
    """Return a Unix timestamp <days> from now for DynamoDB TTL."""
    from datetime import timedelta
    expiry = datetime.now(timezone.utc) + timedelta(days=days)
    return int(expiry.timestamp())


def _iso_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _extract_ip(raw: str | None) -> str:
    """Extract first IPv4 address found in a string."""
    if not raw:
        return "unknown"
    match = re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", raw)
    return match.group(0) if match else "unknown"


def _decode_cloudwatch_data(encoded_data: str) -> dict:
    """
    CloudWatch Logs subscription filter payload is base64-encoded,
    gzip-compressed JSON.  Decode and return the log data object.
    """
    compressed = base64.b64decode(encoded_data)
    raw_json = gzip.decompress(compressed).decode("utf-8")
    return json.loads(raw_json)


# ─────────────────────────────────────────────────────────────
#  Event parsers (one per Cowrie event type)
# ─────────────────────────────────────────────────────────────

def _parse_login_failed(cowrie: dict) -> dict:
    return {
        "event_type": "LOGIN_FAILED",
        "attacker_ip": _extract_ip(cowrie.get("src_ip", cowrie.get("peerIP", "unknown"))),
        "username": cowrie.get("username", ""),
        "password": cowrie.get("password", ""),
        "session_id": cowrie.get("session", ""),
        "protocol": cowrie.get("protocol", "ssh"),
    }


def _parse_login_success(cowrie: dict) -> dict:
    return {
        "event_type": "LOGIN_SUCCESS",
        "attacker_ip": _extract_ip(cowrie.get("src_ip", cowrie.get("peerIP", "unknown"))),
        "username": cowrie.get("username", ""),
        "password": cowrie.get("password", ""),
        "session_id": cowrie.get("session", ""),
        "protocol": cowrie.get("protocol", "ssh"),
    }


def _parse_command_input(cowrie: dict) -> dict:
    return {
        "event_type": "COMMAND_INPUT",
        "attacker_ip": _extract_ip(cowrie.get("src_ip", cowrie.get("peerIP", "unknown"))),
        "command": cowrie.get("input", ""),
        "session_id": cowrie.get("session", ""),
    }


def _parse_session_connect(cowrie: dict) -> dict:
    return {
        "event_type": "SESSION_CONNECT",
        "attacker_ip": _extract_ip(cowrie.get("src_ip", cowrie.get("peerIP", "unknown"))),
        "dst_port": str(cowrie.get("dst_port", "")),
        "session_id": cowrie.get("session", ""),
        "protocol": cowrie.get("protocol", "ssh"),
    }


def _parse_client_version(cowrie: dict) -> dict:
    return {
        "event_type": "CLIENT_VERSION",
        "attacker_ip": _extract_ip(cowrie.get("src_ip", cowrie.get("peerIP", "unknown"))),
        "client_version": cowrie.get("version", ""),
        "session_id": cowrie.get("session", ""),
    }


def _parse_generic(cowrie: dict, event_type: str) -> dict:
    return {
        "event_type": event_type.upper().replace(".", "_").replace("COWRIE_", ""),
        "attacker_ip": _extract_ip(cowrie.get("src_ip", cowrie.get("peerIP", "unknown"))),
        "session_id": cowrie.get("session", ""),
        "raw_data": json.dumps(cowrie)[:2048],  # cap at 2 KB
    }


EVENT_PARSERS = {
    "cowrie.login.failed":      _parse_login_failed,
    "cowrie.login.success":     _parse_login_success,
    "cowrie.command.input":     _parse_command_input,
    "cowrie.session.connect":   _parse_session_connect,
    "cowrie.session.closed":    lambda c: _parse_generic(c, "SESSION_CLOSED"),
    "cowrie.client.version":    _parse_client_version,
    "cowrie.direct-tcpip.data": lambda c: _parse_generic(c, "TCP_IP_FORWARD"),
}


# ─────────────────────────────────────────────────────────────
#  Core processing logic
# ─────────────────────────────────────────────────────────────

def _build_dynamo_item(parsed: dict, raw_log: dict) -> dict:
    """
    Build the DynamoDB record that will be stored for a single intrusion event.
    """
    now = _iso_now()
    event_id = str(uuid.uuid4())

    # Cowrie timestamps are ISO-8601; fall back to now
    cowrie_ts = raw_log.get("timestamp", now)

    item: dict[str, Any] = {
        "event_id":   event_id,
        "timestamp":  cowrie_ts,
        "ingested_at": now,
        "log_group":  LOG_GROUP_NAME,
        "ttl":        _ttl_epoch(),
        **parsed,
    }

    # Remove None / empty-string values to keep DynamoDB tidy
    return {k: v for k, v in item.items() if v is not None and v != ""}


def _process_log_event(log_event: dict) -> dict | None:
    """
    Parse a single CloudWatch log event (one JSON line from Cowrie).
    Returns a DynamoDB item dict or None if the event should be skipped.
    """
    message = log_event.get("message", "").strip()
    if not message:
        return None

    # ── Try to parse as Cowrie JSON log ──────────────────────
    try:
        cowrie = json.loads(message)
    except json.JSONDecodeError:
        # Plain-text Cowrie log line – store as-is
        ip = _extract_ip(message)
        return {
            "event_id":   str(uuid.uuid4()),
            "timestamp":  _iso_now(),
            "ingested_at": _iso_now(),
            "event_type": "TEXT_LOG",
            "attacker_ip": ip,
            "raw_data":   message[:2048],
            "log_group":  LOG_GROUP_NAME,
            "ttl":        _ttl_epoch(),
        }

    event_type_raw: str = cowrie.get("eventid", "unknown")
    parser = EVENT_PARSERS.get(event_type_raw)

    if parser:
        parsed = parser(cowrie)
    else:
        parsed = _parse_generic(cowrie, event_type_raw)

    return _build_dynamo_item(parsed, cowrie)


def _batch_write(items: list[dict]) -> int:
    """
    Write items to DynamoDB using batch_writer (handles 25-item batches and
    retries automatically).  Returns the number of items written.
    """
    written = 0
    with _table.batch_writer() as batch:
        for item in items:
            batch.put_item(Item=item)
            written += 1
    return written


# ─────────────────────────────────────────────────────────────
#  Lambda Handler
# ─────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context: Any) -> dict:
    """
    Entry point invoked by the CloudWatch Logs subscription filter.

    The event payload looks like:
      {
        "awslogs": {
          "data": "<base64-gzip-encoded log data>"
        }
      }
    """
    logger.info("Log processor invoked. RequestId: %s", context.aws_request_id)

    awslogs_data = event.get("awslogs", {}).get("data")
    if not awslogs_data:
        logger.warning("Event has no awslogs.data – skipping.")
        return {"statusCode": 200, "processed": 0}

    # ── Decode CloudWatch payload ─────────────────────────────
    try:
        cw_payload = _decode_cloudwatch_data(awslogs_data)
    except Exception as exc:
        logger.error("Failed to decode CloudWatch data: %s", exc)
        raise

    log_events: list[dict] = cw_payload.get("logEvents", [])
    logger.info(
        "Log group: %s | Log stream: %s | Events: %d",
        cw_payload.get("logGroup"),
        cw_payload.get("logStream"),
        len(log_events),
    )

    # ── Process each log line ─────────────────────────────────
    dynamo_items: list[dict] = []
    skipped = 0

    for raw_event in log_events:
        try:
            item = _process_log_event(raw_event)
            if item:
                dynamo_items.append(item)
            else:
                skipped += 1
        except Exception as exc:
            logger.error("Error processing log event %s: %s", raw_event.get("id"), exc)
            skipped += 1

    # ── Write to DynamoDB ─────────────────────────────────────
    written = 0
    if dynamo_items:
        try:
            written = _batch_write(dynamo_items)
            logger.info("Written %d intrusion events to DynamoDB table '%s'.", written, DYNAMODB_TABLE_NAME)
        except ClientError as exc:
            logger.error("DynamoDB write error: %s", exc.response["Error"]["Message"])
            raise

    summary = {
        "statusCode":  200,
        "total_events": len(log_events),
        "processed":   written,
        "skipped":     skipped,
    }
    logger.info("Summary: %s", json.dumps(summary))
    return summary
