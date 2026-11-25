"""Synthetic players: one journey per invocation (every minute).

GET /health, POST /scores (synthetic board), GET /leaderboard (synthetic board).
It gives the API steady traffic so the symptom alarms have data and a broken
deployment shows up within minutes. It never raises: failures are what the
API alarms are for.
"""

from __future__ import annotations

import http.client
import json
import logging
import os
import urllib.error
import urllib.request
from typing import Any

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

TIMEOUT_SECONDS = 8


def call(method: str, url: str, body: dict[str, Any] | None = None) -> tuple[int, dict[str, Any]]:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:  # noqa: S310 (our own API URL)
            payload = json.loads(response.read() or b"{}")
            return response.status, payload if isinstance(payload, dict) else {}
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read() or b"{}")
        except (OSError, http.client.HTTPException, ValueError):
            payload = {}
        return exc.code, payload if isinstance(payload, dict) else {}
    except (OSError, http.client.HTTPException, ValueError) as exc:  # URLError and timeouts are OSErrors
        return 0, {"error": str(exc)}


def handler(event: dict[str, Any], context: Any = None) -> dict[str, Any]:
    base = os.environ["API_URL"].rstrip("/")
    results: dict[str, int] = {}

    results["health"], _ = call("GET", f"{base}/health")
    results["submit"], _ = call("POST", f"{base}/scores", {
        "player": "synthetic-player", "score": 120, "duration_ms": 30_000, "synthetic": True,
    })
    results["leaderboard"], _ = call("GET", f"{base}/leaderboard?board=synthetic&limit=5")

    ok = results["health"] == 200 and results["submit"] == 201 and results["leaderboard"] == 200
    LOG.info(json.dumps({"msg": "synthetic journey", "ok": ok, "results": results}))
    return {"ok": ok, "results": results}
