"""Synthetic traffic: one customer journey per invocation (every minute).

GET /health, POST /orders, GET /orders/{id}. It gives the API steady traffic
so the symptom alarms have data and a broken deployment shows up within
minutes. It never raises: failures are what the API alarms are for.
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
    status, order = call("POST", f"{base}/orders", {
        "customer_id": "synthetic-traffic",
        "items": [{"sku": "SKU-STARTER-KIT", "quantity": 2, "unit_price": 149.5}],
    })
    results["create"] = status
    if status == 201 and order.get("order_id"):
        results["get"], _ = call("GET", f"{base}/orders/{order['order_id']}")

    ok = results.get("health") == 200 and results.get("create") == 201 and results.get("get") == 200
    LOG.info(json.dumps({"msg": "synthetic journey", "ok": ok, "results": results}))
    return {"ok": ok, "results": results}
