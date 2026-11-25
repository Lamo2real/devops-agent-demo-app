from orders_api import traffic


def test_full_journey(monkeypatch):
    monkeypatch.setenv("API_URL", "https://api.example.com/")
    calls = []

    def fake_call(method, url, body=None):
        calls.append((method, url))
        if url.endswith("/orders") and method == "POST":
            return 201, {"order_id": "o-1"}
        return 200, {}

    monkeypatch.setattr(traffic, "call", fake_call)
    assert traffic.handler({}) == {"ok": True, "results": {"health": 200, "create": 201, "get": 200}}
    assert calls[-1] == ("GET", "https://api.example.com/orders/o-1")


def test_connection_errors_never_raise(monkeypatch):
    import http.client

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
    assert result["ok"] is False and "get" not in result["results"]
