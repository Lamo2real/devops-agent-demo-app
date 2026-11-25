"""Starfall Dodge leaderboard API: a small HTTP API on Lambda + DynamoDB.

Routes (API Gateway HTTP API, payload format 2.0):
    GET  /health                    liveness, does not touch DynamoDB
    POST /scores                    submit a finished game
    GET  /leaderboard?limit=10      best scores first

Boards: "global" (real players) and "synthetic" (the traffic generator and the
smoke test, never shown to players). Every request logs one JSON line (route,
status, latency, request id) so AWS DevOps Agent can query errors with
CloudWatch Logs Insights.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timezone
from typing import Any

import boto3
from boto3.dynamodb.conditions import Key
from botocore.config import Config

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

BOARDS = ("global", "synthetic")
MAX_SCORE = 1_000_000
MAX_DURATION_MS = 3_600_000  # one hour
MIN_DURATION_MS = 1_000
# Plausibility: the game cannot award more than this many points per second.
MAX_POINTS_PER_SECOND = 60
SCORE_SLACK = 100
KEY_SCORE_DIGITS = 8  # sort key: (10^8 - score), so the best score sorts first
DEFAULT_LIMIT = 10
MAX_LIMIT = 50
PLAYER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _.\-]{0,15}$")

_TABLE = None


class ValidationError(Exception):
    """The request is invalid: answered with 400."""


def table():
    """DynamoDB table, created once per container (tests replace it)."""
    global _TABLE
    if _TABLE is None:
        resource = boto3.resource("dynamodb", config=Config(retries={"mode": "standard", "max_attempts": 3}))
        _TABLE = resource.Table(os.environ["TABLE_NAME"])
    return _TABLE


def respond(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json", "cache-control": "no-store"},
        "body": json.dumps(body),
    }


def parse_score(raw: str | None) -> dict[str, Any]:
    """Validate a submitted game."""
    if not raw:
        raise ValidationError("request body is required")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"body is not valid JSON: {exc.msg}") from None
    except ValueError:  # e.g. an integer with thousands of digits
        raise ValidationError("body is not valid JSON") from None
    if not isinstance(data, dict):
        raise ValidationError("body must be a JSON object")

    player = data.get("player")
    if not isinstance(player, str) or not PLAYER_RE.match(player):
        raise ValidationError("player must be 1 to 16 characters: letters, digits, space, _ . -")

    score = data.get("score")
    if isinstance(score, bool) or not isinstance(score, int) or not 0 <= score <= MAX_SCORE:
        raise ValidationError(f"score must be an integer from 0 to {MAX_SCORE}")

    duration_ms = data.get("duration_ms")
    if isinstance(duration_ms, bool) or not isinstance(duration_ms, int) or not MIN_DURATION_MS <= duration_ms <= MAX_DURATION_MS:
        raise ValidationError(f"duration_ms must be an integer from {MIN_DURATION_MS} to {MAX_DURATION_MS}")
    if score > MAX_POINTS_PER_SECOND * (duration_ms / 1000) + SCORE_SLACK:
        raise ValidationError("score is not possible for that duration")

    board = "synthetic" if data.get("synthetic") is True else "global"
    return {"player": player.strip(), "score": score, "duration_ms": duration_ms, "board": board}


def submit_score(event: dict[str, Any]) -> dict[str, Any]:
    entry = parse_score(event.get("body"))
    created_at = datetime.now(timezone.utc).isoformat()
    score_id = str(uuid.uuid4())
    item = {
        "board": entry["board"],
        "sort_key": f"{10 ** KEY_SCORE_DIGITS - entry['score']:0{KEY_SCORE_DIGITS}d}#{created_at}#{score_id}",
        "score_id": score_id,
        "player": entry["player"],
        "score": entry["score"],
        "duration_ms": entry["duration_ms"],
        "created_at": created_at,
    }
    table().put_item(Item=item)
    return respond(201, {"id": score_id, "board": entry["board"], "player": entry["player"], "score": entry["score"]})


def parse_limit(params: dict[str, str] | None) -> int:
    raw = (params or {}).get("limit")
    if raw is None:
        return DEFAULT_LIMIT
    if not re.fullmatch(r"[0-9]{1,3}", raw) or not 1 <= int(raw) <= MAX_LIMIT:
        raise ValidationError(f"limit must be an integer from 1 to {MAX_LIMIT}")
    return int(raw)


def leaderboard(event: dict[str, Any]) -> dict[str, Any]:
    params = event.get("queryStringParameters") or {}
    limit = parse_limit(params)
    board = params.get("board", "global")
    if board not in BOARDS:
        raise ValidationError(f"board must be one of {', '.join(BOARDS)}")
    items = table().query(KeyConditionExpression=Key("board").eq(board), Limit=limit, ScanIndexForward=True).get("Items", [])
    entries = [
        {"rank": rank, "player": item["player"], "score": int(item["score"]), "created_at": item["created_at"]}
        for rank, item in enumerate(items, start=1)
    ]
    return respond(200, {"board": board, "entries": entries})


def route(event: dict[str, Any]) -> dict[str, Any]:
    route_key = event.get("routeKey", "")
    if route_key == "GET /health":
        return respond(200, {"status": "ok", "version": os.environ.get("APP_VERSION", "dev")})
    if route_key == "POST /scores":
        return submit_score(event)
    if route_key == "GET /leaderboard":
        return leaderboard(event)
    return respond(404, {"error": "route not found", "route": route_key})


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    started = time.perf_counter()
    request_id = (event.get("requestContext") or {}).get("requestId", "")
    try:
        response = route(event)
    except ValidationError as exc:
        response = respond(400, {"error": str(exc)})
    except Exception:  # noqa: BLE001 - every unexpected error is a 500 with a stack trace in the log
        LOG.exception(json.dumps({"msg": "unhandled error", "route": event.get("routeKey"), "request_id": request_id}))
        response = respond(500, {"error": "internal error", "request_id": request_id})
    LOG.info(json.dumps({
        "msg": "request",
        "route": event.get("routeKey"),
        "status": response["statusCode"],
        "latency_ms": round((time.perf_counter() - started) * 1000, 1),
        "request_id": request_id,
    }))
    return response
