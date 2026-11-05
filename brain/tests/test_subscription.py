import asyncio
import base64
import json
import os
from pathlib import Path
import sys

import pytest
from fastapi.testclient import TestClient

from app import config, tts
from app.main import app
from app.models import subscription as sub
from app.models.base import Attachment, ProviderError
from app.models.router import Router


@pytest.fixture
def cli(tmp_path, monkeypatch):
    monkeypatch.setenv("CJ_HOME", str(tmp_path / "config"))
    monkeypatch.setenv("CJ_WORKSPACE", str(tmp_path))
    monkeypatch.setenv("CJ_SUB_TEST_LOG", str(tmp_path / "launch.json"))
    binary = tmp_path / "assistant"
    binary.write_text(f"#!{sys.executable}\n" + '''
import json, os, pathlib, sys
args = sys.argv[1:]
if args[:2] == ["login", "status"]:
    print("Logged in using ChatGPT"); sys.exit()
if args[:2] == ["auth", "status"]:
    print(json.dumps({"loggedIn":True,"authMethod":"claude.ai","subscriptionType":"pro"})); sys.exit()
prompt = sys.stdin.read()
images = [args[i+1] for i,a in enumerate(args[:-1]) if a == "--image"]
pathlib.Path(os.environ["CJ_SUB_TEST_LOG"]).write_text(json.dumps({"args":args,"prompt":prompt,
    "images_exist":all(pathlib.Path(p).exists() for p in images),
    "api_keys":[k for k in ("OPENAI_API_KEY","CODEX_API_KEY","ANTHROPIC_API_KEY") if k in os.environ]}))
if "--output-last-message" in args:
    pathlib.Path(args[args.index("--output-last-message")+1]).write_text("Subscription reply")
else:
    print(json.dumps({"result":"Subscription reply","is_error":False}))
''')
    binary.chmod(0o700)
    monkeypatch.setenv("CJ_CODEX_BIN", str(binary))
    monkeypatch.setenv("CJ_CLAUDE_CODE_BIN", str(binary))
    return tmp_path


@pytest.mark.parametrize("provider,flag", [("codex", "--dangerously-bypass-approvals-and-sandbox"),
                                           ("claude-code", "--dangerously-skip-permissions")])
def test_subscription_cli_uses_login_and_unrestricted_tools(cli, monkeypatch, provider, flag):
    for key in ("OPENAI_API_KEY", "CODEX_API_KEY", "ANTHROPIC_API_KEY"):
        monkeypatch.setenv(key, "must-not-be-used")
    result = asyncio.run(sub.Subscription(provider).complete("Answer briefly", [{"role":"user","text":"hello; $(bad)"}]))
    assert result.text == "Subscription reply"
    launch = json.loads((cli / "launch.json").read_text())
    assert flag in launch["args"] and launch["api_keys"] == []
    assert "hello; $(bad)" in launch["prompt"]
    assert "hello; $(bad)" not in launch["args"]


def test_camera_file_exists_during_request_and_is_removed_after(cli):
    image = Attachment(base64.b64encode(b"fake-camera-frame").decode(), "image/jpeg")
    asyncio.run(sub.Subscription("codex").complete("Look", [{"role":"user","text":"read this"}], image))
    launch = json.loads((cli / "launch.json").read_text())
    image_path = launch["args"][launch["args"].index("--image") + 1]
    assert launch["images_exist"] and not Path(image_path).exists()


def test_api_credentials_do_not_satisfy_subscription_login(cli, monkeypatch):
    async def api_account(_):
        return {"installed": True, "signed_in": True, "subscription": False}
    monkeypatch.setattr(sub, "account", api_account)
    with pytest.raises(ProviderError, match="will not fall back"):
        asyncio.run(sub.Subscription("codex").complete("system", []))
    assert not (cli / "launch.json").exists()


def test_expired_claude_session_explains_how_to_sign_in(cli, monkeypatch):
    async def expired_session(args, **kwargs):
        if args[1:3] == ["auth", "status"]:
            return 0, json.dumps({"loggedIn": True, "authMethod": "claude.ai"}), ""
        return 1, json.dumps({"is_error": True, "result": "Failed to authenticate: OAuth session expired and could not be refreshed"}), ""

    monkeypatch.setattr(sub, "run_process", expired_session)
    with pytest.raises(ProviderError, match="claude auth login"):
        asyncio.run(sub.Subscription("claude-code").complete("Answer briefly", []))


def test_selected_subscription_never_falls_back_to_gemini(cli, monkeypatch):
    monkeypatch.delenv("CJ_FORCE_MOCK", raising=False)
    monkeypatch.setenv("CJ_PROVIDER", "codex")
    monkeypatch.setenv("CJ_CODEX_BIN", "/nonexistent/codex")
    router = Router()
    assert router.preferred() == "codex"
    assert [p.name for p in router.chain()] == ["codex"]
    assert [p.name for p in router.chain(Attachment("AA==", "audio/wav"))] == ["codex"]


def test_subscription_http_requires_pairing_and_uses_phone_speech(cli, monkeypatch):
    monkeypatch.setenv("CJ_PROVIDER", "codex")
    async def no_api_tts(*args):
        raise AssertionError("API speech must not run")
    monkeypatch.setattr(tts, "speak", no_api_tts)
    client = TestClient(app)
    body = {"text":"hello", "voice":True}
    assert client.post("/api/ask", json=body).status_code == 401
    headers = {"Authorization": f"Bearer {config.token()}"}
    response = client.post("/api/ask", json=body, headers=headers)
    assert response.status_code == 200, response.text
    assert response.json()["spoken"] == "Subscription reply"
    assert "voice_b64" not in response.json()
    assert client.get("/health").json()["voice_mode"] == "local"
    assert client.get("/api/bridge/status").status_code == 401
    assert client.get("/api/bridge/status", headers=headers).json()["execution"] == "unrestricted"
    assert client.post("/api/ask", json={"audio_b64":"AA=="}, headers=headers).status_code == 422


def test_old_live_client_is_told_to_update_without_gemini(cli, monkeypatch):
    monkeypatch.setenv("CJ_PROVIDER", "codex")
    with TestClient(app).websocket_connect("/ws/live", headers={"Authorization": f"Bearer {config.token()}"}) as ws:
        assert ws.receive_json()["type"] == "error"


def test_cancel_terminates_running_cli(cli):
    async def exercise():
        pidfile = cli / "pid"
        script = "import os,time,pathlib; pathlib.Path(%r).write_text(str(os.getpid())); time.sleep(60)" % str(pidfile)
        task = asyncio.create_task(sub.run_process([sys.executable, "-c", script]))
        for _ in range(100):
            if pidfile.exists():
                break
            await asyncio.sleep(0.01)
        assert pidfile.exists()
        pid = int(pidfile.read_text())
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)
    asyncio.run(exercise())
