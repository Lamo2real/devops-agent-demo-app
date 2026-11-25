#!/usr/bin/env python3
"""Check a deployed API: health, create an order, read it back, reject bad input.
Usage: python scripts/smoke_test.py https://<api-id>.execute-api.<region>.amazonaws.com [expected_version]"""

import json
import sys
import urllib.error
import urllib.request


def call(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}")


def main() -> int:
    base = sys.argv[1].rstrip("/")
    expected_version = sys.argv[2] if len(sys.argv) > 2 else None
    failures = []

    def check(name, ok, detail=""):
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}{': ' + detail if detail else ''}")
        if not ok:
            failures.append(name)

    status, health = call("GET", f"{base}/health")
    check("health", status == 200 and health.get("status") == "ok", f"{status} {health}")
    if expected_version:
        check("deployed version", health.get("version") == expected_version, health.get("version", ""))
    status, order = call("POST", f"{base}/orders", {"customer_id": "smoke", "items": [{"sku": "S-1", "quantity": 3, "unit_price": 10}]})
    check("create order", status == 201 and order.get("total") == 30, f"{status}")
    if status == 201:
        status, got = call("GET", f"{base}/orders/{order['order_id']}")
        check("read order", status == 200 and got.get("order_id") == order["order_id"], f"{status}")
    status, _ = call("POST", f"{base}/orders", {"customer_id": "smoke", "items": []})
    check("invalid order rejected", status == 400, f"{status}")
    print("RESULT:", "PASS" if not failures else "FAIL")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
