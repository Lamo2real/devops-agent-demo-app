"""Orders API: a small HTTP API on Lambda + DynamoDB.

Routes (API Gateway HTTP API, payload format 2.0):
    GET  /health              liveness, does not touch DynamoDB
    POST /orders              create an order
    GET  /orders/{order_id}   read one order

Every request logs one JSON line (route, status, latency, request id) so the
AWS DevOps Agent can query errors with CloudWatch Logs Insights.
"""

from __future__ import annotations

import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any

import boto3
from botocore.config import Config

LOG = logging.getLogger()
LOG.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

MAX_ITEMS = 50
MAX_QUANTITY = 1000
MAX_UNIT_PRICE = Decimal("1000000")

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


def _json_default(value: Any) -> Any:
    if isinstance(value, Decimal):
        return int(value) if value == value.to_integral_value() else float(value)
    raise TypeError(f"not serializable: {type(value).__name__}")


def respond(status: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, default=_json_default),
    }


def parse_order(raw: str | None) -> dict[str, Any]:
    """Validate a create-order request and compute the total."""
    if not raw:
        raise ValidationError("request body is required")
    try:
        data = json.loads(raw, parse_float=Decimal)
    except json.JSONDecodeError as exc:
        raise ValidationError(f"body is not valid JSON: {exc.msg}") from None
    except ValueError:  # e.g. an integer with thousands of digits
        raise ValidationError("body is not valid JSON") from None
    if not isinstance(data, dict):
        raise ValidationError("body must be a JSON object")

    customer_id = data.get("customer_id")
    if not isinstance(customer_id, str) or not 1 <= len(customer_id) <= 64:
        raise ValidationError("customer_id must be a string of 1 to 64 characters")

    items = data.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
        raise ValidationError(f"items must be a list of 1 to {MAX_ITEMS} entries")

    clean_items = []
    total = Decimal("0")
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValidationError(f"items[{index}] must be an object")
        sku = item.get("sku")
        quantity = item.get("quantity")
        unit_price = item.get("unit_price")
        if not isinstance(sku, str) or not 1 <= len(sku) <= 64:
            raise ValidationError(f"items[{index}].sku must be a string of 1 to 64 characters")
        if isinstance(quantity, bool) or not isinstance(quantity, int) or not 1 <= quantity <= MAX_QUANTITY:
            raise ValidationError(f"items[{index}].quantity must be an integer from 1 to {MAX_QUANTITY}")
        # Only JSON numbers: json.loads gives int or Decimal (NaN and Infinity arrive as float).
        if isinstance(unit_price, bool) or not isinstance(unit_price, (int, Decimal)):
            raise ValidationError(f"items[{index}].unit_price must be a number")
        price = Decimal(unit_price)
        if not price.is_finite() or not 0 <= price <= MAX_UNIT_PRICE:
            raise ValidationError(f"items[{index}].unit_price must be a number from 0 to {MAX_UNIT_PRICE}")
        try:
            price = price.quantize(Decimal("0.01"))
        except InvalidOperation:  # defence in depth: never a 500 for client input
            raise ValidationError(f"items[{index}].unit_price is not a valid amount") from None
        clean_items.append({"sku": sku, "quantity": quantity, "unit_price": price})
        total += price * quantity

    return {"customer_id": customer_id, "items": clean_items, "total": total.quantize(Decimal("0.01"))}


def create_order(event: dict[str, Any]) -> dict[str, Any]:
    order = parse_order(event.get("body"))
    order["order_id"] = str(uuid.uuid4())
    order["status"] = "CREATED"
    order["created_at"] = datetime.now(timezone.utc).isoformat()
    table().put_item(Item=order, ConditionExpression="attribute_not_exists(order_id)")
    return respond(201, order)


def get_order(order_id: str) -> dict[str, Any]:
    try:
        uuid.UUID(order_id)
    except ValueError:
        raise ValidationError("order_id must be a UUID") from None
    item = table().get_item(Key={"order_id": order_id}).get("Item")
    if item is None:
        return respond(404, {"error": "order not found", "order_id": order_id})
    return respond(200, item)


def route(event: dict[str, Any]) -> dict[str, Any]:
    route_key = event.get("routeKey", "")
    if route_key == "GET /health":
        return respond(200, {"status": "ok", "version": os.environ.get("APP_VERSION", "dev")})
    if route_key == "POST /orders":
        return create_order(event)
    if route_key == "GET /orders/{order_id}":
        return get_order((event.get("pathParameters") or {}).get("order_id", ""))
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
