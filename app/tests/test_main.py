from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_root_returns_message_and_version():
    r = client.get("/")
    assert r.status_code == 200
    body = r.json()
    assert "message" in body
    assert "version" in body


def test_healthz_is_ok():
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_readyz_toggle_round_trip():
    assert client.get("/readyz").status_code == 200

    r = client.post("/toggle-ready")
    assert r.status_code == 200
    assert r.json() == {"ready": False}
    assert client.get("/readyz").status_code == 503

    client.post("/toggle-ready")
    assert client.get("/readyz").status_code == 200


def test_metrics_exposes_request_counter():
    client.get("/")  # ensure at least one labeled sample exists
    r = client.get("/metrics")
    assert r.status_code == 200
    assert "app_requests_total" in r.text
