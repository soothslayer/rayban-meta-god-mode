import asyncio
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from uuid import uuid4

from fastapi.testclient import TestClient

from app import config
from app.main import app
from app.models.muse import Muse
from app.models.router import Router


def test_muse_talk_uses_native_relay_and_preserves_conversation(monkeypatch):
    async def verify():
        conversation = uuid4()
        messages = []
        peer_closed = asyncio.Event()

        async def relay(reader, writer):
            length = int.from_bytes(await reader.readexactly(4), "big")
            payload = json.loads(await reader.readexactly(length))
            messages.append(payload)
            if payload["text"] == "cancel":
                await reader.read()
                peer_closed.set()
            else:
                body = json.dumps({"reply": "A reply from Muse"}).encode()
                writer.write(len(body).to_bytes(4, "big") + body)
                await writer.drain()
            writer.close()
            await writer.wait_closed()

        with TemporaryDirectory(dir="/tmp") as directory:
            path = str(Path(directory) / "chat")
            monkeypatch.setenv("CJ_MUSE_SOCKET", path)
            async with await asyncio.start_unix_server(relay, path) as server:
                for text in ["hello", "again"]:
                    assert await Muse().reply(text, conversation) == "A reply from Muse"
                task = asyncio.create_task(Muse().reply("cancel", conversation))
                async def received():
                    while len(messages) < 3:
                        await asyncio.sleep(0.005)
                await asyncio.wait_for(received(), 2)
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
                await asyncio.wait_for(peer_closed.wait(), 2)
            assert [item["conversation"] for item in messages] == [str(conversation)] * 3

    asyncio.run(verify())


def test_muse_requires_pairing_without_fallback_or_api_voice(monkeypatch, tmp_path):
    monkeypatch.setenv("CJ_HOME", str(tmp_path))
    monkeypatch.setenv("CJ_PROVIDER", "muse")
    monkeypatch.delenv("CJ_FORCE_MOCK", raising=False)
    monkeypatch.delenv("CJ_MUSE_SOCKET", raising=False)
    client = TestClient(app)
    assert [p.name for p in Router().chain()] == ["muse"]
    assert client.get("/health").json()["voice_mode"] == "local"
    assert client.post("/api/ask", json={"text": "hello"}).status_code == 401
    headers = {"Authorization": "Bearer " + config.token()}
    result = client.post("/api/ask", headers=headers, json={"text": "hello", "voice": True})
    assert result.status_code == 503 and "Pair Muse" in result.json()["detail"]
    result = client.post("/api/ask", headers=headers, json={"text": "Look", "assistant": "muse", "image_b64": "AA=="})
    assert result.status_code == 503 and "photo" in result.json()["detail"]
    async def respond(self, text, conversation):
        assert text == "voice check" and conversation is not None
        return "Heard you"
    monkeypatch.setattr(Muse, "reply", respond)
    result = client.post("/api/ask", headers=headers, json={"text": "voice check", "voice": True, "conversation_id": str(uuid4())})
    assert result.status_code == 200
    assert result.json()["provider"] == "muse" and "voice_b64" not in result.json()
