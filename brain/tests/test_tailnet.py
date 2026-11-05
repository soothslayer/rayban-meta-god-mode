import json
import subprocess

import pytest
from fastapi.testclient import TestClient

from app import config, tailnet
from app.main import app


HOST = "cj.example.ts.net"
KEY = HOST + ":8443"


@pytest.fixture
def serve():
    return {"TCP": {"8443": {"HTTPS": True}},
            "Web": {KEY: {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8765"}}}}}


def test_discovers_only_cj_private_root(serve):
    assert tailnet.private_url(HOST + ".", serve) == "https://" + KEY
    assert tailnet.private_url("another.example.ts.net", serve) is None
    serve["AllowFunnel"] = {KEY: True}
    assert tailnet.private_url(HOST, serve) is None
    serve["AllowFunnel"][KEY] = False
    serve["Web"][KEY]["Handlers"]["/api"] = {"Proxy": "http://127.0.0.1:9999"}
    assert tailnet.private_url(HOST, serve) is None


def test_rejects_other_backends_and_transient_overrides(serve):
    serve["Foreground"] = {"other": {"TCP": {"8443": {"HTTPS": True}}}}
    assert tailnet.private_url(HOST, serve) is None
    del serve["Foreground"]
    serve["Web"][KEY]["Handlers"]["/"]["Proxy"] = "http://127.0.0.1:1234"
    assert tailnet.private_url(HOST, serve) is None


def test_suggests_free_port_without_touching_existing_services(monkeypatch):
    def run(args, **kwargs):
        if args[1:] == ["status", "--json"]:
            result = {"BackendState": "Running", "Self": {"DNSName": HOST}}
        else:
            assert args[1:] == ["serve", "status", "--json"]
            result = {"TCP": {"8443": {"HTTPS": True}}, "Foreground": {"other": {"TCP": {"9443": {"TCPForward": "localhost:80"}}}}}
        return subprocess.CompletedProcess(args, 0, json.dumps(result).encode())

    monkeypatch.setattr(tailnet.shutil, "which", lambda _: "/test/tailscale")
    monkeypatch.setattr(tailnet.subprocess, "run", run)
    url, hint = tailnet.discover()
    assert url is None and "--https=10443" in hint


def test_lan_pairing_survives_disconnected_tailnet(monkeypatch):
    monkeypatch.setattr(tailnet, "discover", lambda: (None, "Connect Tailscale."))
    client = TestClient(app)
    assert client.get("/api/bridge/pairing").status_code == 401
    response = client.get("/api/bridge/pairing", headers={"Authorization": f"Bearer {config.token()}"})
    assert response.status_code == 200
    assert response.json()["lan"].startswith("http://")
    assert response.json()["tailscale"] is None
