import http.client

from starfall_api import traffic


def test_full_journey(monkeypatch):
    monkeypatch.setenv("API_URL", "https://api.example.com/")
    calls = []

    def fake_call(method, url, body=None):
        calls.append((method, url, body))
        return (201 if method == "POST" else 200), {}

    monkeypatch.setattr(traffic, "call", fake_call)
    assert traffic.handler({}) == {"ok": True, "results": {"health": 200, "submit": 201, "leaderboard": 200}}
    assert calls[1][2]["synthetic"] is True
    assert "board=synthetic" in calls[2][1]


def test_connection_errors_never_raise(monkeypatch):
    for error in (ConnectionResetError("reset"), http.client.IncompleteRead(b"x"), TimeoutError("slow")):
        def broken(*_a, _e=error, **_k):
            raise _e

        monkeypatch.setattr(traffic.urllib.request, "urlopen", broken)
        status, payload = traffic.call("GET", "https://api.example.com/health")
        assert status == 0 and "error" in payload


def test_failure_is_reported_not_raised(monkeypatch):
    monkeypatch.setenv("API_URL", "https://api.example.com")
    monkeypatch.setattr(traffic, "call", lambda m, u, b=None: (500, {"error": "boom"}))
    result = traffic.handler({})
    assert result["ok"] is False
