import json
import uuid
from decimal import Decimal

import pytest

from orders_api import handler as h


class FakeTable:
    def __init__(self):
        self.items = {}

    def put_item(self, Item, ConditionExpression=None):
        assert Item["order_id"] not in self.items
        self.items[Item["order_id"]] = Item

    def get_item(self, Key):
        item = self.items.get(Key["order_id"])
        return {"Item": item} if item else {}


@pytest.fixture(autouse=True)
def fake_table(monkeypatch):
    table = FakeTable()
    monkeypatch.setattr(h, "_TABLE", table)
    return table


def event(route_key, body=None, path=None):
    evt = {"routeKey": route_key, "requestContext": {"requestId": "req-1", "http": {"method": route_key.split()[0]}}}
    if body is not None:
        evt["body"] = body if isinstance(body, str) else json.dumps(body)
    if path:
        evt["pathParameters"] = path
    return evt


def body(response):
    return json.loads(response["body"])


VALID = {"customer_id": "c-1", "items": [{"sku": "A", "quantity": 2, "unit_price": 10.5}, {"sku": "B", "quantity": 1, "unit_price": 0.99}]}


def test_health():
    r = h.handler(event("GET /health"))
    assert r["statusCode"] == 200 and body(r)["status"] == "ok"


def test_create_and_get_order(fake_table):
    r = h.handler(event("POST /orders", VALID))
    assert r["statusCode"] == 201
    created = body(r)
    assert created["total"] == 21.99
    assert created["status"] == "CREATED"
    assert uuid.UUID(created["order_id"])
    stored = fake_table.items[created["order_id"]]
    assert stored["total"] == Decimal("21.99")

    r = h.handler(event("GET /orders/{order_id}", path={"order_id": created["order_id"]}))
    assert r["statusCode"] == 200 and body(r)["customer_id"] == "c-1"


def test_unknown_order_is_404():
    r = h.handler(event("GET /orders/{order_id}", path={"order_id": str(uuid.uuid4())}))
    assert r["statusCode"] == 404


@pytest.mark.parametrize("payload,message", [
    (None, "request body is required"),
    ("{not json", "not valid JSON"),
    ([], "JSON object"),
    ({"items": VALID["items"]}, "customer_id"),
    ({"customer_id": "c", "items": []}, "items must be a list"),
    ({"customer_id": "c", "items": [{"sku": "A", "quantity": 0, "unit_price": 1}]}, "quantity"),
    ({"customer_id": "c", "items": [{"sku": "A", "quantity": True, "unit_price": 1}]}, "quantity"),
    ({"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": -1}]}, "unit_price"),
    ({"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": "x"}]}, "unit_price"),
    ({"customer_id": "c", "items": [{"sku": "", "quantity": 1, "unit_price": 1}]}, "sku"),
    ({"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": "12.5"}]}, "unit_price"),
    ({"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": None}]}, "unit_price"),
    ('{"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": 1e30}]}', "unit_price"),
    ('{"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": 1e999}]}', "unit_price"),
    ('{"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": 1000000.01}]}', "unit_price"),
    ('{"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": NaN}]}', "unit_price"),
    ('{"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": Infinity}]}', "unit_price"),
    ('{"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": ' + "9" * 31 + '}]}', "unit_price"),
    ('{"customer_id": "c", "items": [{"sku": "A", "quantity": ' + "9" * 5000 + ', "unit_price": 1}]}', "valid JSON"),
])
def test_validation_errors_are_400(payload, message):
    r = h.handler(event("POST /orders", payload) if payload is not None else event("POST /orders"))
    assert r["statusCode"] == 400
    assert message in body(r)["error"]


def test_boundary_prices_are_accepted():
    for price in ("0", "0.005", "1000000"):
        payload = '{"customer_id": "c", "items": [{"sku": "A", "quantity": 1, "unit_price": %s}]}' % price
        assert h.handler(event("POST /orders", payload))["statusCode"] == 201, price


def test_bad_order_id_is_400():
    r = h.handler(event("GET /orders/{order_id}", path={"order_id": "nope"}))
    assert r["statusCode"] == 400


def test_unexpected_error_is_500_and_logged(monkeypatch, caplog):
    class Broken:
        def put_item(self, **_):
            raise RuntimeError("dynamodb down")

    monkeypatch.setattr(h, "_TABLE", Broken())
    r = h.handler(event("POST /orders", VALID))
    assert r["statusCode"] == 500 and body(r)["request_id"] == "req-1"
    assert "unhandled error" in caplog.text


def test_unknown_route_is_404():
    assert h.handler(event("DELETE /orders"))["statusCode"] == 404
