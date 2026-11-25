#!/usr/bin/env python3
"""Check a deployed API: health, score submission, leaderboard, validation and CORS.
Usage: python scripts/smoke_test.py <api url> [expected version] [web origin]"""

import json
import sys
import urllib.error
import urllib.request


def call(method, url, body=None, origin=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"content-type": "application/json"}
    if origin:
        headers["origin"] = origin
    request = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.loads(response.read() or b"{}"), dict(response.headers)
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read() or b"{}"), dict(exc.headers)


def main() -> int:
    base = sys.argv[1].rstrip("/")
    expected_version = sys.argv[2] if len(sys.argv) > 2 else None
    origin = sys.argv[3] if len(sys.argv) > 3 else None
    failures = []

    def check(name, ok, detail=""):
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}{': ' + detail if detail else ''}")
        if not ok:
            failures.append(name)

    status, health, _ = call("GET", f"{base}/health")
    check("health", status == 200 and health.get("status") == "ok", f"{status} {health}")
    if expected_version:
        check("deployed version", health.get("version") == expected_version, health.get("version", ""))

    status, created, headers = call("POST", f"{base}/scores", {"player": "smoke-test", "score": 77, "duration_ms": 20_000, "synthetic": True}, origin)
    check("submit score", status == 201 and created.get("score") == 77, f"{status}")
    if origin:
        allowed = {k.lower(): v for k, v in headers.items()}.get("access-control-allow-origin")
        check("CORS allows the game page", allowed == origin, f"{allowed}")

    status, board, _ = call("GET", f"{base}/leaderboard?board=synthetic&limit=50")
    players = [e["player"] for e in board.get("entries", [])]
    check("score appears on the leaderboard", status == 200 and "smoke-test" in players, f"{status}")
    status, board, _ = call("GET", f"{base}/leaderboard?limit=5")
    check("global leaderboard hides synthetic scores", status == 200 and "smoke-test" not in [e["player"] for e in board.get("entries", [])], f"{status}")
    status, _, _ = call("POST", f"{base}/scores", {"player": "smoke-test", "score": 10**7, "duration_ms": 20_000})
    check("impossible score rejected", status == 400, f"{status}")

    print("RESULT:", "PASS" if not failures else "FAIL")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
