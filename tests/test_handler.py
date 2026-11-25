import json

import pytest

from starfall_api import handler as h


class FakeTable:
    def __init__(self):
        self.items = []

    def put_item(self, Item):
        self.items.append(Item)

    def query(self, KeyConditionExpression, Limit, ScanIndexForward):
        board = KeyConditionExpression.get_expression()["values"][1]
        rows = sorted((i for i in self.items if i["board"] == board), key=lambda i: i["sort_key"], reverse=not ScanIndexForward)
        return {"Items": rows[:Limit]}


@pytest.fixture(autouse=True)
def fake_table(monkeypatch):
    table = FakeTable()
    monkeypatch.setattr(h, "_TABLE", table)
    return table


def event(route_key, body=None, query=None):
    evt = {"routeKey": route_key, "requestContext": {"requestId": "req-1"}}
    if body is not None:
        evt["body"] = body if isinstance(body, str) else json.dumps(body)
    if query is not None:
        evt["queryStringParameters"] = query
    return evt


def body(response):
    return json.loads(response["body"])


GAME = {"player": "Nova", "score": 420, "duration_ms": 60_000}


def test_health():
    r = h.handler(event("GET /health"))
    assert r["statusCode"] == 200 and body(r)["status"] == "ok"


def test_submit_and_leaderboard_order(fake_table):
    for player, score in [("Ana", 100), ("Bo", 900), ("Cy", 500), ("Di", 500)]:
        r = h.handler(event("POST /scores", {"player": player, "score": score, "duration_ms": 60_000}))
        assert r["statusCode"] == 201
    r = h.handler(event("GET /leaderboard", query={"limit": "3"}))
    entries = body(r)["entries"]
    assert [e["player"] for e in entries] == ["Bo", "Cy", "Di"]  # ties: earlier first
    assert [e["rank"] for e in entries] == [1, 2, 3]
    assert all(set(e) == {"rank", "player", "score", "created_at"} for e in entries)


def test_default_limit_and_empty_board():
    r = h.handler(event("GET /leaderboard"))
    assert r["statusCode"] == 200 and body(r) == {"board": "global", "entries": []}


def test_synthetic_scores_never_reach_the_global_board(fake_table):
    h.handler(event("POST /scores", {**GAME, "synthetic": True}))
    h.handler(event("POST /scores", GAME))
    assert body(h.handler(event("GET /leaderboard")))["entries"][0]["player"] == "Nova"
    assert len(body(h.handler(event("GET /leaderboard")))["entries"]) == 1
    synthetic = body(h.handler(event("GET /leaderboard", query={"board": "synthetic"})))
    assert synthetic["board"] == "synthetic" and len(synthetic["entries"]) == 1


def test_sort_key_orders_by_score(fake_table):
    h.handler(event("POST /scores", {**GAME, "score": 9}))
    h.handler(event("POST /scores", {**GAME, "score": 10}))
    keys = sorted(i["sort_key"] for i in fake_table.items)
    assert keys[0].startswith("99999990#") and keys[1].startswith("99999991#")


@pytest.mark.parametrize("payload,message", [
    (None, "request body is required"),
    ("{nope", "not valid JSON"),
    ("[]", "JSON object"),
    ('{"player": "A", "score": 1, "duration_ms": 5000, "x": ' + "9" * 5000 + "}", "valid JSON"),
    ({**GAME, "player": ""}, "player"),
    ({**GAME, "player": "x" * 17}, "player"),
    ({**GAME, "player": "<script>"}, "player"),
    ({**GAME, "player": " lead"}, "player"),
    ({**GAME, "player": 7}, "player"),
    ({**GAME, "score": -1}, "score"),
    ({**GAME, "score": 1_000_001}, "score"),
    ({**GAME, "score": 1.5}, "score"),
    ({**GAME, "score": "10"}, "score"),
    ({**GAME, "score": True}, "score"),
    ({**GAME, "score": None}, "score"),
    ({**GAME, "duration_ms": 999}, "duration_ms"),
    ({**GAME, "duration_ms": 3_600_001}, "duration_ms"),
    ({**GAME, "duration_ms": "60000"}, "duration_ms"),
    ({"player": "Nova", "score": 10_000, "duration_ms": 5_000}, "not possible"),
])
def test_invalid_submissions_are_400(payload, message):
    r = h.handler(event("POST /scores", payload) if payload is not None else event("POST /scores"))
    assert r["statusCode"] == 400
    assert message in body(r)["error"]


def test_plausibility_boundary():
    # 60 points/second plus 100 slack
    assert h.handler(event("POST /scores", {"player": "A", "score": 400, "duration_ms": 5_000}))["statusCode"] == 201
    assert h.handler(event("POST /scores", {"player": "A", "score": 401, "duration_ms": 5_000}))["statusCode"] == 400


@pytest.mark.parametrize("query", [{"limit": "0"}, {"limit": "51"}, {"limit": "x"}, {"limit": "-3"}, {"limit": "1.5"}, {"board": "other"}])
def test_bad_leaderboard_queries_are_400(query):
    assert h.handler(event("GET /leaderboard", query=query))["statusCode"] == 400


def test_unexpected_error_is_500_and_logged(monkeypatch, caplog):
    class Broken:
        def put_item(self, **_):
            raise RuntimeError("dynamodb down")

    monkeypatch.setattr(h, "_TABLE", Broken())
    r = h.handler(event("POST /scores", GAME))
    assert r["statusCode"] == 500 and body(r)["request_id"] == "req-1"
    assert "unhandled error" in caplog.text


def test_unknown_route_is_404():
    assert h.handler(event("DELETE /scores"))["statusCode"] == 404
